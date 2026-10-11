@echo off
rem Part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT). GNU GPL v3.
rem
rem Builds the Spotify library (ext\klangten_spotify) for Windows and places it
rem in bin\windows-<arch>\klangten_spotify.dll.
rem
rem   tools\build-spotify.bat [x64^|x86^|all]     (default: all)
rem
rem Needs Rust with the MSVC toolchain and the targets x86_64-pc-windows-msvc
rem and i686-pc-windows-msvc (rustup target add i686-pc-windows-msvc). The CRT
rem is linked statically: the installer ships no Visual C++ runtime.
setlocal
set "ROOT=%~dp0.."
set "WHICH=%~1"
if "%WHICH%"=="" set "WHICH=all"
set "RUSTFLAGS=-C target-feature=+crt-static"
pushd "%ROOT%\ext\klangten_spotify" || exit /b 1
if /I "%WHICH%"=="x64" goto x64
if /I "%WHICH%"=="x86" goto x86
if /I not "%WHICH%"=="all" (
  echo Unknown architecture "%WHICH%". Use x64, x86 or all.
  popd
  exit /b 1
)
:x64
cargo build --release --locked --target x86_64-pc-windows-msvc || goto failed
if not exist "%ROOT%\bin\windows-x64" mkdir "%ROOT%\bin\windows-x64"
copy /Y "target\x86_64-pc-windows-msvc\release\klangten_spotify.dll" "%ROOT%\bin\windows-x64\" >nul || goto failed
echo Spotify library: bin\windows-x64\klangten_spotify.dll
if /I "%WHICH%"=="x64" goto done
:x86
cargo build --release --locked --target i686-pc-windows-msvc || goto failed
if not exist "%ROOT%\bin\windows-x86" mkdir "%ROOT%\bin\windows-x86"
copy /Y "target\i686-pc-windows-msvc\release\klangten_spotify.dll" "%ROOT%\bin\windows-x86\" >nul || goto failed
echo Spotify library: bin\windows-x86\klangten_spotify.dll
:done
popd
exit /b 0
:failed
popd
echo Building the Spotify library failed.
exit /b 1
