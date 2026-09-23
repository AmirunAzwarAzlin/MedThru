@echo off
REM One-click launcher for the MedThru prototype.
REM Rebuilds the Windows app only when source has changed since the last
REM build, then starts the backend and opens the app. Previously this always
REM ran "flutter build windows --debug" (~45s even with zero changes) on
REM every launch; now a no-op start just launches the existing exe.

cd /d "%~dp0"

REM Make sure the tools the script relies on are actually on PATH, so a fresh
REM machine gives a clear message instead of a cryptic "not recognized" error.
where flutter >nul 2>&1
if errorlevel 1 (
  echo.
  echo ERROR: 'flutter' was not found on your PATH.
  echo Install Flutter and add its 'bin' folder to PATH, then try again.
  echo   https://docs.flutter.dev/get-started/install/windows
  echo.
  pause
  exit /b 1
)
where node >nul 2>&1
if errorlevel 1 (
  echo.
  echo ERROR: 'node' was not found on your PATH.
  echo Install Node.js and reopen this launcher, then try again.
  echo   https://nodejs.org/
  echo.
  pause
  exit /b 1
)

set "EXE=%~dp0app\build\windows\x64\runner\Debug\medthru_app.exe"

REM Only the app's own source can make the built exe stale: Dart code,
REM pubspec (deps), assets, and the hand-written native runner. This
REM deliberately excludes app\windows\flutter, which flutter regenerates as
REM part of the build itself -- including it would make every run look dirty.
set "NEEDS_BUILD=0"
if not exist "%EXE%" (
  set "NEEDS_BUILD=1"
) else (
  for /f %%i in ('powershell -NoProfile -Command "$exe = (Get-Item -LiteralPath '%EXE%').LastWriteTimeUtc; $src = (Get-ChildItem -LiteralPath '%~dp0app\lib','%~dp0app\assets','%~dp0app\windows\runner','%~dp0app\pubspec.yaml','%~dp0app\pubspec.lock','%~dp0app\windows\CMakeLists.txt' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum; if ($src -gt $exe) { 1 } else { 0 }"') do set "NEEDS_BUILD=%%i"
)

if "%NEEDS_BUILD%"=="1" (
  REM The build can't overwrite the exe while a copy is still running, so
  REM close any open instance first. Only needed when we're about to rebuild.
  echo Closing any running MedThru app...
  taskkill /IM medthru_app.exe /F >nul 2>&1

  echo Rebuilding the MedThru app - source changed since the last build...
  pushd "%~dp0app"
  REM "call" because flutter is itself a batch script; without it this window
  REM would exit as soon as flutter returns.
  call flutter build windows --debug
  if errorlevel 1 (
    echo.
    echo Build failed - see the messages above. Not launching.
    popd
    pause
    exit /b 1
  )
  popd
) else (
  echo No source changes since the last build - skipping rebuild.
)

REM Skip spawning a second server window if one's already listening -- it
REM would just fail on the port and sit there as clutter.
for /f %%i in ('node -e "const s=require('net').createConnection({port:3000,host:'127.0.0.1'});s.once('connect',()=>{process.stdout.write('1');s.destroy()});s.once('error',()=>process.stdout.write('0'));s.setTimeout(300,()=>{process.stdout.write('0');s.destroy()});"') do set "SERVER_UP=%%i"

if "%SERVER_UP%"=="1" (
  echo MedThru backend already running - reusing it.
) else (
  echo Starting MedThru backend server...
  start "MedThru Server" cmd /k "node server.js"
  timeout /t 3 /nobreak >nul
)

echo Starting the NFC reader bridge...
REM Watches the ACR122U and forwards card taps to the server. Harmless if no
REM reader is plugged in yet -- it just waits.
start "MedThru NFC Reader" cmd /k "node reader.js"

echo Opening the MedThru app...
start "" "%EXE%"

echo.
echo MedThru is starting. You can close this window.
timeout /t 2 /nobreak >nul
