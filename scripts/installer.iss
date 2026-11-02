; Script generated for XiugouTV Windows x64 Installer
#ifndef AppVersion
  #define AppVersion "1.0.4"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{E88D6F21-6A2F-4E8C-B8FB-5A86FA8F0C42}}
AppName=XiugouTV
AppVersion={#AppVersion}
; 安装包自身的版本资源（FileVersion / ProductVersion），发布门禁据此核对版本号。
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
AppPublisher=XiugouTV Project
AppPublisherURL=https://github.com/qfw66/xiugou-tv
AppSupportURL=https://github.com/qfw66/xiugou-tv
AppUpdatesURL=https://github.com/qfw66/xiugou-tv
DefaultDirName={autopf}\XiugouTV
DefaultGroupName=XiugouTV
DisableProgramGroupPage=yes
; 默认仍按管理员装到 Program Files；仅允许命令行 /CURRENTUSER 免提权安装，
; 供发布门禁静默装到临时目录做启动冒烟（向导界面不变）。
PrivilegesRequiredOverridesAllowed=commandline
LicenseFile=
OutputDir={#OutputDir}
OutputBaseFilename=xiugou-tv-windows-x64-v{#AppVersion}-setup
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\xiugou_tv.exe

[Languages]
; Inno Setup 6 自带英文消息文件为安装根目录的 Default.isl；Languages\ 目录只放第三方语言包，
; 没有 English.isl。若日后需要中文向导，把 ChineseSimplified.isl 放进仓库再追加一项。
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\XiugouTV"; Filename: "{app}\xiugou_tv.exe"
Name: "{group}\{cm:UninstallProgram,XiugouTV}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\XiugouTV"; Filename: "{app}\xiugou_tv.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\xiugou_tv.exe"; Description: "{cm:LaunchProgram,XiugouTV}"; Flags: nowait postinstall skipifsilent
