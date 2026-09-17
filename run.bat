@echo off
rem run.bat - Klangten aus dem Quelltext starten (Windows).
rem
rem   run.bat              gegen den oeffentlichen Klango-Server (ten.klango.online)
rem   run.bat --dev        gegen einen lokalen Entwicklungsserver auf Port 5100
rem   run.bat --api URL    gegen einen beliebigen Server
rem
rem Das ist ein Quelltextlauf: der eingebaute Updater ist dabei abgeschaltet,
rem weil er nur in Launcher-Builds greift. Ein fertiges Programm baut compile.bat.

setlocal EnableExtensions
set "ROOT=%~dp0"
pushd "%ROOT%"

set "ARGS="

:parse_args
if "%~1"=="" goto after_args
if /I "%~1"=="--dev" (
  set "KLANGTEN_API_URL=http://127.0.0.1:5100"
  shift
  goto parse_args
)
if /I "%~1"=="--api" (
  set "KLANGTEN_API_URL=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="-h" goto usage
if /I "%~1"=="--help" goto usage
set "ARGS=%ARGS% %~1"
shift
goto parse_args

:usage
echo Verwendung: run.bat [--dev] [--api URL] [Argumente...]
popd
exit /b 0

:after_args
if defined KLANGTEN_API_URL echo API: %KLANGTEN_API_URL%

where bundle >nul 2>&1
if errorlevel 1 (
  echo bundler nicht gefunden - starte mit dem System-Ruby ohne Bundler.
  ruby elten.rb%ARGS%
  set "EXITCODE=%ERRORLEVEL%"
  popd
  exit /b %EXITCODE%
)

call bundle check >nul 2>&1
if errorlevel 1 (
  echo Gems fehlen, installiere sie ^(das kann beim ersten Mal lange dauern^)...
  rem Nokogiri und sqlite3 werden gegen die MSYS2-Systembibliotheken gebaut,
  rem ein Quellbau scheitert hier sonst an libiconv.
  call bundle config set --local build.nokogiri --use-system-libraries
  call bundle config set --local build.sqlite3 --enable-system-libraries
  call bundle install || goto fail
)

call bundle exec ruby elten.rb%ARGS%
set "EXITCODE=%ERRORLEVEL%"
popd
exit /b %EXITCODE%

:fail
set "EXITCODE=%ERRORLEVEL%"
popd
exit /b %EXITCODE%
