"""Main window (PySide6)."""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import uuid
from pathlib import Path
from typing import Callable, Optional

import numpy as np
from PySide6.QtCore import QEvent, QObject, QThread, QTimer, QUrl, Qt, Signal, Slot
from PySide6.QtGui import QAction, QColor, QIcon, QKeySequence, QPalette, QPixmap
from PySide6.QtMultimedia import QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (
    QAbstractSpinBox, QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QDoubleSpinBox, QFileDialog, QFrame, QGridLayout, QGroupBox, QHBoxLayout, QInputDialog, QLabel,
    QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QProgressDialog, QPushButton,
    QRadioButton, QScrollArea, QSlider, QStackedWidget, QStyle, QToolButton, QVBoxLayout, QWidget,
)

from . import media
from .audio_engine import (
    SILENCE_DB, AudioEngine, AudioParams, PluginSlot, db_to_gain, load_plugin, plugin_names_in, scan_plugins,
)
from .exporter import HIGH, LIGHT, QUALITIES, export
from .media import MediaInfo, format_timecode
from .widgets import FaderWidget, MeterWidget, TimelineWidget

APP_NAME = "EasyMovTrim"
MIN_RANGE = 0.1
VIDEO_FILTER = ("動画ファイル (*.mp4 *.mov *.m4v *.mkv *.webm *.avi *.flv *.f4v *.wmv *.asf *.mts *.m2ts *.ts "
                "*.mpg *.mpeg *.m2v *.vob *.ogv *.3gp *.3g2 *.rm *.rmvb *.divx *.mxf *.dv);;すべてのファイル (*)")


# --------------------------------------------------------------------------- background work

class Worker(QThread):
    progressed = Signal(float, str)
    item = Signal(object)
    succeeded = Signal(object)
    failed = Signal(str)
    was_cancelled = Signal()

    def __init__(self, fn: Callable[["Worker"], object], parent=None):
        super().__init__(parent)
        self.fn = fn
        self.cancel = threading.Event()

    def report(self, fraction: float, message: str = "") -> None:
        self.progressed.emit(fraction, message)

    def run(self) -> None:
        try:
            self.succeeded.emit(self.fn(self))
        except media.Cancelled:
            self.was_cancelled.emit()
        except Exception as e:  # surface every failure to the UI
            self.failed.emit(str(e) or e.__class__.__name__)


class Relay(QObject):
    """Lives on the GUI thread so worker signals are delivered there (queued)."""

    def __init__(self, parent: QObject, on_item=None, on_progress=None, on_success=None, on_fail=None,
                 on_cancel=None):
        super().__init__(parent)
        self._item, self._progress = on_item, on_progress
        self._success, self._fail, self._cancel = on_success, on_fail, on_cancel

    @Slot(object)
    def item(self, obj):
        if self._item:
            self._item(obj)

    @Slot(float, str)
    def progress(self, p, msg):
        if self._progress:
            self._progress(p, msg)

    @Slot(object)
    def success(self, r):
        if self._success:
            self._success(r)

    @Slot(str)
    def fail(self, m):
        if self._fail:
            self._fail(m)

    @Slot()
    def cancelled(self):
        if self._cancel:
            self._cancel()

    def attach(self, w: "Worker") -> None:
        w.item.connect(self.item)
        w.progressed.connect(self.progress)
        w.succeeded.connect(self.success)
        w.failed.connect(self.fail)
        w.was_cancelled.connect(self.cancelled)
        w.finished.connect(self.deleteLater)


# --------------------------------------------------------------------------- plugin dialogs

class PluginPicker(QDialog):
    def __init__(self, paths: list[Path], parent=None):
        super().__init__(parent)
        self.setWindowTitle("プラグインを挿入")
        self.resize(460, 520)
        self.selected: Optional[Path] = None
        lay = QVBoxLayout(self)
        self.search = QLineEdit(placeholderText="検索…")
        self.list = QListWidget()
        for p in paths:
            it = QListWidgetItem(p.stem)
            it.setToolTip(str(p))
            it.setData(Qt.UserRole, str(p))
            self.list.addItem(it)
        if not paths:
            self.list.addItem("VST3 プラグインが見つかりません")
        lay.addWidget(QLabel("VST3 プラグイン（C:\\Program Files\\Common Files\\VST3）" if sys.platform == "win32"
                             else "VST3 / Audio Unit プラグイン"))
        lay.addWidget(self.search)
        lay.addWidget(self.list)
        browse = QPushButton("ファイルから選ぶ…")
        browse.clicked.connect(self._browse)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._accept)
        buttons.rejected.connect(self.reject)
        row = QHBoxLayout()
        row.addWidget(browse)
        row.addStretch()
        row.addWidget(buttons)
        lay.addLayout(row)
        self.search.textChanged.connect(self._filter)
        self.list.itemDoubleClicked.connect(lambda _: self._accept())

    def _filter(self, text: str) -> None:
        t = text.lower()
        for i in range(self.list.count()):
            it = self.list.item(i)
            it.setHidden(t not in it.text().lower())

    def _browse(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "VST3 プラグインを選択", "", "VST3 (*.vst3);;すべて (*)")
        if path:
            self.selected = Path(path)
            self.accept()

    def _accept(self) -> None:
        it = self.list.currentItem()
        if it and it.data(Qt.UserRole):
            self.selected = Path(it.data(Qt.UserRole))
            self.accept()


class ParamsDialog(QDialog):
    """Generic parameter editor (non-blocking alternative to the plugin's own window)."""

    def __init__(self, slot: PluginSlot, parent=None):
        super().__init__(parent)
        self.slot = slot
        self.setWindowTitle(f"{slot.name} — パラメーター")
        self.resize(560, 600)
        lay = QVBoxLayout(self)
        self.search = QLineEdit(placeholderText="パラメーターを検索…")
        lay.addWidget(self.search)
        area = QScrollArea()
        area.setWidgetResizable(True)
        inner = QWidget()
        self.grid = QGridLayout(inner)
        self.grid.setColumnStretch(1, 1)
        area.setWidget(inner)
        lay.addWidget(area)
        self.rows: list[tuple[str, list[QWidget]]] = []
        plugin = slot.plugin
        for r, (name, prm) in enumerate(getattr(plugin, "parameters", {}).items()):
            label = QLabel(getattr(prm, "label", None) or name)
            label.setToolTip(name)
            widgets = [label] + self._control(plugin, name, prm)
            for c, w in enumerate(widgets):
                self.grid.addWidget(w, r, c)
            self.rows.append((name.lower() + " " + label.text().lower(), widgets))
        if not self.rows:
            self.grid.addWidget(QLabel("編集できるパラメーターはありません。"), 0, 0)
        self.search.textChanged.connect(self._filter)

    def _filter(self, text: str) -> None:
        t = text.lower()
        for key, widgets in self.rows:
            for w in widgets:
                w.setVisible(t in key)

    def _control(self, plugin, name: str, prm) -> list[QWidget]:
        ptype = getattr(prm, "type", float)
        valid = getattr(prm, "valid_values", None)
        if ptype is bool:
            cb = QCheckBox()
            cb.setChecked(bool(getattr(plugin, name)))
            cb.toggled.connect(lambda v: setattr(plugin, name, v))
            return [cb]
        if ptype is str and valid and len(valid) <= 200:
            combo = QComboBox()
            combo.addItems([str(v) for v in valid])
            cur = str(getattr(plugin, name))
            if cur in [str(v) for v in valid]:
                combo.setCurrentText(cur)
            combo.currentTextChanged.connect(lambda v: setattr(plugin, name, v))
            return [combo]
        slider = QSlider(Qt.Horizontal)
        slider.setRange(0, 1000)
        slider.setValue(int(round(float(getattr(prm, "raw_value", 0.0)) * 1000)))
        value = QLabel(str(getattr(plugin, name)))
        value.setMinimumWidth(110)

        def changed(v: int):
            try:
                prm.raw_value = v / 1000.0
                value.setText(str(getattr(plugin, name)))
            except Exception:
                pass

        slider.valueChanged.connect(changed)
        return [slider, value]


class PluginRow(QFrame):
    def __init__(self, win: "MainWindow", slot: PluginSlot, index: int, count: int):
        super().__init__()
        self.setFrameShape(QFrame.StyledPanel)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(6, 4, 6, 4)
        on = QCheckBox()
        on.setChecked(not slot.bypassed)
        on.setToolTip("オン / バイパス")
        on.toggled.connect(lambda v: setattr(slot, "bypassed", not v))
        lay.addWidget(on)
        text = QLabel(f"<b>{slot.name}</b>" + (f"<br><span style='color:#ff9f0a'>{slot.error}</span>" if slot.error else ""))
        text.setWordWrap(True)
        lay.addWidget(text, 1)

        def tool(label: str, tip: str, fn, enabled=True):
            b = QToolButton()
            b.setText(label)
            b.setToolTip(tip)
            b.setEnabled(enabled)
            b.clicked.connect(fn)
            lay.addWidget(b)

        tool("画面", "プラグイン本来の画面を開く", lambda: win.show_plugin_editor(slot))
        tool("⚙", "パラメーター一覧", lambda: win.show_plugin_params(slot))
        tool("▲", "上へ", lambda: win.move_plugin(slot, -1), index > 0)
        tool("▼", "下へ", lambda: win.move_plugin(slot, 1), index < count - 1)
        tool("✕", "削除", lambda: win.remove_plugin(slot))


# --------------------------------------------------------------------------- main window

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.resize(1320, 860)
        self.setMinimumSize(1100, 740)
        self.setAcceptDrops(True)

        self.engine = AudioEngine()
        self.info: Optional[MediaInfo] = None
        self.duration = 0.0
        self.in_point = 0.0
        self.out_point = 0.0
        self.current = 0.0
        self.loop = False
        self.using_proxy = False
        self._was_playing = False
        self._last_resync = 0.0
        self._workers: list[Worker] = []
        self._thumb_worker: Optional[Worker] = None
        self._plugin_paths: Optional[list[Path]] = None
        self._busy: Optional[QProgressDialog] = None

        self.player = QMediaPlayer(self)
        self.video = QVideoWidget()
        self.player.setVideoOutput(self.video)
        self.player.errorOccurred.connect(self._on_player_error)

        self._build_ui()
        self._build_menu()
        self._sync_params()
        self._refresh()

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._tick)
        self.timer.start(33)
        QApplication.instance().installEventFilter(self)

    # ---------------------------------------------------------------- layout

    def _build_ui(self) -> None:
        root = QWidget()
        h = QHBoxLayout(root)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(0)
        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(16, 14, 16, 14)
        lv.setSpacing(10)

        header = QHBoxLayout()
        open_btn = QPushButton(self.style().standardIcon(QStyle.SP_DirOpenIcon), " 開く…")
        open_btn.clicked.connect(self.open_dialog)
        header.addWidget(open_btn)
        self.file_label = QLabel("動画ファイルを開いてください")
        self.file_label.setTextFormat(Qt.RichText)
        header.addWidget(self.file_label, 1)
        lv.addLayout(header)

        self.stack = QStackedWidget()
        placeholder = QLabel("ここに動画ファイルをドロップ\n\nまたは Ctrl+O で開く\n"
                             "MP4 / MOV / MKV / WebM / AVI / FLV / WMV / MTS など")
        placeholder.setAlignment(Qt.AlignCenter)
        placeholder.setStyleSheet("background:#000; color:#bbb; font-size:15px; border-radius:8px;")
        self.video.setStyleSheet("background:#000;")
        self.stack.addWidget(placeholder)
        self.stack.addWidget(self.video)
        self.stack.setMinimumHeight(280)
        lv.addWidget(self.stack, 1)

        # transport
        tr = QHBoxLayout()
        self.time_label = QLabel("00:00:00.000")
        self.time_label.setStyleSheet("font-family: Consolas, monospace; font-size: 16px;")
        tr.addWidget(self.time_label)
        tr.addStretch()

        def tbtn(text: str, tip: str, fn) -> QPushButton:
            b = QPushButton(text)
            b.setToolTip(tip)
            b.clicked.connect(fn)
            b.setFixedWidth(40)
            tr.addWidget(b)
            return b

        tbtn("⇤", "開始点へ移動 (Home)", lambda: self.seek(self.in_point))
        tbtn("◀", "1 フレーム戻る (←)", lambda: self.step(-1))
        self.play_btn = tbtn("▶", "再生 / 一時停止 (Space)", self.toggle_play)
        self.play_btn.setFixedWidth(56)
        tbtn("▶", "1 フレーム進む (→)", lambda: self.step(1)).setText("▶|")
        tbtn("⇥", "終了点へ移動 (End)", lambda: self.seek(self.out_point))
        range_btn = QPushButton("範囲を再生")
        range_btn.clicked.connect(self.play_range)
        tr.addSpacing(12)
        tr.addWidget(range_btn)
        self.loop_btn = QPushButton("ループ")
        self.loop_btn.setCheckable(True)
        self.loop_btn.setToolTip("トリム範囲をループ再生 (L)")
        self.loop_btn.toggled.connect(self.set_loop)
        tr.addWidget(self.loop_btn)
        tr.addStretch()
        self.duration_label = QLabel("00:00:00.000")
        self.duration_label.setStyleSheet("font-family: Consolas, monospace; color:#999;")
        tr.addWidget(self.duration_label)
        self.transport = QWidget()
        self.transport.setLayout(tr)
        lv.addWidget(self.transport)

        self.timeline = TimelineWidget()
        self.timeline.seekRequested.connect(self.seek)
        self.timeline.inRequested.connect(lambda t: (self.set_in(t), self.seek(self.in_point)))
        self.timeline.outRequested.connect(lambda t: (self.set_out(t), self.seek(self.out_point)))
        lv.addWidget(self.timeline)

        bottom = QHBoxLayout()
        bottom.addWidget(self._build_trim_box(), 1)
        bottom.addWidget(self._build_export_box())
        lv.addLayout(bottom)
        h.addWidget(left, 1)

        line = QFrame()
        line.setFrameShape(QFrame.VLine)
        h.addWidget(line)
        h.addWidget(self._build_audio_panel())
        self.setCentralWidget(root)

    def _seconds_box(self) -> QDoubleSpinBox:
        sb = QDoubleSpinBox()
        sb.setDecimals(3)
        sb.setSuffix(" 秒")
        sb.setRange(0, 0)
        sb.setKeyboardTracking(False)
        sb.setMinimumWidth(130)
        sb.setAlignment(Qt.AlignRight)
        return sb

    def _build_trim_box(self) -> QGroupBox:
        box = QGroupBox("トリム範囲（秒）")
        g = QGridLayout(box)
        self.in_box = self._seconds_box()
        self.out_box = self._seconds_box()
        self.in_box.valueChanged.connect(self.set_in)
        self.out_box.valueChanged.connect(self.set_out)
        self.in_tc = QLabel()
        self.out_tc = QLabel()
        self.len_label = QLabel()
        for lab in (self.in_tc, self.out_tc, self.len_label):
            lab.setStyleSheet("font-family: Consolas, monospace; color:#aaa;")
        b_in = QPushButton("現在位置を開始に (I)")
        b_in.clicked.connect(lambda: self.set_in(self.current))
        b_out = QPushButton("現在位置を終了に (O)")
        b_out.clicked.connect(lambda: self.set_out(self.current))
        b_reset = QPushButton("範囲をリセット")
        b_reset.clicked.connect(self.reset_range)
        g.addWidget(QLabel("開始"), 0, 0)
        g.addWidget(self.in_box, 0, 1)
        g.addWidget(self.in_tc, 0, 2)
        g.addWidget(b_in, 0, 3)
        g.addWidget(QLabel("終了"), 1, 0)
        g.addWidget(self.out_box, 1, 1)
        g.addWidget(self.out_tc, 1, 2)
        g.addWidget(b_out, 1, 3)
        g.addWidget(QLabel("長さ"), 2, 0)
        g.addWidget(self.len_label, 2, 1, 1, 2)
        g.addWidget(b_reset, 2, 3)
        self.trim_box = box
        return box

    def _build_export_box(self) -> QGroupBox:
        box = QGroupBox("エクスポート")
        box.setFixedWidth(340)
        v = QVBoxLayout(box)
        row = QHBoxLayout()
        self.quality_group = QButtonGroup(self)
        for i, q in enumerate(QUALITIES):
            rb = QRadioButton(q.title)
            rb.setChecked(q is HIGH)
            self.quality_group.addButton(rb, i)
            row.addWidget(rb)
        row.addStretch()
        v.addLayout(row)
        self.quality_detail = QLabel(HIGH.detail)
        self.quality_detail.setWordWrap(True)
        self.quality_detail.setStyleSheet("color:#999; font-size:11px;")
        self.quality_group.idToggled.connect(
            lambda i, on: on and self.quality_detail.setText(QUALITIES[i].detail))
        v.addWidget(self.quality_detail)
        self.export_btn = QPushButton("MP4 を書き出す…")
        self.export_btn.setMinimumHeight(36)
        self.export_btn.setStyleSheet("QPushButton{background:#0a84ff;color:white;border-radius:6px;font-weight:600}"
                                      "QPushButton:disabled{background:#3a3a3c;color:#888}")
        self.export_btn.clicked.connect(self.export_movie)
        v.addWidget(self.export_btn)
        self.export_box = box
        return box

    def _build_audio_panel(self) -> QWidget:
        panel = QWidget()
        panel.setFixedWidth(320)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        v = QVBoxLayout(inner)
        v.setContentsMargins(16, 14, 16, 14)
        title = QLabel("<b>オーディオ</b>")
        title.setStyleSheet("font-size:15px;")
        v.addWidget(title)

        mf = QHBoxLayout()
        self.meter = MeterWidget()
        self.fader = FaderWidget()
        self.fader.valueChanged.connect(self._on_fader)
        mf.addStretch()
        mf.addWidget(self.meter)
        mf.addSpacing(12)
        mf.addWidget(self.fader)
        mf.addStretch()
        mw = QWidget()
        mw.setLayout(mf)
        mw.setFixedHeight(270)
        v.addWidget(mw)

        vol = QHBoxLayout()
        vol.addWidget(QLabel("音量"))
        vol.addStretch()
        self.vol_label = QLabel("+0.0 dB")
        self.vol_label.setStyleSheet("font-family: Consolas, monospace;")
        vol.addWidget(self.vol_label)
        zero = QPushButton("0 dB")
        zero.clicked.connect(lambda: self._on_fader(0.0, update_widget=True))
        vol.addWidget(zero)
        v.addLayout(vol)
        v.addWidget(self._hline())

        self.fade_in_cb, self.fade_in_sb = self._fade_row(v, "フェードイン")
        self.fade_out_cb, self.fade_out_sb = self._fade_row(v, "フェードアウト")
        v.addWidget(self._hline())

        ph = QHBoxLayout()
        ph.addWidget(QLabel("<b>プラグイン (VST3)</b>"))
        ph.addStretch()
        add = QPushButton("＋ 挿入")
        add.clicked.connect(self.add_plugin)
        ph.addWidget(add)
        v.addLayout(ph)
        self.plugin_box = QVBoxLayout()
        self.plugin_box.setSpacing(4)
        v.addLayout(self.plugin_box)
        note = QLabel("信号の流れ: プラグイン → フェーダー → フェード → メーター")
        note.setStyleSheet("color:#777; font-size:10px;")
        note.setWordWrap(True)
        v.addWidget(note)
        v.addStretch()
        scroll.setWidget(inner)
        outer = QVBoxLayout(panel)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll)
        self._rebuild_plugins()
        return panel

    @staticmethod
    def _hline() -> QFrame:
        f = QFrame()
        f.setFrameShape(QFrame.HLine)
        return f

    def _fade_row(self, parent: QVBoxLayout, title: str):
        cb = QCheckBox(title)
        slider = QSlider(Qt.Horizontal)
        slider.setRange(1, 50)
        slider.setValue(10)
        sb = QDoubleSpinBox()
        sb.setRange(0.1, 5.0)
        sb.setSingleStep(0.1)
        sb.setDecimals(1)
        sb.setValue(1.0)
        sb.setSuffix(" 秒")
        slider.valueChanged.connect(lambda val: sb.setValue(val / 10))
        sb.valueChanged.connect(lambda val: (slider.blockSignals(True), slider.setValue(int(round(val * 10))),
                                             slider.blockSignals(False), self._sync_params()))
        cb.toggled.connect(lambda on: (slider.setEnabled(on), sb.setEnabled(on), self._sync_params()))
        slider.setEnabled(False)
        sb.setEnabled(False)
        parent.addWidget(cb)
        row = QHBoxLayout()
        row.addWidget(slider, 1)
        row.addWidget(sb)
        parent.addLayout(row)
        return cb, sb

    def _build_menu(self) -> None:
        m = self.menuBar().addMenu("ファイル")
        a_open = QAction("動画を開く…", self, shortcut=QKeySequence.Open, triggered=self.open_dialog)
        a_export = QAction("MP4 を書き出す…", self, shortcut=QKeySequence("Ctrl+E"), triggered=self.export_movie)
        a_quit = QAction("終了", self, shortcut=QKeySequence.Quit, triggered=self.close)
        m.addActions([a_open, a_export])
        m.addSeparator()
        m.addAction(a_quit)
        p = self.menuBar().addMenu("再生")
        p.addAction(QAction("再生 / 一時停止（Space）", self, triggered=self.toggle_play))
        p.addAction(QAction("範囲を再生", self, triggered=self.play_range))
        p.addSeparator()
        p.addAction(QAction("現在位置を開始点に（I）", self, triggered=lambda: self.set_in(self.current)))
        p.addAction(QAction("現在位置を終了点に（O）", self, triggered=lambda: self.set_out(self.current)))
        p.addAction(QAction("範囲をリセット", self, triggered=self.reset_range))
        h = self.menuBar().addMenu("ヘルプ")
        h.addAction(QAction("ライセンス情報", self, triggered=self._show_licenses))

    # ---------------------------------------------------------------- state sync

    def _refresh(self) -> None:
        loaded = self.info is not None
        for w in (self.transport, self.timeline, self.trim_box, self.export_box):
            w.setEnabled(loaded)
        self.timeline.set_state(self.duration, self.in_point, self.out_point, self.current)
        self.time_label.setText(format_timecode(self.current))
        self.duration_label.setText(format_timecode(self.duration))
        step = 1 / (self.info.fps if self.info and self.info.fps > 0 else 30)
        for sb, val, lo, hi in ((self.in_box, self.in_point, 0, max(0, self.out_point - MIN_RANGE)),
                                (self.out_box, self.out_point, min(self.duration, self.in_point + MIN_RANGE), self.duration)):
            sb.blockSignals(True)
            sb.setRange(lo, hi)
            sb.setSingleStep(step)
            sb.setValue(val)
            sb.blockSignals(False)
        self.in_tc.setText(format_timecode(self.in_point))
        self.out_tc.setText(format_timecode(self.out_point))
        length = max(0.0, self.out_point - self.in_point)
        self.len_label.setText(f"{length:.3f} 秒   {format_timecode(length)}")
        self.play_btn.setText("❚❚" if self.engine.playing else "▶")

    def _sync_params(self) -> None:
        self.engine.set_params(AudioParams(
            gain=db_to_gain(self.fader.db),
            fade_in_on=self.fade_in_cb.isChecked(), fade_in=round(self.fade_in_sb.value(), 1),
            fade_out_on=self.fade_out_cb.isChecked(), fade_out=round(self.fade_out_sb.value(), 1),
            trim_start=self.in_point, trim_end=self.out_point if self.out_point > self.in_point else float("inf"),
        ))

    def _on_fader(self, db: float, update_widget: bool = False) -> None:
        if update_widget:
            self.fader.set_db(db)
        self.vol_label.setText("-∞ dB" if db <= SILENCE_DB else f"{db:+.1f} dB")
        self._sync_params()

    # ---------------------------------------------------------------- loading

    def open_dialog(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "動画ファイルを開く", "", VIDEO_FILTER)
        if path:
            self.open_file(path)

    def open_file(self, path: str) -> None:
        self.pause()

        def job(w: Worker):
            w.report(-1, "読み込んでいます…")
            info = media.probe(path)
            data = None
            if info.has_audio:
                raw = media.temp_dir() / f"audio_{uuid.uuid4().hex[:8]}.f32"
                media.decode_audio(path, raw, info.duration, lambda p: w.report(p, "音声を読み込んでいます…"), w.cancel)
                if raw.stat().st_size >= 8:
                    data = np.memmap(raw, dtype=np.float32, mode="r").reshape(-1, 2)
            return info, data

        self._run(job, "読み込んでいます…", self._loaded)

    def _loaded(self, result) -> None:
        info, data = result
        self.info = info
        self.duration = info.duration
        self.in_point, self.out_point, self.current = 0.0, info.duration, 0.0
        self.engine.load(data, info.duration)
        if self.engine.device_error:
            self.statusBar().showMessage(self.engine.device_error, 10000)
        self.using_proxy = False
        self.player.setSource(QUrl.fromLocalFile(info.path))
        self.player.pause()
        self.player.setPosition(0)
        self.stack.setCurrentIndex(1)
        name = Path(info.path).name
        self.file_label.setText(f"<b>{name}</b><br><span style='color:#999;font-size:11px'>{info.summary}</span>")
        self.setWindowTitle(f"{name} — {APP_NAME}")
        self._sync_params()
        self._refresh()
        self._load_thumbnails(info)

    def _on_player_error(self, error, message: str) -> None:
        if self.info is None or self.using_proxy or error == QMediaPlayer.NoError:
            return
        info = self.info
        self.using_proxy = True

        def job(w: Worker):
            out = media.temp_dir() / f"proxy_{uuid.uuid4().hex[:8]}.mp4"
            media.make_preview_proxy(info, out, lambda p: w.report(p, "プレビュー用に変換しています…"), w.cancel)
            return out

        def done(out: Path):
            if self.info is info:
                self.player.setSource(QUrl.fromLocalFile(str(out)))
                self.player.pause()
                self.player.setPosition(int(self.current * 1000))
                self.statusBar().showMessage("プレビュー用に変換しました（書き出しは元のファイルから行います）", 8000)

        self._run(job, "プレビュー用に変換しています…", done)

    def _load_thumbnails(self, info: MediaInfo) -> None:
        if self._thumb_worker is not None:
            self._thumb_worker.cancel.set()
        self.timeline.thumbnails = []
        count = 24

        def job(w: Worker):
            for i in range(count):
                if w.cancel.is_set():
                    return None
                png = media.thumbnail_png(info.path, info.duration * (i + 0.5) / count)
                if png:
                    w.item.emit(png)
            return None

        w = Worker(job, self)
        Relay(self, on_item=lambda png: self._add_thumb(info, png)).attach(w)
        self._thumb_worker = w
        self._keep(w)
        w.start()

    def _add_thumb(self, info: MediaInfo, png: bytes) -> None:
        if self.info is not info:
            return
        pix = QPixmap()
        if pix.loadFromData(png):
            self.timeline.thumbnails.append(pix)
            self.timeline.update()

    # ---------------------------------------------------------------- transport

    def _tick(self) -> None:
        self.meter.push(self.engine.meter.read_and_reset())
        if self.info is None:
            return
        playing = self.engine.playing
        if playing:
            t = self.engine.position()
            self.current = t
            if self.player.playbackState() != QMediaPlayer.PlayingState:
                self.player.play()
            drift = self.player.position() / 1000 - t
            if abs(drift) > 0.15 and abs(t - self._last_resync) > 0.5:
                self.player.setPosition(int(t * 1000))
                self._last_resync = t
        elif self._was_playing:
            self.player.pause()
            self.current = self.engine.position()
            self.player.setPosition(int(self.current * 1000))
        self._was_playing = playing
        self.timeline.set_state(self.duration, self.in_point, self.out_point, self.current)
        self.time_label.setText(format_timecode(self.current))
        self.play_btn.setText("❚❚" if playing else "▶")

    def toggle_play(self) -> None:
        if self.info is None:
            return
        if self.engine.playing:
            self.pause()
            return
        if self.current >= self.duration - 0.02 or (self.loop and not (self.in_point <= self.current < self.out_point)):
            self.seek(self.in_point)
        self.engine.play(loop=self.loop)
        self.player.play()
        self._last_resync = self.current

    def play_range(self) -> None:
        if self.info is None:
            return
        self.seek(self.in_point)
        self.engine.play(stop_at=None if self.loop else self.out_point, loop=self.loop)
        self.player.play()
        self._last_resync = self.current

    def pause(self) -> None:
        self.engine.pause()
        self.player.pause()
        if self.info is not None:
            self.current = self.engine.position()
            self.player.setPosition(int(self.current * 1000))
        self._was_playing = False

    def seek(self, t: float) -> None:
        if self.info is None:
            return
        t = max(0.0, min(self.duration, t))
        self.current = t
        self.engine.seek(t)
        self.player.setPosition(int(t * 1000))
        self._last_resync = t
        self.timeline.set_state(self.duration, self.in_point, self.out_point, self.current)
        self.time_label.setText(format_timecode(t))

    def step(self, frames: int) -> None:
        if self.info is None:
            return
        self.pause()
        fps = self.info.fps if self.info.fps > 0 else 30
        self.seek(self.current + frames / fps)

    def set_loop(self, on: bool) -> None:
        self.loop = on
        self.loop_btn.setChecked(on)
        self.engine.set_loop(on)

    # ---------------------------------------------------------------- trim

    def set_in(self, t: float) -> None:
        if self.info is None:
            return
        self.in_point = max(0.0, min(t, self.out_point - MIN_RANGE))
        self._sync_params()
        self._refresh()

    def set_out(self, t: float) -> None:
        if self.info is None:
            return
        self.out_point = max(min(self.duration, self.in_point + MIN_RANGE), min(t, self.duration))
        self._sync_params()
        self._refresh()

    def reset_range(self) -> None:
        if self.info is None:
            return
        self.in_point, self.out_point = 0.0, self.duration
        self._sync_params()
        self._refresh()

    # ---------------------------------------------------------------- plugins

    def add_plugin(self) -> None:
        if self._plugin_paths is None:
            QApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                self._plugin_paths = scan_plugins()
            finally:
                QApplication.restoreOverrideCursor()
        picker = PluginPicker(self._plugin_paths, self)
        if picker.exec() != QDialog.Accepted or picker.selected is None:
            return
        path = str(picker.selected)
        name = None
        names = plugin_names_in(path)
        if len(names) > 1:
            name, ok = QInputDialog.getItem(self, "プラグインを選択", "このファイルには複数のプラグインがあります:", names, 0, False)
            if not ok:
                return
        QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            plugin = load_plugin(path, name)
        except Exception as e:
            QApplication.restoreOverrideCursor()
            QMessageBox.warning(self, "プラグインを読み込めません", f"{Path(path).stem}\n\n{e}")
            return
        QApplication.restoreOverrideCursor()
        slot = PluginSlot(name=getattr(plugin, "name", None) or Path(path).stem, path=path, plugin=plugin)
        self.engine.add_slot(slot)
        self._rebuild_plugins()

    def remove_plugin(self, slot: PluginSlot) -> None:
        self.engine.remove_slot(slot)
        self._rebuild_plugins()

    def move_plugin(self, slot: PluginSlot, delta: int) -> None:
        self.engine.move_slot(slot, delta)
        self._rebuild_plugins()

    def show_plugin_params(self, slot: PluginSlot) -> None:
        dlg = ParamsDialog(slot, self)
        dlg.setModal(False)
        dlg.show()

    def show_plugin_editor(self, slot: PluginSlot) -> None:
        if not hasattr(slot.plugin, "show_editor"):
            self.show_plugin_params(slot)
            return
        self.statusBar().showMessage(f"{slot.name} の画面を開いています。閉じるとメイン画面に戻ります。")
        QApplication.processEvents()
        try:
            slot.plugin.show_editor()  # blocks until the plugin window is closed
        except Exception as e:
            QMessageBox.information(self, "プラグイン画面", f"このプラグインの画面を開けませんでした。\n{e}\n\nパラメーター一覧で編集できます。")
            self.show_plugin_params(slot)
        self.statusBar().clearMessage()

    def _rebuild_plugins(self) -> None:
        while self.plugin_box.count():
            item = self.plugin_box.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        slots = list(self.engine.slots)
        if not slots:
            hint = QLabel("「＋ 挿入」から VST3 エフェクトを追加できます。上から順に処理されます。")
            hint.setWordWrap(True)
            hint.setStyleSheet("color:#999; font-size:11px;")
            self.plugin_box.addWidget(hint)
        for i, s in enumerate(slots):
            self.plugin_box.addWidget(PluginRow(self, s, i, len(slots)))

    # ---------------------------------------------------------------- export

    def export_movie(self) -> None:
        if self.info is None or self.out_point - self.in_point <= 0:
            return
        self.pause()
        quality = QUALITIES[max(0, self.quality_group.checkedId())]
        src = Path(self.info.path)
        default = src.with_name(f"{src.stem}_trim{'_light' if quality is LIGHT else ''}.mp4")
        out, _ = QFileDialog.getSaveFileName(self, "MP4 を書き出す", str(default), "MP4 動画 (*.mp4)")
        if not out:
            return
        if not out.lower().endswith(".mp4"):
            out += ".mp4"
        self._sync_params()
        info, start, end, params = self.info, self.in_point, self.out_point, self.engine.params

        def job(w: Worker):
            export(info, out, start, end, quality, params, self.engine.slots, self.engine.chain_lock,
                   lambda p: w.report(p, f"MP4 を書き出しています（{quality.title}）…"), w.cancel)
            return out

        def done(path: str):
            box = QMessageBox(self)
            box.setWindowTitle("書き出しが完了しました")
            box.setText(path)
            reveal = box.addButton("フォルダを開く", QMessageBox.AcceptRole)
            box.addButton("閉じる", QMessageBox.RejectRole)
            box.exec()
            if box.clickedButton() is reveal:
                reveal_in_file_manager(path)

        self._run(job, f"MP4 を書き出しています（{quality.title}）…", done)

    # ---------------------------------------------------------------- helpers

    def _keep(self, w: Worker) -> None:
        self._workers.append(w)
        w.finished.connect(lambda: self._workers.remove(w) if w in self._workers else None)

    def _run(self, job, title: str, on_success) -> None:
        dlg = QProgressDialog(title, "キャンセル", 0, 0, self)
        dlg.setWindowTitle(APP_NAME)
        dlg.setWindowModality(Qt.WindowModal)
        dlg.setMinimumDuration(0)
        dlg.setAutoClose(False)
        dlg.setAutoReset(False)
        w = Worker(job, self)

        def progress(p: float, msg: str):
            if msg:
                dlg.setLabelText(msg)
            if p < 0:
                dlg.setRange(0, 0)
            else:
                dlg.setRange(0, 1000)
                dlg.setValue(int(p * 1000))

        Relay(self, on_progress=progress,
              on_success=lambda r: (dlg.close(), on_success(r)),
              on_fail=lambda m: (dlg.close(), QMessageBox.critical(self, "エラー", m)),
              on_cancel=dlg.close).attach(w)
        dlg.canceled.connect(w.cancel.set)
        self._keep(w)
        w.start()
        dlg.show()

    def _show_licenses(self) -> None:
        text = "EasyMovTrim\n\n"
        for p in (media.resource_dir() / "THIRD_PARTY_NOTICES.md",
                  media.resource_dir().parent.parent / "THIRD_PARTY_NOTICES.md"):
            if p.is_file():
                text += p.read_text(encoding="utf-8")
                break
        dlg = QDialog(self)
        dlg.setWindowTitle("ライセンス情報")
        dlg.resize(640, 560)
        lay = QVBoxLayout(dlg)
        view = QLabel(text)
        view.setWordWrap(True)
        view.setTextInteractionFlags(Qt.TextSelectableByMouse)
        area = QScrollArea()
        area.setWidgetResizable(True)
        area.setWidget(view)
        lay.addWidget(area)
        dlg.exec()

    # ---------------------------------------------------------------- events

    def eventFilter(self, obj: QObject, e: QEvent) -> bool:
        if e.type() == QEvent.KeyPress and self.isActiveWindow() and self.info is not None:
            focus = QApplication.focusWidget()
            if isinstance(focus, (QAbstractSpinBox, QLineEdit, QComboBox)) or e.modifiers() & (
                    Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier):
                return False
            shift = bool(e.modifiers() & Qt.ShiftModifier)
            k = e.key()
            actions = {
                Qt.Key_Space: self.toggle_play,
                Qt.Key_Left: lambda: self.seek(self.current - 1) if shift else self.step(-1),
                Qt.Key_Right: lambda: self.seek(self.current + 1) if shift else self.step(1),
                Qt.Key_Home: lambda: self.seek(self.in_point),
                Qt.Key_End: lambda: self.seek(self.out_point),
                Qt.Key_I: lambda: self.set_in(self.current),
                Qt.Key_O: lambda: self.set_out(self.current),
                Qt.Key_L: lambda: self.set_loop(not self.loop),
            }
            if k in actions:
                actions[k]()
                return True
        return super().eventFilter(obj, e)

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        urls = [u for u in e.mimeData().urls() if u.isLocalFile()]
        if urls:
            self.open_file(urls[0].toLocalFile())

    def closeEvent(self, e):
        for w in list(self._workers):
            w.cancel.set()
            w.wait(3000)
        self.engine.close()
        super().closeEvent(e)


def reveal_in_file_manager(path: str) -> None:
    try:
        if sys.platform == "win32":
            subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-R", path])
        else:
            subprocess.Popen(["xdg-open", str(Path(path).parent)])
    except Exception:
        pass


def _dark_palette(app: QApplication) -> None:
    app.setStyle("Fusion")
    pal = QPalette()
    base, window, text = QColor(30, 30, 32), QColor(38, 38, 40), QColor(230, 230, 232)
    pal.setColor(QPalette.Window, window)
    pal.setColor(QPalette.WindowText, text)
    pal.setColor(QPalette.Base, base)
    pal.setColor(QPalette.AlternateBase, window)
    pal.setColor(QPalette.Text, text)
    pal.setColor(QPalette.Button, QColor(52, 52, 56))
    pal.setColor(QPalette.ButtonText, text)
    pal.setColor(QPalette.Highlight, QColor(10, 132, 255))
    pal.setColor(QPalette.HighlightedText, Qt.white)
    pal.setColor(QPalette.ToolTipBase, base)
    pal.setColor(QPalette.ToolTipText, text)
    pal.setColor(QPalette.Disabled, QPalette.Text, QColor(120, 120, 120))
    pal.setColor(QPalette.Disabled, QPalette.ButtonText, QColor(120, 120, 120))
    pal.setColor(QPalette.Disabled, QPalette.WindowText, QColor(120, 120, 120))
    app.setPalette(pal)


def run_gui(argv: list[str]) -> int:
    app = QApplication(sys.argv[:1])
    app.setApplicationName(APP_NAME)
    _dark_palette(app)
    icon = media.resource_dir() / "assets" / "icon.png"
    if icon.is_file():
        app.setWindowIcon(QIcon(str(icon)))
    win = MainWindow()
    win.show()
    files = [a for a in argv if not a.startswith("-") and os.path.isfile(a)]
    if files:
        QTimer.singleShot(200, lambda: win.open_file(files[0]))
    return app.exec()
