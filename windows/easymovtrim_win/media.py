"""ffmpeg / ffprobe helpers: probing, audio decoding, thumbnails, proxies."""
from __future__ import annotations

import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

SAMPLE_RATE = 48_000
CHANNELS = 2

# Hide console windows spawned by subprocess on Windows.
_NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0

ProgressFn = Callable[[float], None]


class Cancelled(Exception):
    pass


class MediaError(Exception):
    pass


# --------------------------------------------------------------------------- paths

def resource_dir() -> Path:
    """Folder containing bundled resources (PyInstaller) or the package folder."""
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parent


_TEMP_DIR: Optional[Path] = None


def temp_dir() -> Path:
    global _TEMP_DIR
    if _TEMP_DIR is None:
        _TEMP_DIR = Path(tempfile.mkdtemp(prefix="easymovtrim_"))
        atexit.register(lambda: shutil.rmtree(_TEMP_DIR, ignore_errors=True))
    return _TEMP_DIR


def find_tool(name: str) -> Optional[str]:
    exe = name + (".exe" if sys.platform == "win32" else "")
    candidates = [
        resource_dir() / "ffmpeg" / exe,
        resource_dir() / exe,
        Path(sys.executable).parent / "ffmpeg" / exe,
        Path(sys.executable).parent / exe,
    ]
    for c in candidates:
        if c.is_file():
            return str(c)
    found = shutil.which(name)
    if found:
        return found
    for d in ("/opt/homebrew/bin", "/usr/local/bin"):
        p = Path(d) / name
        if p.is_file():
            return str(p)
    return None


def ffmpeg_path() -> str:
    p = find_tool("ffmpeg")
    if not p:
        raise MediaError("ffmpeg が見つかりません。アプリを再インストールしてください。")
    return p


def ffprobe_path() -> str:
    p = find_tool("ffprobe")
    if not p:
        raise MediaError("ffprobe が見つかりません。アプリを再インストールしてください。")
    return p


# --------------------------------------------------------------------------- probe

@dataclass
class MediaInfo:
    path: str
    duration: float
    width: int          # display width (rotation applied)
    height: int         # display height
    fps: float
    has_video: bool
    has_audio: bool
    video_codec: str
    audio_channels: int

    @property
    def summary(self) -> str:
        parts = [f"{self.width}×{self.height}", f"{self.fps:.2f}fps", format_timecode(self.duration)]
        if not self.has_audio:
            parts.append("音声なし")
        return "  ·  ".join(parts)


def _parse_rate(s: str) -> float:
    try:
        if "/" in s:
            a, b = s.split("/")
            return float(a) / float(b) if float(b) else 0.0
        return float(s)
    except (ValueError, ZeroDivisionError):
        return 0.0


def probe(path: str) -> MediaInfo:
    args = [ffprobe_path(), "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]
    r = subprocess.run(args, capture_output=True, creationflags=_NO_WINDOW)
    if r.returncode != 0:
        raise MediaError("ファイルを読み込めません。\n" + r.stderr.decode("utf-8", "replace")[-800:])
    data = json.loads(r.stdout.decode("utf-8", "replace") or "{}")
    fmt = data.get("format", {})
    duration = float(fmt.get("duration") or 0)
    video = next((s for s in data.get("streams", []) if s.get("codec_type") == "video"
                  and not s.get("disposition", {}).get("attached_pic")), None)
    audio = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), None)
    if video is None:
        raise MediaError("映像トラックが見つかりません。")
    w, h = int(video.get("width") or 0), int(video.get("height") or 0)
    rotation = 0
    for sd in video.get("side_data_list", []) or []:
        if "rotation" in sd:
            rotation = int(float(sd["rotation"]))
    if "rotate" in (video.get("tags") or {}):
        rotation = int(float(video["tags"]["rotate"]))
    if abs(rotation) % 180 == 90:
        w, h = h, w
    sar = _parse_rate(video.get("sample_aspect_ratio", "1:1").replace(":", "/")) or 1.0
    if sar and abs(sar - 1.0) > 0.01:
        w = int(round(w * sar / 2)) * 2
    fps = _parse_rate(video.get("avg_frame_rate", "0/0")) or _parse_rate(video.get("r_frame_rate", "0/0")) or 30.0
    if duration <= 0:
        duration = float(video.get("duration") or 0)
    return MediaInfo(
        path=path, duration=duration, width=w, height=h, fps=fps,
        has_video=True, has_audio=audio is not None,
        video_codec=str(video.get("codec_name", "")),
        audio_channels=int(audio.get("channels") or 0) if audio else 0,
    )


# --------------------------------------------------------------------------- running ffmpeg

def run_ffmpeg(args: list[str], duration: float, progress: Optional[ProgressFn] = None,
               cancel: Optional[threading.Event] = None) -> None:
    """Runs ffmpeg with `-progress pipe:1`, reporting 0..1 progress. Raises on failure / cancel."""
    cmd = [ffmpeg_path(), "-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"] + args
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, creationflags=_NO_WINDOW)
    err_tail: list[bytes] = []

    def read_err():
        assert proc.stderr is not None
        for line in proc.stderr:
            err_tail.append(line)
            if len(err_tail) > 40:
                del err_tail[:20]

    t = threading.Thread(target=read_err, daemon=True)
    t.start()
    assert proc.stdout is not None
    for raw in proc.stdout:
        if cancel is not None and cancel.is_set():
            proc.kill()
            proc.wait()
            raise Cancelled()
        line = raw.decode("ascii", "ignore").strip()
        if line.startswith("out_time_us=") and progress and duration > 0:
            try:
                us = float(line.split("=", 1)[1])
                progress(max(0.0, min(1.0, us / 1e6 / duration)))
            except ValueError:
                pass
    proc.wait()
    t.join(timeout=2)
    if cancel is not None and cancel.is_set():
        raise Cancelled()
    if proc.returncode != 0:
        tail = b"".join(err_tail[-8:]).decode("utf-8", "replace")
        raise MediaError(f"ffmpeg の処理に失敗しました。\n{tail}")


_ENCODERS: Optional[set[str]] = None


def available_encoders() -> set[str]:
    global _ENCODERS
    if _ENCODERS is None:
        r = subprocess.run([ffmpeg_path(), "-hide_banner", "-encoders"], capture_output=True,
                           creationflags=_NO_WINDOW)
        names = set()
        for line in r.stdout.decode("utf-8", "replace").splitlines():
            parts = line.split()
            if len(parts) >= 2 and len(parts[0]) == 6:
                names.add(parts[1])
        _ENCODERS = names
    return _ENCODERS


# --------------------------------------------------------------------------- audio / thumbnails / proxy

def decode_audio(path: str, out_path: Path, duration: float, progress: Optional[ProgressFn] = None,
                 cancel: Optional[threading.Event] = None, start: float = 0.0,
                 length: Optional[float] = None) -> None:
    """Decodes the first audio stream to raw float32 stereo 48 kHz."""
    args: list[str] = []
    if start > 0:
        args += ["-ss", f"{start:.6f}"]
    args += ["-i", path]
    if length is not None:
        args += ["-t", f"{length:.6f}"]
    args += ["-map", "0:a:0", "-vn", "-sn", "-dn", "-ac", str(CHANNELS), "-ar", str(SAMPLE_RATE),
             "-f", "f32le", str(out_path)]
    run_ffmpeg(args, length if length is not None else duration, progress, cancel)


def thumbnail_png(path: str, t: float, height: int = 96) -> Optional[bytes]:
    cmd = [ffmpeg_path(), "-hide_banner", "-nostdin", "-v", "error", "-ss", f"{max(0.0, t):.3f}", "-i", path,
           "-frames:v", "1", "-vf", f"scale=-2:{height}", "-f", "image2pipe", "-vcodec", "png", "-"]
    r = subprocess.run(cmd, capture_output=True, creationflags=_NO_WINDOW)
    return r.stdout if r.returncode == 0 and r.stdout else None


def h264_encoder_args(bitrate: int, crf: int, quality_preset: str = "medium") -> list[list[str]]:
    """Candidate H.264 encoder argument lists, best first."""
    enc = available_encoders()
    out: list[list[str]] = []
    if "libx264" in enc:
        out.append(["-c:v", "libx264", "-preset", quality_preset, "-crf", str(crf),
                    "-maxrate", str(int(bitrate * 1.5)), "-bufsize", str(int(bitrate * 3)),
                    "-profile:v", "high"])
    for hw in ("h264_mf", "h264_videotoolbox", "h264_nvenc", "h264_qsv", "h264_amf"):
        if hw in enc:
            out.append(["-c:v", hw, "-b:v", str(bitrate)])
    if "libopenh264" in enc:
        out.append(["-c:v", "libopenh264", "-b:v", str(bitrate)])
    return out


def make_preview_proxy(info: MediaInfo, out_path: Path, progress: Optional[ProgressFn] = None,
                       cancel: Optional[threading.Event] = None) -> None:
    """Video-only H.264 proxy for formats the Qt player cannot display."""
    last: Exception = MediaError("H.264 エンコーダーがありません")
    for enc in h264_encoder_args(8_000_000, 20, "veryfast"):
        try:
            run_ffmpeg(["-i", info.path, "-map", "0:v:0", "-an", "-sn", "-dn",
                        "-vf", "scale=trunc(iw*sar/2)*2:trunc(ih/2)*2,setsar=1,format=yuv420p"]
                       + enc + [str(out_path)], info.duration, progress, cancel)
            return
        except Cancelled:
            raise
        except Exception as e:  # try the next encoder
            last = e
    raise last


def format_timecode(seconds: float) -> str:
    s = max(0.0, seconds)
    h = int(s // 3600)
    m = int((s % 3600) // 60)
    return f"{h:02d}:{m:02d}:{s % 60:06.3f}"
