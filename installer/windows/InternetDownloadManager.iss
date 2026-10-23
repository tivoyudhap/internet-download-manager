#define AppName "Internet Download Manager"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "build\release"
#endif

[Setup]
AppId={{7A9E74B1-77DF-4C66-B1E3-3C1D8D9A1C20}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Tivo Yudha
DefaultDirName={localappdata}\Programs\Internet Download Manager
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=InternetDownloadManager-Windows-{#AppVersion}-Setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\internet_download_manager.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\internet_download_manager.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\internet_download_manager.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\internet_download_manager.exe"; Description: "Launch {#AppName}"; Flags: postinstall nowait skipifsilent
