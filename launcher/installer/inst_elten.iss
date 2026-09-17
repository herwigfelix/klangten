; A part of Elten - EltenLink / Elten Network desktop client.
; Copyright (C) 2014-2026 Dawid Pieper
; Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: own AppId, names, directories and data location,
; so that Klangten installs side by side with Elten.

#ifndef SourceDir
#define SourceDir "..\..\dist\windows\Klangten"
#endif

#ifndef OutputDir
#define OutputDir "..\..\dist\windows"
#endif

#ifndef OutputBaseFilename
#define OutputBaseFilename "KlangtenSetup"
#endif

[Setup]
; Klangten's own AppId. Never reuse Elten's {9FE2B24B-49F4-4D0B-A36B-31F267F9B114}.
AppId={{2EEA2E35-34F6-4197-9224-50402E47BBAE}
AppName=Klangten
AppVersion=Klangten 0.1.0
AppVerName=Klangten 0.1.0
AppPublisher=sixdotsIT
AppPublisherURL=https://klango.online
AppSupportURL=https://klango.online/
AppUpdatesURL=https://klango.online
AppCopyright=Copyright (C) 2014-2026 Dawid Pieper; modifications Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
DefaultDirName={autopf}\Klangten
DefaultGroupName=Klangten
AllowNoIcons=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=Lzma2/ultra
SolidCompression=yes
RestartIfNeededByRun=no
PrivilegesRequiredOverridesAllowed=commandline dialog
LicenseFile=gpl-3.0.txt
InfoBeforeFile=klangten-notice.txt
WizardStyle=modern

#define Use_UninsHs_Default_CustomMessages

[InstallDelete]
Type: filesandordirs; Name: "{app}\*"

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "pl"; MessagesFile: "compiler:Languages\Polish.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "tr"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}";

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: "ignoreversion createallsubdirs recursesubdirs"

[Icons]
Name: "{group}\Klangten"; Filename: "{app}\elten.exe"
Name: "{group}\{cm:ProgramOnTheWeb,Klangten}"; Filename: "https://klango.online"
Name: "{group}\{cm:UninstallProgram,Klangten}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\Klangten"; Filename: "{app}\elten.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\elten.exe"; Description: "{cm:LaunchProgram,{#StringChange("Klangten", '&', '&&')}}"; Flags: nowait postinstall

[INI]
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "de-DE"; Languages: de; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "pl-PL"; Languages: pl; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "fr-FR"; Languages: fr; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "ru-RU"; Languages: ru; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "es-PA"; Languages: es; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "tr-TR"; Languages: tr; Flags: createkeyifdoesntexist
