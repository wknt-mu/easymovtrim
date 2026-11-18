"""Real-time audio playback with plugin chain, fader, fades and metering.

Signal flow (same as the macOS version): plugins -> fader gain -> fades -> meter.
The audio stream is the master clock for preview playback.
"""
from __future__ import annotations

import math
import os
import sys
import threading
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Optional

import numpy as np

from .media import CHANNELS, SAMPLE_RATE

try:
    import sounddevice as sd
except Exception:  # PortAudio missing: fall back to a silent clock
    sd = None

try:
    import pedalboard
except Exception:
    pedalboard = None

SILENCE_DB = -60.0


def db_to_gain(db: float) -> float:
    return 0.0 if db <= SILENCE_DB else 10 ** (db / 20)


def gain_to_db(g: float) -> float:
    return -120.0 if g <= 1e-6 else 20 * math.log10(g)


@dataclass
class AudioParams:
    gain: float = 1.0
    fade_in_on: bool = False
    fade_in: float = 1.0
    fade_out_on: bool = False
    fade_out: float = 1.0
    trim_start: float = 0.0
    trim_end: float = float("inf")


def fade_gains(t: np.ndarray, p: AudioParams, preview: bool) -> np.ndarray:
    """Equal-power fade curve. Outside the range: unfaded in preview, silent in export."""
    g = np.ones_like(t, dtype=np.float32)
    if p.fade_in_on and p.fade_in > 0:
        x = (t - p.trim_start) / p.fade_in
        g *= np.where(x < 1, np.sin(np.clip(x, 0, 1) * np.pi / 2), 1.0).astype(np.float32)
    if p.fade_out_on and p.fade_out > 0:
        x = (p.trim_end - t) / p.fade_out
        g *= np.where(x < 1, np.sin(np.clip(x, 0, 1) * np.pi / 2), 1.0).astype(np.float32)
    inside = (t >= p.trim_start) & (t <= p.trim_end)
    return np.where(inside, g, 1.0 if preview else 0.0).astype(np.float32)


# --------------------------------------------------------------------------- plugins

@dataclass
class PluginSlot:
    name: str
    path: str
    plugin: object
    bypassed: bool = False
    error: Optional[str] = None


def plugin_search_roots() -> list[Path]:
    roots: list[Path] = []
    if sys.platform == "win32":
        common = os.environ.get("COMMONPROGRAMFILES", r"C:\Program Files\Common Files")
        roots.append(Path(common) / "VST3")
        local = os.environ.get("LOCALAPPDATA")
        if local:
            roots.append(Path(local) / "Programs" / "Common" / "VST3")
    elif sys.platform == "darwin":
        for base in (Path("/Library/Audio/Plug-Ins"), Path.home() / "Library/Audio/Plug-Ins"):
            roots += [base / "VST3", base / "Components"]
    else:
        roots += [Path.home() / ".vst3", Path("/usr/lib/vst3"), Path("/usr/local/lib/vst3")]
    return roots


def scan_plugins() -> list[Path]:
    """Lists VST3 bundles (and Audio Units on macOS) without loading them."""
    found: list[Path] = []
    for root in plugin_search_roots():
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            keep = []
            for d in dirnames:
                if d.lower().endswith((".vst3", ".component")):
                    found.append(Path(dirpath) / d)
                else:
                    keep.append(d)
            dirnames[:] = keep
            for f in filenames:
                if f.lower().endswith(".vst3"):
                    found.append(Path(dirpath) / f)
    return sorted(set(found), key=lambda p: p.stem.lower())


def plugin_names_in(path: str) -> list[str]:
    if pedalboard is None:
        return []
    try:
        if path.lower().endswith(".vst3"):
            return list(pedalboard.VST3Plugin.get_plugin_names_for_file(path))
        if hasattr(pedalboard, "AudioUnitPlugin"):
            return list(pedalboard.AudioUnitPlugin.get_plugin_names_for_file(path))
    except Exception:
        pass
    return []


def load_plugin(path: str, plugin_name: Optional[str] = None) -> object:
    if pedalboard is None:
        raise RuntimeError("pedalboard が利用できません")
    plugin = pedalboard.load_plugin(path, plugin_name=plugin_name) if plugin_name else pedalboard.load_plugin(path)
    if getattr(plugin, "is_instrument", False) and not getattr(plugin, "is_effect", True):
        raise RuntimeError("インストゥルメント（音源）プラグインは挿入できません。エフェクトを選んでください。")
    return plugin


# --------------------------------------------------------------------------- engine

class Meter:
    def __init__(self):
        self._lock = threading.Lock()
        self._peaks = np.zeros(CHANNELS, dtype=np.float32)

    def submit(self, block: np.ndarray) -> None:
        peaks = np.max(np.abs(block), axis=0) if len(block) else np.zeros(CHANNELS, np.float32)
        with self._lock:
            np.maximum(self._peaks, peaks, out=self._peaks)

    def read_and_reset(self) -> np.ndarray:
        with self._lock:
            p = self._peaks.copy()
            self._peaks[:] = 0
        return p


class AudioEngine:
    BLOCK = 1024

    def __init__(self):
        self.data: Optional[np.ndarray] = None  # (frames, 2) float32, may be a memmap
        self.total_frames = 0
        self.params = AudioParams()
        self.meter = Meter()
        self.slots: list[PluginSlot] = []
        self.chain_lock = threading.Lock()

        self._pos = 0                 # next frame to render
        self._playing = False
        self._loop = False
        self._stop_at: Optional[int] = None
        self._last_gain = 1.0
        self._latency_frames = 0
        self._play_started_at = 0
        self._stream = None
        self._fake_thread: Optional[threading.Thread] = None
        self._fake_stop = threading.Event()
        self.device_error: Optional[str] = None

    # ---- lifecycle

    def load(self, data: Optional[np.ndarray], duration: float) -> None:
        self.pause()
        self.data = data
        self.total_frames = len(data) if data is not None else int(duration * SAMPLE_RATE)
        self._pos = 0
        self._ensure_stream()
        self.reset_plugins()

    def _ensure_stream(self) -> None:
        if self._stream is not None or self._fake_thread is not None:
            return
        if sd is not None:
            try:
                self._stream = sd.OutputStream(samplerate=SAMPLE_RATE, channels=CHANNELS, dtype="float32",
                                               blocksize=self.BLOCK, latency="high", callback=self._callback)
                self._stream.start()
                self._latency_frames = int(float(self._stream.latency) * SAMPLE_RATE)
                return
            except Exception as e:
                self._stream = None
                self.device_error = f"オーディオ出力を開けません: {e}"
        # Silent clock so preview still works without an audio device.
        self._fake_stop.clear()
        self._fake_thread = threading.Thread(target=self._fake_loop, daemon=True)
        self._fake_thread.start()

    def _fake_loop(self) -> None:
        buf = np.zeros((self.BLOCK, CHANNELS), np.float32)
        period = self.BLOCK / SAMPLE_RATE
        next_t = time.monotonic()
        while not self._fake_stop.is_set():
            self._render(buf, self.BLOCK)
            next_t += period
            time.sleep(max(0.0, next_t - time.monotonic()))

    def close(self) -> None:
        self._playing = False
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        self._fake_stop.set()

    # ---- transport (called from the UI thread)

    @property
    def playing(self) -> bool:
        return self._playing

    def play(self, stop_at: Optional[float] = None, loop: bool = False) -> None:
        self._stop_at = int(stop_at * SAMPLE_RATE) if stop_at is not None else None
        self._loop = loop
        self._play_started_at = self._pos
        self._playing = True

    def set_loop(self, loop: bool) -> None:
        self._loop = loop

    def pause(self) -> None:
        if self._playing:
            self._playing = False
            self._pos = max(0, self.position_frames())

    def seek(self, seconds: float) -> None:
        self._pos = int(max(0.0, min(seconds, self.total_frames / SAMPLE_RATE)) * SAMPLE_RATE)
        self._play_started_at = self._pos
        self.reset_plugins()

    def position_frames(self) -> int:
        """Frame currently heard (render position minus output latency)."""
        if self._playing:
            return max(self._play_started_at, self._pos - self._latency_frames)
        return self._pos

    def position(self) -> float:
        return self.position_frames() / SAMPLE_RATE

    def set_params(self, params: AudioParams) -> None:
        self.params = replace(params)

    # ---- plugins

    def add_slot(self, slot: PluginSlot) -> None:
        with self.chain_lock:
            self.slots.append(slot)

    def remove_slot(self, slot: PluginSlot) -> None:
        with self.chain_lock:
            if slot in self.slots:
                self.slots.remove(slot)

    def move_slot(self, slot: PluginSlot, delta: int) -> None:
        with self.chain_lock:
            i = self.slots.index(slot)
            j = i + delta
            if 0 <= j < len(self.slots):
                self.slots[i], self.slots[j] = self.slots[j], self.slots[i]

    def reset_plugins(self) -> None:
        with self.chain_lock:
            for s in self.slots:
                try:
                    s.plugin.reset()
                except Exception:
                    pass

    # ---- rendering (audio thread)

    def _callback(self, outdata, frames, time_info, status) -> None:  # sounddevice signature
        self._render(outdata, frames)

    def _render(self, outdata: np.ndarray, frames: int) -> None:
        if not self._playing:
            outdata.fill(0)
            return
        start = self._pos
        block = np.zeros((frames, CHANNELS), np.float32)
        end = start + frames
        loop_end = self._stop_at
        if self.data is not None and start < self.total_frames:
            n = min(frames, self.total_frames - start)
            block[:n] = self.data[start:start + n]

        processed = process_block(block, start, self.slots, self.chain_lock, self.params,
                                  self._last_gain, preview=True, blocking=False)
        self._last_gain = self.params.gain
        self.meter.submit(processed)
        outdata[:] = processed

        self._pos = end
        if self._loop:
            p = self.params
            in_f, out_f = int(p.trim_start * SAMPLE_RATE), int(min(p.trim_end, self.total_frames / SAMPLE_RATE) * SAMPLE_RATE)
            if self._pos >= out_f and out_f > in_f:
                self._pos = in_f
                self._play_started_at = in_f
        elif loop_end is not None and self._pos >= loop_end:
            self._playing = False
            self._pos = loop_end
        if self._pos >= self.total_frames and not self._loop:
            self._playing = False
            self._pos = self.total_frames


def process_block(block: np.ndarray, start_frame: int, slots: list[PluginSlot], lock: threading.Lock,
                  params: AudioParams, from_gain: float, preview: bool, blocking: bool) -> np.ndarray:
    """Runs one (frames, 2) block through plugins, fader and fades."""
    frames = len(block)
    out = block
    acquired = lock.acquire(blocking=blocking)
    if acquired:
        try:
            if any(not s.bypassed and s.error is None for s in slots):
                planar = np.ascontiguousarray(block.T)
                for s in slots:
                    if s.bypassed or s.error is not None:
                        continue
                    try:
                        planar = s.plugin.process(planar, SAMPLE_RATE, buffer_size=max(frames, 1), reset=False)
                    except Exception as e:  # keep audio running; mark the plugin
                        s.error = str(e)
                if planar.shape[0] == 1:
                    planar = np.repeat(planar, CHANNELS, axis=0)
                planar = planar[:CHANNELS, :frames]
                if planar.shape[1] < frames:
                    planar = np.pad(planar, ((0, 0), (0, frames - planar.shape[1])))
                out = np.ascontiguousarray(planar.T, dtype=np.float32)
        finally:
            lock.release()

    ramp = np.linspace(from_gain, params.gain, frames, endpoint=True, dtype=np.float32)
    t = (start_frame + np.arange(frames, dtype=np.float64)) / SAMPLE_RATE
    g = ramp * fade_gains(t, params, preview)
    return (out * g[:, None]).astype(np.float32, copy=False)
