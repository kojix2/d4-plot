[Setup]
AppId=kojix2.d4-plot
AppName=d4-plot
AppVersion={#AppVersion}
AppPublisher=kojix2
AppPublisherURL=https://github.com/kojix2/d4-plot
AppSupportURL=https://github.com/kojix2/d4-plot/issues
DefaultDirName={localappdata}\Programs\d4-plot
DefaultGroupName=d4-plot
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\d4-plot.exe
OutputDir=..\dist
OutputBaseFilename=d4-plot-v{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\bin\d4-plot.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\d4-plot"; Filename: "{app}\d4-plot.exe"
Name: "{autodesktop}\d4-plot"; Filename: "{app}\d4-plot.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
