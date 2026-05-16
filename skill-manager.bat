@echo off
title AI Skills Hub Manager
setlocal

set "ROOT=%~dp0"
set "AI_SKILLS_USERPROFILE_ROOT=%USERPROFILE%"
set "AI_SKILLS_APPDATA_ROOT=%APPDATA%"
set "AI_SKILLS_LOCALAPPDATA_ROOT=%LOCALAPPDATA%"

where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "AI Skills Hub Manager" pwsh -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manage-skills.ps1" ui
) else (
  start "AI Skills Hub Manager" powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manage-skills.ps1" ui
)
