"""Entry point.

GUI:       python -m easymovtrim_win [file]
Headless:  python -m easymovtrim_win --export IN OUT [--in S] [--out S] [--quality light|high]
                    [--fadein S] [--fadeout S] [--volume DB] [--plugin PATH]
"""
from __future__ import annotations

import argparse
import sys
import threading


def run_headless(argv: list[str]) -> int:
    from . import media
    from .audio_engine import AudioParams, PluginSlot, db_to_gain, load_plugin
    from .exporter import HIGH, LIGHT, export

    ap = argparse.ArgumentParser(prog="EasyMovTrim")
    ap.add_argument("--export", nargs=2, metavar=("IN", "OUT"), required=True)
    ap.add_argument("--in", dest="start", type=float, default=0.0)
    ap.add_argument("--out", dest="end", type=float)
    ap.add_argument("--quality", choices=["light", "high"], default="high")
    ap.add_argument("--fadein", type=float)
    ap.add_argument("--fadeout", type=float)
    ap.add_argument("--volume", type=float, default=0.0)
    ap.add_argument("--plugin", action="append", default=[])
    a = ap.parse_args(argv)

    src, dst = a.export
    info = media.probe(src)
    end = a.end if a.end is not None else info.duration
    norm = lambda v: min(5.0, max(0.1, round(v, 1)))
    params = AudioParams(
        gain=db_to_gain(a.volume),
        fade_in_on=a.fadein is not None, fade_in=norm(a.fadein or 1.0),
        fade_out_on=a.fadeout is not None, fade_out=norm(a.fadeout or 1.0),
        trim_start=a.start, trim_end=end,
    )
    slots = []
    for p in a.plugin:
        plugin = load_plugin(p)
        slots.append(PluginSlot(name=getattr(plugin, "name", p), path=p, plugin=plugin))
        print(f"plugin: {slots[-1].name}")

    def progress(p: float) -> None:
        sys.stderr.write(f"\rexport {p * 100:5.1f}%")

    export(info, dst, a.start, end, LIGHT if a.quality == "light" else HIGH, params, slots,
           threading.Lock(), progress, threading.Event())
    print(f"\ndone: {dst}")
    return 0


def main() -> int:
    if "--export" in sys.argv:
        try:
            return run_headless(sys.argv[1:])
        except SystemExit:
            raise
        except BaseException:
            # A windowed (no console) build would otherwise show a blocking error dialog.
            import os
            import tempfile
            import traceback
            text = traceback.format_exc()
            try:
                sys.stderr.write(text)
            except Exception:
                pass
            with open(os.path.join(tempfile.gettempdir(), "easymovtrim_error.log"), "w", encoding="utf-8") as f:
                f.write(text)
            return 1
    from .ui import run_gui
    return run_gui(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
