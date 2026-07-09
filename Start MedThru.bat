@echo off
REM One-click launcher for the MedThru prototype.
REM Starts the backend server (if not already running) and opens the app.

cd /d "%~dp0"

echo Starting MedThru backend server...
REM Launch the Node server in its own window. If it's already running on
REM port 3000 it will just error out harmlessly in that window.
start "MedThru Server" cmd /k "node server.js"

REM Give the server a couple of seconds to come up before opening the app.
timeout /t 3 /nobreak >nul

echo Opening the MedThru app...
start "" "%~dp0app\build\windows\x64\runner\Debug\medthru_app.exe"

echo.
echo MedThru is starting. You can close this window.
timeout /t 3 /nobreak >nul
