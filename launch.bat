@echo off
title Antigravity Switcher
cd /d "%~dp0"
python switcher_gui.py
if %errorlevel% neq 0 (
    pause
)
