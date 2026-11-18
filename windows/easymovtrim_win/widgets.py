"""Custom-painted widgets: timeline, level meter, volume fader."""
from __future__ import annotations

import math
import time
from typing import Optional

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QBrush, QColor, QFont, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import QSizePolicy, QWidget

from .audio_engine import SILENCE_DB, gain_to_db

YELLOW = QColor("#f5c518")
RED = QColor("#ff3b30")


def _short_time(t: float, fractional: bool) -> str:
    m = int(t // 60)
    s = t % 60
    return f"{m}:{s:04.1f}" if fractional else f"{m}:{int(s):02d}"


# --------------------------------------------------------------------------- timeline

class TimelineWidget(QWidget):
    seekRequested = Signal(float)
    inRequested = Signal(float)
    outRequested = Signal(float)

    RULER = 18
    STRIP = 58
    HANDLE = 10

    def __init__(self, parent=None):
        super().__init__(parent)
        self.duration = 0.0
        self.in_point = 0.0
        self.out_point = 0.0
        self.current = 0.0
        self.thumbnails: list[QPixmap] = []
        self._drag: Optional[str] = None
        self.setMinimumHeight(self.RULER + self.STRIP + 6)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setCursor(Qt.PointingHandCursor)

    def set_state(self, duration: float, in_point: float, out_point: float, current: float) -> None:
        self.duration, self.in_point, self.out_point, self.current = duration, in_point, out_point, current
        self.update()

    def _x(self, t: float) -> float:
        return (t / self.duration) * self.width() if self.duration > 0 else 0.0

    def _t(self, x: float) -> float:
        if self.width() <= 0 or self.duration <= 0:
            return 0.0
        return max(0.0, min(self.duration, x / self.width() * self.duration))

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        w = self.width()
        self._paint_ruler(p, w)
        strip = QRectF(0, self.RULER, w, self.STRIP)
        path = QPainterPath()
        path.addRoundedRect(strip, 4, 4)
        p.save()
        p.setClipPath(path)
        p.fillRect(strip, QColor(10, 10, 10))
        self._paint_thumbs(p, strip)
        p.restore()
        if self.duration <= 0:
            return
        xi, xo, xn = self._x(self.in_point), self._x(self.out_point), self._x(self.current)
        dim = QColor(0, 0, 0, 160)
        p.fillRect(QRectF(0, self.RULER, max(0, xi), self.STRIP), dim)
        p.fillRect(QRectF(xo, self.RULER, max(0, w - xo), self.STRIP), dim)
        p.setPen(QPen(YELLOW, 3))
        p.setBrush(Qt.NoBrush)
        p.drawRect(QRectF(xi + 1.5, self.RULER + 1.5, max(self.HANDLE * 2, xo - xi) - 3, self.STRIP - 3))
        p.setPen(Qt.NoPen)
        p.setBrush(YELLOW)
        p.drawRoundedRect(QRectF(xi, self.RULER, self.HANDLE, self.STRIP), 3, 3)
        p.drawRoundedRect(QRectF(xo - self.HANDLE, self.RULER, self.HANDLE, self.STRIP), 3, 3)
        p.setPen(QPen(QColor(0, 0, 0, 170), 2))
        for x, sign in ((xi + self.HANDLE / 2, -1), (xo - self.HANDLE / 2, 1)):
            cy = self.RULER + self.STRIP / 2
            p.drawLine(QPointF(x - 2 * sign, cy - 5), QPointF(x + 2 * sign, cy))
            p.drawLine(QPointF(x + 2 * sign, cy), QPointF(x - 2 * sign, cy + 5))
        p.setPen(Qt.NoPen)
        p.setBrush(RED)
        p.drawRect(QRectF(xn - 1, 0, 2, self.RULER + self.STRIP + 4))
        tri = QPainterPath()
        tri.moveTo(xn - 6, 0)
        tri.lineTo(xn + 6, 0)
        tri.lineTo(xn, 8)
        tri.closeSubpath()
        p.drawPath(tri)

    def _paint_ruler(self, p: QPainter, w: int) -> None:
        if self.duration <= 0 or w <= 0:
            return
        pps = w / self.duration
        steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        major = next((s for s in steps if s * pps >= 70), 7200)
        minor = major / 5
        font = QFont(self.font())
        font.setPointSizeF(7.5)
        p.setFont(font)
        i = 0
        while True:
            t = i * minor
            if t > self.duration + 1e-4:
                break
            x = t * pps
            is_major = i % 5 == 0
            p.setPen(QPen(QColor(150, 150, 150, 230 if is_major else 120), 1))
            p.drawLine(QPointF(x, self.RULER - (8 if is_major else 4)), QPointF(x, self.RULER))
            if is_major:
                p.drawText(QPointF(x + 3, 9), _short_time(t, major < 1))
            i += 1

    def _paint_thumbs(self, p: QPainter, strip: QRectF) -> None:
        if not self.thumbnails:
            return
        first = self.thumbnails[0]
        aspect = max(0.3, first.width() / max(first.height(), 1))
        visible = max(1, math.ceil(strip.width() / (strip.height() * aspect)))
        cell = strip.width() / visible
        n = len(self.thumbnails)
        for i in range(visible):
            pix = self.thumbnails[min(n - 1, int((i + 0.5) / visible * n))]
            target = QRectF(strip.left() + i * cell, strip.top(), cell, strip.height())
            # center-crop to fill the cell
            src_aspect = pix.width() / max(pix.height(), 1)
            cell_aspect = target.width() / target.height()
            if src_aspect > cell_aspect:
                sw = pix.height() * cell_aspect
                src = QRectF((pix.width() - sw) / 2, 0, sw, pix.height())
            else:
                sh = pix.width() / cell_aspect
                src = QRectF(0, (pix.height() - sh) / 2, pix.width(), sh)
            p.drawPixmap(target, pix, src)

    def mousePressEvent(self, e):
        if self.duration <= 0:
            return
        x, y = e.position().x(), e.position().y()
        self._drag = "playhead"
        if y >= self.RULER:
            d_in = abs(x - (self._x(self.in_point) + self.HANDLE / 2))
            d_out = abs(x - (self._x(self.out_point) - self.HANDLE / 2))
            if min(d_in, d_out) <= 12:
                self._drag = "in" if d_in <= d_out else "out"
        self._apply(x)

    def mouseMoveEvent(self, e):
        if self._drag:
            self._apply(e.position().x())

    def mouseReleaseEvent(self, _):
        self._drag = None

    def _apply(self, x: float) -> None:
        t = self._t(x)
        if self._drag == "in":
            self.inRequested.emit(t)
        elif self._drag == "out":
            self.outRequested.emit(t)
        else:
            self.seekRequested.emit(t)


# --------------------------------------------------------------------------- meter

class MeterWidget(QWidget):
    MIN_DB = -60.0
    MAX_DB = 6.0
    MARKS = [6, 0, -6, -12, -20, -30, -40, -60]

    def __init__(self, parent=None):
        super().__init__(parent)
        self.levels = [-120.0, -120.0]
        self.holds = [-120.0, -120.0]
        self.hold_times = [0.0, 0.0]
        self.clipped = False
        self.setMinimumSize(60, 240)
        self.setToolTip("クリップ表示はクリックでリセット")

    def frac(self, db: float) -> float:
        return (min(self.MAX_DB, max(self.MIN_DB, db)) - self.MIN_DB) / (self.MAX_DB - self.MIN_DB)

    def push(self, peaks) -> None:
        now = time.monotonic()
        for c in range(2):
            pk = float(peaks[c]) if c < len(peaks) else 0.0
            db = gain_to_db(pk)
            self.levels[c] = max(db, self.levels[c] - 1.2, -120.0)
            if db >= self.holds[c]:
                self.holds[c] = db
                self.hold_times[c] = now
            elif now - self.hold_times[c] > 1.5:
                self.holds[c] = max(self.holds[c] - 1.5, self.levels[c])
            if pk >= 1.0:
                self.clipped = True
        self.update()

    def mousePressEvent(self, _):
        self.clipped = False
        self.holds = [-120.0, -120.0]
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        bar_w, gap, top, bottom = 10, 3, 14, 30
        h = self.height() - top - bottom
        p.setBrush(RED if self.clipped else QColor(255, 59, 48, 45))
        p.setPen(Qt.NoPen)
        p.drawRoundedRect(QRectF(0, 0, bar_w * 2 + gap, 8), 2, 2)
        grad = QLinearGradient(0, top + h, 0, top)
        grad.setColorAt(0.0, QColor("#30d158"))
        grad.setColorAt(0.70, QColor("#30d158"))
        grad.setColorAt(0.76, QColor("#ffd60a"))
        grad.setColorAt(0.86, QColor("#ff9f0a"))
        grad.setColorAt(0.91, RED)
        for c in range(2):
            x = c * (bar_w + gap)
            p.fillRect(QRectF(x, top, bar_w, h), QColor(0, 0, 0, 200))
            lh = h * self.frac(self.levels[c])
            p.fillRect(QRectF(x, top + h - lh, bar_w, lh), QBrush(grad))
            if self.holds[c] > self.MIN_DB:
                y = top + h - h * self.frac(self.holds[c])
                p.fillRect(QRectF(x, y - 1, bar_w, 2), RED if self.holds[c] >= 0 else QColor(255, 255, 255, 230))
        font = QFont(self.font())
        font.setPointSizeF(7)
        p.setFont(font)
        p.setPen(QColor(160, 160, 160))
        sx = 2 * bar_w + gap + 4
        for m in self.MARKS:
            y = top + h - h * self.frac(m)
            p.drawText(QPointF(sx, y + 3), f"+{m}" if m > 0 else str(m))
        p.drawText(QPointF(2, top + h + 12), "L")
        p.drawText(QPointF(bar_w + gap + 2, top + h + 12), "R")
        peak = max(self.holds)
        p.setPen(RED if self.clipped else QColor(170, 170, 170))
        p.drawText(QPointF(0, top + h + 26), "-∞" if peak <= -100 else f"{peak:.1f}")


# --------------------------------------------------------------------------- fader

FADER_POINTS = [(-60, 0.0), (-40, 0.12), (-30, 0.22), (-20, 0.36), (-10, 0.55), (-5, 0.66), (0, 0.78), (6, 0.89), (12, 1.0)]


def fader_pos(db: float) -> float:
    if db <= FADER_POINTS[0][0]:
        return 0.0
    for (d0, p0), (d1, p1) in zip(FADER_POINTS, FADER_POINTS[1:]):
        if db <= d1:
            return p0 + (db - d0) / (d1 - d0) * (p1 - p0)
    return 1.0


def fader_db(pos: float) -> float:
    if pos <= 0:
        return FADER_POINTS[0][0]
    for (d0, p0), (d1, p1) in zip(FADER_POINTS, FADER_POINTS[1:]):
        if pos <= p1:
            return d0 + (pos - p0) / (p1 - p0) * (d1 - d0)
    return FADER_POINTS[-1][0]


class FaderWidget(QWidget):
    valueChanged = Signal(float)
    KNOB_H = 30
    MARKS = [12, 6, 0, -5, -10, -20, -30, -40, -60]

    def __init__(self, parent=None):
        super().__init__(parent)
        self.db = 0.0
        self._drag_start: Optional[tuple[float, float]] = None
        self.setMinimumSize(76, 240)
        self.setToolTip("ドラッグで音量調整（Shift で微調整、ダブルクリックで 0 dB）")

    def set_db(self, db: float) -> None:
        self.db = max(SILENCE_DB, min(12.0, db))
        self.update()

    def _travel(self) -> float:
        return self.height() - self.KNOB_H

    def _y(self, db: float) -> float:
        return (1 - fader_pos(db)) * self._travel() + self.KNOB_H / 2

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        cx = self.width() / 2 + 10
        font = QFont(self.font())
        font.setPointSizeF(7)
        p.setFont(font)
        for m in self.MARKS:
            y = self._y(m)
            p.setPen(QColor(220, 220, 220) if m == 0 else QColor(150, 150, 150))
            p.drawText(QRectF(0, y - 6, 22, 12), Qt.AlignRight | Qt.AlignVCenter,
                       "-∞" if m <= -60 else (f"+{m}" if m > 0 else str(m)))
            p.setPen(QPen(QColor(150, 150, 150, 230 if m == 0 else 110), 1))
            half = 15 if m == 0 else 11
            p.drawLine(QPointF(cx - half, y), QPointF(cx + half, y))
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(0, 0, 0, 190))
        p.drawRoundedRect(QRectF(cx - 2.5, self.KNOB_H / 2, 5, self._travel()), 2, 2)
        y = self._y(self.db)
        knob = QRectF(cx - 18, y - self.KNOB_H / 2, 36, self.KNOB_H)
        grad = QLinearGradient(knob.topLeft(), knob.bottomLeft())
        grad.setColorAt(0, QColor(220, 220, 220))
        grad.setColorAt(1, QColor(140, 140, 140))
        p.setBrush(grad)
        p.setPen(QPen(QColor(0, 0, 0, 110), 0.5))
        p.drawRoundedRect(knob, 4, 4)
        p.fillRect(QRectF(knob.left(), y - 1, knob.width(), 2), QColor(20, 20, 20))

    def mousePressEvent(self, e):
        self._drag_start = (e.position().y(), fader_pos(self.db))

    def mouseMoveEvent(self, e):
        if not self._drag_start:
            return
        y0, p0 = self._drag_start
        fine = 0.2 if e.modifiers() & Qt.ShiftModifier else 1.0
        pos = max(0.0, min(1.0, p0 - (e.position().y() - y0) / max(self._travel(), 1) * fine))
        self._emit(round(fader_db(pos), 1))

    def mouseReleaseEvent(self, _):
        self._drag_start = None

    def mouseDoubleClickEvent(self, _):
        self._emit(0.0)

    def wheelEvent(self, e):
        step = 0.5 if e.angleDelta().y() > 0 else -0.5
        self._emit(round(self.db + step, 1))

    def _emit(self, db: float) -> None:
        self.set_db(db)
        self.valueChanged.emit(self.db)
