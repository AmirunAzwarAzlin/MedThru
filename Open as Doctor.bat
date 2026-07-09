@echo off
REM Opens Med-IC already signed in as a doctor (admin / admin123).
REM Auto-login only works in debug builds -- see _wantsAutoDoctor in main.dart.

cd /d "%~dp0"

echo Starting Med-IC backend server...
start "Med-IC Server" cmd /k "node server.js"

REM Give the server a moment; auto-login hits it on app startup.
timeout /t 3 /nobreak >nul

echo Opening Med-IC as doctor...
start "" "%~dp0app\build\windows\x64\runner\Debug\medthru_app.exe" --doctor

timeout /t 2 /nobreak >nul
