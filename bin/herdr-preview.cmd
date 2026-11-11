@echo off
rem Runs herdr-preview.ps1 from any shell (cmd, PowerShell, Herdr's terminals).
where pwsh >nul 2>nul && (pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0herdr-preview.ps1" %*) || (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0herdr-preview.ps1" %*)
