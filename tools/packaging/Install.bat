@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-QnapPhotoManager.ps1" -Launch
if errorlevel 1 pause
