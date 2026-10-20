@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\release.ps1" %*
if errorlevel 1 (
  echo.
  echo [FAILED] See the message above.
  pause
)
endlocal
