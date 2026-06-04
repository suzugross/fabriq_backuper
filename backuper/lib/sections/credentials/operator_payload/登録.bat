@echo off
rem ============================================================
rem Fabriq BackUper - Credentials restore launcher
rem
rem Launches register_credentials.ps1 in the same directory with
rem PowerShell ExecutionPolicy bypassed. Does NOT require admin.
rem Run as the user whose Credential Manager you want to populate.
rem ============================================================

chcp 65001 > nul 2>&1
rem v0.38.0: support files were moved into _data\ to keep the folder front
rem (mostly batches) tidy; register_credentials.ps1 + credentials_list.csv now
rem live there.
pushd "%~dp0_data"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\register_credentials.ps1"
set RC=%ERRORLEVEL%

popd

echo.
if not "%RC%"=="0" echo Exit code: %RC%
echo.
pause
