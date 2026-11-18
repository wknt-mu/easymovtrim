# Builds the Windows package (run in PowerShell on Windows 10/11, x64).
#   powershell -ExecutionPolicy Bypass -File windows\build_windows.ps1
# Output (in ..\dist):
#   EasyMovTrim-<ver>-windows.zip            portable version
#   EasyMovTrim-<ver>-windows-setup.exe      installer (if Inno Setup 6 is installed)
param(
    [string]$Version = "1.0.0",
    [string]$FfmpegZipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-win64-lgpl-8.1.zip",
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # progress bars make downloads/unzips very slow
Set-Location $PSScriptRoot
$dist = Join-Path (Resolve-Path "..") "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# 1) Python environment
if (-not (Test-Path ".venv")) { & $Python -m venv .venv }
$py = ".\.venv\Scripts\python.exe"
& $py -m pip install --upgrade pip
& $py -m pip install -r requirements.txt pyinstaller==6.22.3

# 2) ffmpeg / ffprobe (LGPL build from BtbN/FFmpeg-Builds)
if (-not (Test-Path "ffmpeg_bin\ffmpeg.exe")) {
    New-Item -ItemType Directory -Force -Path "ffmpeg_bin", "build" | Out-Null
    $zip = "build\ffmpeg.zip"
    try {
        Invoke-WebRequest -Uri $FfmpegZipUrl -OutFile $zip
    } catch {
        Write-Host "falling back to the master build of ffmpeg"
        Invoke-WebRequest -Uri "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip" -OutFile $zip
    }
    Expand-Archive -Path $zip -DestinationPath "build\ffmpeg" -Force
    Get-ChildItem "build\ffmpeg" -Recurse -Include ffmpeg.exe, ffprobe.exe | Copy-Item -Destination "ffmpeg_bin" -Force
    Get-ChildItem "build\ffmpeg" -Recurse -Include LICENSE.txt | Select-Object -First 1 | Copy-Item -Destination "ffmpeg_bin\FFMPEG_LICENSE.txt" -Force
}

# Stamp the version into the app and the exe properties
(Get-Content easymovtrim_win\__init__.py -Raw) -replace 'APP_VERSION = "[^"]*"', "APP_VERSION = `"$Version`"" |
    Set-Content easymovtrim_win\__init__.py -Encoding utf8
$parts = ($Version.Split(".") + @("0", "0", "0"))[0..3] -join ", "
(Get-Content version_info.txt -Raw) -replace "1\.0\.0", $Version -replace "\(1, 0, 0, 0\)", "($parts)" |
    Set-Content version_info.txt -Encoding utf8

# 3) PyInstaller
& $py -m PyInstaller --noconfirm EasyMovTrim.spec
Copy-Item README_WINDOWS.txt "dist\EasyMovTrim\README.txt" -Force

# 4) Smoke test: export a generated clip headlessly
$test = "build\smoke"
New-Item -ItemType Directory -Force -Path $test | Out-Null
& "ffmpeg_bin\ffmpeg.exe" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=30:duration=4" `
    -f lavfi -i "sine=frequency=440:duration=4" -c:v mpeg4 -c:a pcm_s16le "$test\in.avi"
$errLog = Join-Path $env:TEMP "easymovtrim_error.log"
if (Test-Path $errLog) { Remove-Item $errLog }
$p = Start-Process -FilePath "dist\EasyMovTrim\EasyMovTrim.exe" -PassThru `
    -ArgumentList @("--export", "$test\in.avi", "$test\out.mp4", "--in", "1", "--out", "3", "--quality", "light", "--fadein", "0.5")
$null = $p.Handle   # keeps ExitCode available after WaitForExit
if (-not $p.WaitForExit(300000)) { $p.Kill(); throw "smoke test timed out" }
if (Test-Path $errLog) { Get-Content $errLog | Write-Host }
if ($p.ExitCode -ne 0 -or -not (Test-Path "$test\out.mp4")) { throw "smoke test failed (exit $($p.ExitCode))" }
& "ffmpeg_bin\ffprobe.exe" -v error -show_entries format=duration -of csv=p=0 "$test\out.mp4"
Write-Host "smoke test OK"

# 5) Corresponding source for the GPL/LGPL components (published next to the binaries)
$ffver = (& "ffmpeg_bin\ffmpeg.exe" -hide_banner -version | Select-Object -First 1).Split(" ")[2]
Write-Host "bundled ffmpeg version: $ffver"
$ref = $ffver
if ($ffver -match "-g([0-9a-f]{7,})") { $ref = $Matches[1] } else { $ref = $ffver.Split("-")[0] }
Invoke-WebRequest -Uri "https://github.com/FFmpeg/FFmpeg/archive/$ref.tar.gz" -OutFile (Join-Path $dist "ffmpeg-$ffver-source.tar.gz")
# pedalboard has no sdist on PyPI and GitHub archives omit submodules (JUCE, Rubber Band, LAME, ...),
# so clone the release tag with its submodules and pack it.
$pbdir = "build\pedalboard-0.9.26"
if (Test-Path $pbdir) { Remove-Item -Recurse -Force $pbdir }
git -c url."https://github.com/".insteadOf="git@github.com:" clone --quiet --depth 1 --branch v0.9.26 `
    --recurse-submodules --shallow-submodules https://github.com/spotify/pedalboard.git $pbdir
if ($LASTEXITCODE -ne 0) { throw "failed to fetch pedalboard source" }
tar -czf (Join-Path $dist "pedalboard-0.9.26-source.tar.gz") --exclude=.git -C build pedalboard-0.9.26
Write-Host "source archives copied to $dist"

# 6) Portable zip
$zipOut = Join-Path $dist "EasyMovTrim-$Version-windows.zip"
if (Test-Path $zipOut) { Remove-Item $zipOut }
Compress-Archive -Path "dist\EasyMovTrim" -DestinationPath $zipOut
Write-Host "created $zipOut"

# 7) Installer (Inno Setup 6)
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    foreach ($c in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
        if (Test-Path $c) { $iscc = $c }
    }
}
if ($iscc) {
    & $iscc "/DAppVersion=$Version" installer.iss
    Write-Host "created installer in $dist"
} else {
    Write-Host "Inno Setup 6 not found - skipped the installer (zip only)."
}
