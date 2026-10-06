@echo off
chcp 65001 >nul
echo Running a full test in the background log (data\logs), please wait 5-8 minutes...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\app\scheduled-run.ps1"
echo Done.
pause
