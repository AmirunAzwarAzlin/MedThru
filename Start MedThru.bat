@echo off
REM One-click launcher for the MedThru prototype.
REM Rebuilds the Windows app from source, then starts the backend and opens it,
REM so code changes are always picked up (the old launcher ran a stale build).

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

REM The build can't overwrite the exe while a copy is still running, so close
REM any open instance first. Harmless if none is running.
echo Closing any running MedThru app...
taskkill /IM medthru_app.exe /F >nul 2>&1

echo Rebuilding the MedThru app (this can take a minute)...
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

echo Starting MedThru backend server...
REM Launch the Node server in its own window. If it's already running on
REM port 3000 it will just error out harmlessly in that window.
start "MedThru Server" cmd /k "node server.js"

REM Give the server a couple of seconds to come up before opening the app.
timeout /t 3 /nobreak >nul

echo Starting the NFC reader bridge...
REM Watches the ACR122U and forwards card taps to the server. Harmless if no
REM reader is plugged in yet — it just waits.
start "MedThru NFC Reader" cmd /k "node reader.js"

echo Opening the MedThru app...
start "" "%~dp0app\build\windows\x64\runner\Debug\medthru_app.exe"

echo.
echo MedThru is starting. You can close this window.
timeout /t 3 /nobreak >nul
