# Builds the Windows package (run in PowerShell on Windows 10/11, x64).
#   powershell -ExecutionPolicy Bypass -File windows\build_windows.ps1
# Output (in ..\dist):
#   EasyMovTrim-<ver>-windows.zip            portable version
#   EasyMovTrim-<ver>-windows-setup.exe      installer (if Inno Setup 6 is installed)
param(
    [string]$Version = "1.0.0",
    [string]$FfmpegZipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.0-latest-win64-gpl-8.0.zip",
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$dist = Join-Path (Resolve-Path "..") "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# 1) Python environment
if (-not (Test-Path ".venv")) { & $Python -m venv .venv }
$py = ".\.venv\Scripts\python.exe"
& $py -m pip install --upgrade pip
& $py -m pip install -r requirements.txt pyinstaller==6.22.3

# 2) ffmpeg / ffprobe (GPL build from BtbN/FFmpeg-Builds)
if (-not (Test-Path "ffmpeg_bin\ffmpeg.exe")) {
    New-Item -ItemType Directory -Force -Path "ffmpeg_bin", "build" | Out-Null
    $zip = "build\ffmpeg.zip"
    try {
        Invoke-WebRequest -Uri $FfmpegZipUrl -OutFile $zip
    } catch {
        Write-Host "falling back to the master build of ffmpeg"
        Invoke-WebRequest -Uri "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile $zip
    }
    Expand-Archive -Path $zip -DestinationPath "build\ffmpeg" -Force
    Get-ChildItem "build\ffmpeg" -Recurse -Include ffmpeg.exe, ffprobe.exe | Copy-Item -Destination "ffmpeg_bin" -Force
    Get-ChildItem "build\ffmpeg" -Recurse -Include LICENSE.txt | Select-Object -First 1 | Copy-Item -Destination "ffmpeg_bin\FFMPEG_LICENSE.txt" -Force
}

# 3) PyInstaller
& $py -m PyInstaller --noconfirm EasyMovTrim.spec
Copy-Item README_WINDOWS.txt "dist\EasyMovTrim\README.txt" -Force

# 4) Smoke test: export a generated clip headlessly
$test = "build\smoke"
New-Item -ItemType Directory -Force -Path $test | Out-Null
& "ffmpeg_bin\ffmpeg.exe" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=30:duration=4" `
    -f lavfi -i "sine=frequency=440:duration=4" -c:v mpeg4 -c:a libmp3lame "$test\in.avi"
$p = Start-Process -FilePath "dist\EasyMovTrim\EasyMovTrim.exe" -Wait -PassThru `
    -ArgumentList @("--export", "$test\in.avi", "$test\out.mp4", "--in", "1", "--out", "3", "--quality", "light", "--fadein", "0.5")
if ($p.ExitCode -ne 0 -or -not (Test-Path "$test\out.mp4")) { throw "smoke test failed (exit $($p.ExitCode))" }
Write-Host "smoke test OK"

# 5) Portable zip
$zipOut = Join-Path $dist "EasyMovTrim-$Version-windows.zip"
if (Test-Path $zipOut) { Remove-Item $zipOut }
Compress-Archive -Path "dist\EasyMovTrim" -DestinationPath $zipOut
Write-Host "created $zipOut"

# 6) Installer (Inno Setup 6)
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
