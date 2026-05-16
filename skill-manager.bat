@echo off
REM Abre a UI do AI Skills Hub (porta 8765).
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-skills.ps1" ui
