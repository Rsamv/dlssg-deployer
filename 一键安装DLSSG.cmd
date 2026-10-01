@echo off
chcp 65001 >nul
title DLSSG for SM86 0.3.5 - Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DLSSG.ps1" %*
set RC=%errorlevel%
if not "%RC%"=="0" (
    echo.
    echo [ERROR] Install-DLSSG.ps1 exited with code %RC%.
    echo See the error messages above. Press any key to close this window.
    pause >nul
)
exit /b %RC%
