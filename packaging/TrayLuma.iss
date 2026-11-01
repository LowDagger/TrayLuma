#ifndef AppVersion
  #define AppVersion "1.2.0"
#endif
[Setup]
AppId={{D07CFD16-B19C-44A3-85E7-663486E43068}
AppName=TrayLuma
AppVersion={#AppVersion}
AppPublisher=LowDagger
AppPublisherURL=https://github.com/LowDagger/TrayLuma
AppSupportURL=https://github.com/LowDagger/TrayLuma/issues
AppUpdatesURL=https://github.com/LowDagger/TrayLuma/releases
DefaultDirName={localappdata}\Programs\TrayLuma
DefaultGroupName=TrayLuma
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
OutputDir=..\dist
OutputBaseFilename=TrayLuma-Setup
SetupIconFile=..\assets\trayluma.ico
UninstallDisplayIcon={app}\TrayLuma.exe
UninstallDisplayName=TrayLuma
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupMutex=TrayLuma.Setup

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "startup"; Description: "Start TrayLuma when I sign in"; Flags: unchecked

[Files]
Source: "..\dist\TrayLuma.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\NOTICE.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\TrayLuma"; Filename: "{app}\TrayLuma.exe"
Name: "{userdesktop}\TrayLuma"; Filename: "{app}\TrayLuma.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "TrayLuma"; ValueData: """{app}\TrayLuma.exe"" --background"; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\TrayLuma.exe"; Parameters: "--background"; Description: "Launch TrayLuma"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\TrayLuma.exe"; Parameters: "--quit"; Flags: runhidden waituntilterminated; RunOnceId: "CloseTrayLuma"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  ExtractTemporaryFile('TrayLuma.exe');
  if not Exec(ExpandConstant('{tmp}\TrayLuma.exe'), '--quit', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := 'Unable to close the running TrayLuma instance. Exit it from the tray and retry.'
  else if ExitCode <> 0 then
    Result := 'A running instance did not exit. Close it from the tray and retry.';
  Sleep(500);
end;
