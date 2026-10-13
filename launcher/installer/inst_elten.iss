; A part of Elten - EltenLink / Elten Network desktop client.
; Copyright (C) 2014-2026 Dawid Pieper
; Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: own AppId, names, directories and data location,
; so that Klangten installs side by side with Elten; Klangten program names (klangten.exe) and the transition
; from the Elten names used up to 0.3 (see [Code] and docs/klangten-releases.md, "Executable names").

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
; AppVerName is left to Inno Setup ("Klangten version <AppVersion>"); a fixed one
; showed "Klangten 0.1.0" in the list of installed apps for every release.
AppVersion=0.4.1
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
; Up to 0.3 the programs carried Elten's names. The wildcard below removes them
; too; they are listed so that the transition stays visible here.
Type: files; Name: "{app}\elten.exe"
Type: files; Name: "{app}\elten-x86.exe"
Type: files; Name: "{app}\elten-x64.exe"
Type: files; Name: "{app}\elten-arm64.exe"
Type: files; Name: "{app}\bin\ext\windows\EltenSapiBridge32.exe"
Type: files; Name: "{app}\bin\ext\windows\EltenSapiBridge64.exe"
Type: filesandordirs; Name: "{app}\*"

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "pl"; MessagesFile: "compiler:Languages\Polish.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "tr"; MessagesFile: "compiler:Languages\Turkish.isl"

[CustomMessages]
KlangtenRunning=Klangten is running. It has to be closed to continue. Close Klangten now?
KlangtenStillRunning=Klangten is still running. Close it and start Setup again.
de.KlangtenRunning=Klangten läuft noch. Es muss beendet werden, damit die Installation fortgesetzt werden kann. Klangten jetzt beenden?
de.KlangtenStillRunning=Klangten läuft noch. Bitte beenden Sie Klangten und starten Sie das Setup erneut.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}";

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: "ignoreversion createallsubdirs recursesubdirs"

[Icons]
Name: "{group}\Klangten"; Filename: "{app}\klangten.exe"
Name: "{group}\{cm:ProgramOnTheWeb,Klangten}"; Filename: "https://klango.online"
Name: "{group}\{cm:UninstallProgram,Klangten}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\Klangten"; Filename: "{app}\klangten.exe"; Tasks: desktopicon

[Run]
; Not skipifsilent: the updater runs Setup with /silent after Klangten has quit,
; and this entry starts Klangten again (as the user who started Setup, which is
; the default for postinstall entries). Klangten up to 0.3 relies on it as well:
; it starts only Setup and never a program by name.
Filename: "{app}\klangten.exe"; Description: "{cm:LaunchProgram,{#StringChange("Klangten", '&', '&&')}}"; Flags: nowait postinstall

[INI]
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "de-DE"; Languages: de; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "pl-PL"; Languages: pl; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "fr-FR"; Languages: fr; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "ru-RU"; Languages: ru; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "es-PA"; Languages: es; Flags: createkeyifdoesntexist
Filename: "{userappdata}\sixdotsIT\klangten\klangten.ini"; Section: "Interface"; Key: "Language"; String: "tr-TR"; Languages: tr; Flags: createkeyifdoesntexist

[Code]
// Klangten 0.4: the programs were renamed from elten*.exe to klangten*.exe.
// An update started by Klangten up to 0.3 runs this Setup with /silent and
// /tasks="". Setup therefore
//   - stops what is still running from the installation folder (the quitting
//     old Klangten), and only from there: Elten itself uses the same program
//     names in its own folder and is never touched;
//   - points existing shortcuts (desktop, start menu, taskbar, autostart
//     folder) that lead to the old programs in the installation folder to the
//     new ones; the desktop shortcut is otherwise not renewed by /tasks="";
//   - moves Klangten's autostart entry (HKCU ...\Run, value "klangten", never
//     Elten's "elten") to klangten.exe. Klangten repeats that itself at every
//     start (EltenSystemHelpers.sync_autostart), for the case that Setup ran
//     elevated under another account.

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  AutostartValue = 'klangten';

function KlangtenAppDir(): String;
begin
  Result := Lowercase(AddBackslash(ExpandConstant('{app}')));
end;

// True for a program of an old (elten*.exe) or current (klangten*.exe) Klangten.
function IsKlangtenProgramName(Name: String): Boolean;
begin
  Name := Lowercase(Name);
  Result := (ExtractFileExt(Name) = '.exe') and
    ((Pos('elten', Name) = 1) or (Pos('klangten', Name) = 1));
end;

// Process ids of Klangten programs running from the installation folder
// (including bin\ext\windows, where the speech bridge lives).
function KlangtenProcessIds(var Ids: TArrayOfString): Integer;
var
  Locator, Service, Processes, Item: Variant;
  AppDir, ExePath: String;
  I, Count, Pid: Integer;
begin
  Result := 0;
  SetArrayLength(Ids, 0);
  AppDir := KlangtenAppDir();
  if Length(AppDir) < 4 then exit;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Processes := Service.ExecQuery('SELECT ProcessId, Name, ExecutablePath FROM Win32_Process ' +
      'WHERE Name LIKE ''elten%.exe'' OR Name LIKE ''klangten%.exe''');
    Count := Processes.Count;
    for I := 0 to Count - 1 do
    begin
      Item := Processes.ItemIndex(I);
      if VarIsNull(Item.ExecutablePath) then continue;
      ExePath := Item.ExecutablePath;
      ExePath := Lowercase(ExePath);
      if (Pos(AppDir, ExePath) = 1) and IsKlangtenProgramName(ExtractFileName(ExePath)) then
      begin
        SetArrayLength(Ids, Result + 1);
        Pid := Item.ProcessId;
        Ids[Result] := IntToStr(Pid);
        Result := Result + 1;
      end;
    end;
  except
    Log('Klangten: process list unavailable: ' + GetExceptionMessage);
  end;
end;

// Waits up to WaitSeconds for the programs to quit on their own, then ends the
// rest by process id. Never by name: Elten uses the same program names.
procedure StopKlangtenProcesses(WaitSeconds: Integer);
var
  Ids: TArrayOfString;
  I, Waited, ResultCode: Integer;
begin
  Waited := 0;
  while (KlangtenProcessIds(Ids) > 0) and (Waited < WaitSeconds) do
  begin
    Sleep(1000);
    Waited := Waited + 1;
  end;
  if KlangtenProcessIds(Ids) = 0 then exit;
  for I := 0 to GetArrayLength(Ids) - 1 do
  begin
    Log('Klangten: stopping process ' + Ids[I] + ' from ' + ExpandConstant('{app}'));
    // No /T: Setup itself was started by the old Klangten and is its child.
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/PID ' + Ids[I] + ' /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
  Sleep(1000);
end;

// "elten-x64.exe" -> "klangten-x64.exe"
function NewProgramName(OldName: String): String;
begin
  Result := 'klangten' + Copy(OldName, 6, Length(OldName) - 5);
end;

procedure RetargetShortcutsIn(Dir: String);
var
  Find: TFindRec;
  Shell, Shortcut: Variant;
  Target, TargetName, NewTarget, Icon: String;
begin
  if (Dir = '') or not DirExists(Dir) then exit;
  if not FindFirst(AddBackslash(Dir) + '*.lnk', Find) then exit;
  try
    repeat
      try
        Shell := CreateOleObject('WScript.Shell');
        Shortcut := Shell.CreateShortcut(AddBackslash(Dir) + Find.Name);
        Target := Shortcut.TargetPath;
        TargetName := Lowercase(ExtractFileName(Target));
        if (Lowercase(ExtractFilePath(Target)) = KlangtenAppDir()) and
           (Pos('elten', TargetName) = 1) and (ExtractFileExt(TargetName) = '.exe') then
        begin
          NewTarget := ExpandConstant('{app}\') + NewProgramName(TargetName);
          if FileExists(NewTarget) then
          begin
            Log('Klangten: shortcut ' + AddBackslash(Dir) + Find.Name + ' -> ' + NewTarget);
            Shortcut.TargetPath := NewTarget;
            Icon := Shortcut.IconLocation;
            Icon := Lowercase(Icon);
            if Pos(TargetName, Icon) > 0 then Shortcut.IconLocation := NewTarget + ',0';
            Shortcut.Save;
          end;
        end;
      except
        Log('Klangten: shortcut ' + Find.Name + ' not changed: ' + GetExceptionMessage);
      end;
    until not FindNext(Find);
  finally
    FindClose(Find);
  end;
end;

procedure RetargetShortcuts();
var
  PinnedRoot: String;
begin
  RetargetShortcutsIn(ExpandConstant('{group}'));
  RetargetShortcutsIn(ExpandConstant('{commondesktop}'));
  RetargetShortcutsIn(ExpandConstant('{userdesktop}'));
  RetargetShortcutsIn(ExpandConstant('{commonprograms}'));
  RetargetShortcutsIn(ExpandConstant('{userprograms}'));
  RetargetShortcutsIn(ExpandConstant('{commonstartup}'));
  RetargetShortcutsIn(ExpandConstant('{userstartup}'));
  PinnedRoot := ExpandConstant('{userappdata}\Microsoft\Internet Explorer\Quick Launch');
  RetargetShortcutsIn(PinnedRoot);
  RetargetShortcutsIn(PinnedRoot + '\User Pinned\TaskBar');
  RetargetShortcutsIn(PinnedRoot + '\User Pinned\StartMenu');
end;

procedure MoveAutostartEntry();
var
  Value, Lower, NewValue: String;
begin
  if not RegQueryStringValue(HKCU, RunKey, AutostartValue, Value) then exit;
  Lower := Lowercase(Value);
  if Pos(KlangtenAppDir() + 'elten', Lower) = 0 then exit;
  NewValue := '"' + ExpandConstant('{app}\klangten.exe') + '"';
  if Pos('/hidden', Lower) > 0 then NewValue := NewValue + ' /hidden';
  Log('Klangten: autostart ' + Value + ' -> ' + NewValue);
  RegWriteStringValue(HKCU, RunKey, AutostartValue, NewValue);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Ids: TArrayOfString;
begin
  Result := '';
  if WizardSilent() then
  begin
    // The updater: the old Klangten started Setup and is quitting.
    StopKlangtenProcesses(15);
    exit;
  end;
  if KlangtenProcessIds(Ids) = 0 then exit;
  if MsgBox(CustomMessage('KlangtenRunning'), mbConfirmation, MB_YESNO) = IDYES then
    StopKlangtenProcesses(0)
  else
    Result := CustomMessage('KlangtenStillRunning');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    RetargetShortcuts();
    MoveAutostartEntry();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then StopKlangtenProcesses(0);
end;
