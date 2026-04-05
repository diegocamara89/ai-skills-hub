@echo off
title AI Skills Hub Manager
setlocal
set "AI_SKILLS_USERPROFILE_ROOT=%USERPROFILE%"
set "AI_SKILLS_APPDATA_ROOT=%APPDATA%"
powershell -ExecutionPolicy Bypass -File "%~dp0manage-skills.ps1" ui
pause
