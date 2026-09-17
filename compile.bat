@echo off
rem compile.bat - Klangten fuer Windows bauen.
rem
rem   compile.bat                 Launcher bauen (x64, x86 und die Fassade elten.exe)
rem   compile.bat --pkg           zusaetzlich dist\windows\KlangtenSetup.exe
rem   compile.bat --sign          mit signtool signieren (Zertifikat aus dem Zertifikatspeicher)
rem   compile.bat --build-id ID   Build id einbetten (sonst der Git-Hash)
rem
rem ARM64 wird nur auf einem ARM64-Rechner gebaut: die Ruby-Laufzeit dieses Ziels
rem muss waehrend des Builds laufen. Auf x64 uebernimmt die Fassade elten.exe,
rem ARM64-Windows startet dann elten-x64.exe unter Emulation.
rem
rem Zum Starten aus dem Quelltext: run.bat

setlocal EnableExtensions
set "ROOT=%~dp0"
pushd "%ROOT%"

set "PKG=0"
set "SIGN=0"
set "BUILD_ID="

:parse_args
if "%~1"=="" goto after_args
if /I "%~1"=="--pkg" ( set "PKG=1" & shift & goto parse_args )
if /I "%~1"=="--sign" ( set "SIGN=1" & shift & goto parse_args )
if /I "%~1"=="--build-id" ( set "BUILD_ID=%~2" & shift & shift & goto parse_args )
if /I "%~1"=="-h" goto usage
if /I "%~1"=="--help" goto usage
echo Unbekanntes Argument: %~1
popd
exit /b 1

:usage
echo Verwendung: compile.bat [--pkg] [--sign] [--build-id ID]
popd
exit /b 0

:after_args

call "%ROOT%tools\find-cmake-2026.bat" || goto fail
echo Verwende CMake: %CMAKE_EXE%

set "CMAKE_FLAGS="
if defined BUILD_ID set "CMAKE_FLAGS=-DELTEN_BUILD_ID=%BUILD_ID%"
if "%SIGN%"=="1" set "CMAKE_FLAGS=%CMAKE_FLAGS% -DELTEN_WINDOWS_SIGN=ON"

echo == Konfigurieren ==
"%CMAKE_EXE%" --preset windows-x64 %CMAKE_FLAGS% || goto fail
"%CMAKE_EXE%" --preset windows-x86 %CMAKE_FLAGS% || goto fail

echo == Launcher bauen ==
"%CMAKE_EXE%" --build --preset windows-x64-release --target EltenLauncher || goto fail
"%CMAKE_EXE%" --build --preset windows-x86-release --target EltenLauncher || goto fail
rem elten.exe ist die Fassade aus dem x86-Build; sie waehlt zur Laufzeit die Architektur.
"%CMAKE_EXE%" --build --preset windows-x86-release --target EltenLauncherFacade || goto fail

rem ARM64 nur auf einem ARM64-Host
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
  echo == ARM64 bauen ==
  "%CMAKE_EXE%" --preset windows-arm64 %CMAKE_FLAGS% || goto fail
  "%CMAKE_EXE%" --build --preset windows-arm64-release --target EltenLauncher || goto fail
) else (
  echo ARM64 wird uebersprungen ^(kein ARM64-Host^).
)

if "%PKG%"=="1" (
  echo == Installer bauen ==
  "%CMAKE_EXE%" --build --preset windows-x64-release --target EltenPkg || goto fail
  echo Fertig: %ROOT%dist\windows\KlangtenSetup.exe
) else (
  echo Fertig: %ROOT%build\release\windows  ^(--pkg fuer den Installer^)
)

popd
exit /b 0

:fail
set "EXITCODE=%ERRORLEVEL%"
echo Build fehlgeschlagen ^(Code %EXITCODE%^).
popd
exit /b %EXITCODE%
