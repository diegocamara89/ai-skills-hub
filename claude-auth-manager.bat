@echo off
title Claude Auth Manager
setlocal

set "ROOT=%~dp0"
set "AI_SKILLS_USERPROFILE_ROOT=%USERPROFILE%"
set "AI_SKILLS_APPDATA_ROOT=%APPDATA%"
set "AI_SKILLS_LOCALAPPDATA_ROOT=%LOCALAPPDATA%"

where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "Claude Auth Manager" pwsh -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manage-skills.ps1" claude-auth-ui
) else (
  start "Claude Auth Manager" powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manage-skills.ps1" claude-auth-ui
)
