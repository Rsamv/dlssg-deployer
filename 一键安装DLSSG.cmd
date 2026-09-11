@echo off
chcp 65001 >nul
title DLSSG Native 0.2.4 - Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DLSSG.ps1"
exit /b %errorlevel%
