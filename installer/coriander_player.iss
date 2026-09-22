; Inno Setup 脚本 - Coriander Player Windows 安装程序
; 使用方法：
;   1. 先构建 release：flutter build windows --release
;   2. 把 BASS 运行库（bass.dll / basswasapi.dll 及各插件）放到
;      build\windows\x64\runner\Release\BASS\ 目录
;   3. 用 Inno Setup 编译本脚本：
;      "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\coriander_player.iss
;
; BASS 库可从 https://www.un4seen.com/ 免费下载（取 x64 版本）。

#define MyAppName "Coriander Player"
#define MyAppVersion "1.6.4"
#define MyAppPublisher "Ferry-200"
#define MyAppURL "https://github.com/Ferry-200/coriander_player"
#define MyAppExeName "coriander_player.exe"

; 相对本 .iss 文件所在目录（installer\）的构建输出目录
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{B3F2A7C1-9E4D-4A8B-B5E2-CORIANDER0001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
; 仅支持 64 位 Windows
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=coriander_player-{#MyAppVersion}-setup
SetupIconFile=..\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 主程序、Flutter 运行库、插件 DLL、data 目录、BASS 库全部递归打包
Source: "{#BuildDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BuildDir}\BASS\*"; DestDir: "{app}\BASS"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
