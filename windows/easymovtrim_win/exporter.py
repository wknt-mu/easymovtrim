"""Trim + MP4 export. Audio is rendered offline through the same chain as preview."""
from __future__ import annotations

import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import numpy as np

from . import media
from .audio_engine import AudioParams, PluginSlot, process_block
from .media import CHANNELS, SAMPLE_RATE, MediaInfo


@dataclass(frozen=True)
class Quality:
    key: str
    title: str
    detail: str
    max_long: int          # 0 = keep source size
    max_short: int
    crf: int
    audio_bitrate: str
    bpp: float             # bits per pixel for bitrate based encoders
    min_rate: int
    max_rate: int


LIGHT = Quality("light", "軽量", "H.264・最大720p・低ビットレート / AAC 128kbps",
                1280, 720, 26, "128k", 0.08, 800_000, 4_000_000)
HIGH = Quality("high", "高品質", "H.264・元の解像度・高画質 / AAC 256kbps",
               0, 0, 18, "256k", 0.2, 6_000_000, 60_000_000)
QUALITIES = [LIGHT, HIGH]


def target_size(info: MediaInfo, q: Quality) -> tuple[int, int]:
    w, h = max(info.width, 2), max(info.height, 2)
    if q.max_long:
        scale = min(1.0, q.max_long / max(w, h), q.max_short / min(w, h))
        w, h = w * scale, h * scale
    return int(round(w / 2)) * 2, int(round(h / 2)) * 2


def export(info: MediaInfo, out_path: str, start: float, end: float, quality: Quality,
           params: AudioParams, slots: list[PluginSlot], chain_lock: threading.Lock,
           progress: Callable[[float], None], cancel: threading.Event) -> None:
    duration = max(0.01, end - start)
    work = media.temp_dir()
    tag = uuid.uuid4().hex[:8]
    audio_in = work / f"export_{tag}_in.f32"
    audio_out = work / f"export_{tag}_out.f32"
    try:
        has_audio = info.has_audio
        if has_audio:
            media.decode_audio(info.path, audio_in, info.duration, lambda p: progress(p * 0.08), cancel,
                               start=start, length=duration)
            _render_audio(audio_in, audio_out, start, duration, params, slots, chain_lock,
                          lambda p: progress(0.08 + p * 0.07), cancel)

        w, h = target_size(info, quality)
        fps = info.fps if info.fps > 0 else 30
        bitrate = int(min(max(w * h * min(fps, 120) * quality.bpp, quality.min_rate), quality.max_rate))
        vf = f"scale={w}:{h}:flags=lanczos,setsar=1,format=yuv420p"

        base = ["-ss", f"{start:.6f}", "-i", info.path]
        if has_audio:
            base += ["-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", str(CHANNELS), "-i", str(audio_out)]
        base += ["-t", f"{duration:.6f}", "-map", "0:v:0"]
        if has_audio:
            base += ["-map", "1:a:0", "-c:a", "aac", "-b:a", quality.audio_bitrate, "-ar", str(SAMPLE_RATE)]
        base += ["-vf", vf, "-g", str(max(1, int(round(fps * 2)))), "-sn", "-dn",
                 "-map_metadata", "-1", "-movflags", "+faststart"]

        encoders = media.h264_encoder_args(bitrate, quality.crf)
        if not encoders:
            raise media.MediaError("H.264 エンコーダーが見つかりません。")
        last: Exception = media.MediaError("書き出しに失敗しました")
        for enc in encoders:
            try:
                media.run_ffmpeg(base + enc + ["-f", "mp4", out_path], duration,
                                 lambda p: progress(0.15 + p * 0.85), cancel)
                progress(1.0)
                return
            except media.Cancelled:
                raise
            except Exception as e:
                last = e
        raise last
    except media.Cancelled:
        Path(out_path).unlink(missing_ok=True)
        raise
    finally:
        audio_in.unlink(missing_ok=True)
        audio_out.unlink(missing_ok=True)


def _render_audio(src: Path, dst: Path, start: float, duration: float, params: AudioParams,
                  slots: list[PluginSlot], chain_lock: threading.Lock,
                  progress: Callable[[float], None], cancel: threading.Event) -> None:
    raw = np.fromfile(src, dtype=np.float32)
    data = raw[: len(raw) - len(raw) % CHANNELS].reshape(-1, CHANNELS)
    total = int(round(duration * SAMPLE_RATE))
    if len(data) < total:
        data = np.vstack([data, np.zeros((total - len(data), CHANNELS), np.float32)])
    data = data[:total]

    with chain_lock:
        for s in slots:
            try:
                s.plugin.reset()
            except Exception:
                pass
    block = 8192
    start_frame = int(round(start * SAMPLE_RATE))
    out = np.empty_like(data)
    for i in range(0, total, block):
        if cancel.is_set():
            raise media.Cancelled()
        chunk = data[i:i + block]
        out[i:i + len(chunk)] = process_block(chunk, start_frame + i, slots, chain_lock, params,
                                              params.gain, preview=False, blocking=True)
        progress(min(1.0, (i + block) / max(total, 1)))
    with chain_lock:
        for s in slots:
            try:
                s.plugin.reset()
            except Exception:
                pass
    out.astype(np.float32).tofile(dst)
