@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0selibs.ps1" %*
exit /b %ERRORLEVEL%