@echo off
title Antigravity Switcher Installer
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if %errorlevel% neq 0 (
    echo.
    echo Installation failed. Press any key to exit.
    pause >nul
)
