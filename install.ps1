# Antigravity Switcher - Windows PowerShell Installer
$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Antigravity Switcher - Windows Installation   " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$InstallDir = "$env:LOCALAPPDATA\AntigravitySwitcher"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1. Ensure Python is installed
try {
    $pythonVersion = & python --version 2>&1
    Write-Host "✓ Found Python: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "⚠ Python 3 was not detected in PATH. Please install Python 3 from https://python.org or the Microsoft Store." -ForegroundColor Red
    pause
    exit 1
}

# 2. Create Destination Folder
Write-Host "Installing to $InstallDir..." -ForegroundColor Yellow
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# 3. Copy Application Files
Copy-Item "$ScriptDir\account_switcher_core.py" -Destination $InstallDir -Force
Copy-Item "$ScriptDir\switcher_gui.py" -Destination $InstallDir -Force
Copy-Item "$ScriptDir\ui.html" -Destination $InstallDir -Force

# Create launch batch in install dir
$LaunchBat = "$InstallDir\launch.bat"
"@echo off`r`nstart pythonw `"$InstallDir\switcher_gui.py`"" | Out-File -FilePath $LaunchBat -Encoding ASCII

# 4. Create Desktop & Start Menu Shortcuts
$WshShell = New-Object -ComObject WScript.Shell

# Desktop Shortcut
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$Shortcut = $WshShell.CreateShortcut("$DesktopPath\Antigravity Switcher.lnk")
$Shortcut.TargetPath = "$LaunchBat"
$Shortcut.WorkingDirectory = "$InstallDir"
$Shortcut.Description = "Multi-account profile switcher for Google Antigravity"
$Shortcut.Save()
Write-Host "✓ Created Desktop Shortcut" -ForegroundColor Green

# Start Menu Shortcut
$StartMenuPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$StartShortcut = $WshShell.CreateShortcut("$StartMenuPath\Antigravity Switcher.lnk")
$StartShortcut.TargetPath = "$LaunchBat"
$StartShortcut.WorkingDirectory = "$InstallDir"
$StartShortcut.Description = "Multi-account profile switcher for Google Antigravity"
$StartShortcut.Save()
Write-Host "✓ Created Start Menu Shortcut" -ForegroundColor Green

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "✓ Installation complete! Launching Antigravity Switcher..." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

Start-Process "$LaunchBat"
