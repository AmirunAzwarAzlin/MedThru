@echo off
REM Opens Med-IC signed out -- the patient / first-responder view.
REM Tap-a-card flow: use "Read a card" with a token such as 04A1B2C3D4.

cd /d "%~dp0"

echo Starting Med-IC backend server...
start "Med-IC Server" cmd /k "node server.js"

timeout /t 3 /nobreak >nul

echo Opening Med-IC as patient...
start "" "%~dp0app\build\windows\x64\runner\Debug\medthru_app.exe"

timeout /t 2 /nobreak >nul
