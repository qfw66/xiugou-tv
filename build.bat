@echo off
rem Version follows pubspec.yaml (build_windows.ps1 reads it when -Version is omitted).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_windows.ps1" -SkipInstaller %*
