# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec: pyinstaller windows/EasyMovTrim.spec
# Put ffmpeg(.exe) / ffprobe(.exe) in windows/ffmpeg_bin/ before building.
import os
import sys

here = os.path.abspath(SPECPATH)
pkg = os.path.join(here, "easymovtrim_win")
ext = ".exe" if sys.platform == "win32" else ""

binaries = []
for name in ("ffmpeg", "ffprobe"):
    p = os.path.join(here, "ffmpeg_bin", name + ext)
    if os.path.exists(p):
        binaries.append((p, "ffmpeg"))
    else:
        print(f"WARNING: {p} not found - the build will rely on a system ffmpeg")

datas = [
    (os.path.join(pkg, "assets"), "assets"),
    *([(os.path.join(here, "ffmpeg_bin", f), "ffmpeg") for f in os.listdir(os.path.join(here, "ffmpeg_bin"))
       if f.endswith(".txt")] if os.path.isdir(os.path.join(here, "ffmpeg_bin")) else []),
    (os.path.join(here, "..", "THIRD_PARTY_NOTICES.md"), "."),
    (os.path.join(here, "..", "LICENSE"), "."),
    (os.path.join(here, "..", "licenses"), "licenses"),
]

a = Analysis(
    [os.path.join(here, "launcher.py")],
    pathex=[here],
    binaries=binaries,
    datas=datas,
    hiddenimports=["pedalboard_native", "PySide6.QtMultimedia", "PySide6.QtMultimediaWidgets"],
    excludes=["tkinter", "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets", "PySide6.Qt3DCore",
              "PySide6.QtQuick3D", "PySide6.QtCharts", "PySide6.QtDataVisualization", "PySide6.QtPdf"],
    noarchive=False,
)
# PortAudio's ASIO build is covered by Steinberg's separate ASIO SDK license; ship only the default build.
a.binaries = [b for b in a.binaries if "asio" not in os.path.basename(b[0]).lower()]
a.datas = [d for d in a.datas if "asio" not in os.path.basename(d[0]).lower()]

pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="EasyMovTrim",
    console=False,
    icon=os.path.join(pkg, "assets", "icon.ico"),
    version=os.path.join(here, "version_info.txt") if sys.platform == "win32" else None,
)
coll = COLLECT(exe, a.binaries, a.datas, name="EasyMovTrim")
