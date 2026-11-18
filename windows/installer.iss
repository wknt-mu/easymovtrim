; Inno Setup script: builds EasyMovTrim-<version>-windows-setup.exe
; iscc /DAppVersion=1.0.0 windows\installer.iss   (run after PyInstaller)

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{8C6E2E0B-4E57-4C2F-9A43-6B1E8F3D2A71}
AppName=EasyMovTrim
AppVersion={#AppVersion}
AppPublisher=Naoto Iwaki
AppCopyright=Copyright (C) 2026 Naoto Iwaki
AppPublisherURL=https://github.com/wknt-mu/easymovtrim
AppSupportURL=https://github.com/wknt-mu/easymovtrim/issues
AppUpdatesURL=https://github.com/wknt-mu/easymovtrim/releases
VersionInfoVersion={#AppVersion}
VersionInfoCopyright=Copyright (C) 2026 Naoto Iwaki
LicenseFile=..\LICENSE
DefaultDirName={autopf}\EasyMovTrim
DefaultGroupName=EasyMovTrim
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=EasyMovTrim-{#AppVersion}-windows-setup
SetupIconFile=easymovtrim_win\assets\icon.ico
UninstallDisplayIcon={app}\EasyMovTrim.exe
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
InfoBeforeFile=README_WINDOWS.txt

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "dist\EasyMovTrim\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "README_WINDOWS.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\EasyMovTrim"; Filename: "{app}\EasyMovTrim.exe"
Name: "{group}\{cm:UninstallProgram,EasyMovTrim}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\EasyMovTrim"; Filename: "{app}\EasyMovTrim.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\EasyMovTrim.exe"; Description: "{cm:LaunchProgram,EasyMovTrim}"; Flags: nowait postinstall skipifsilent
