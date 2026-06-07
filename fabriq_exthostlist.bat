@echo off
REM Fabriq Extended Hostlist Editor launcher (t-0011).
REM Runs the .ps1 with ExecutionPolicy Bypass. The packaged Fabriq_ExtHostlist.exe
REM (built like the other tools) is the production entry; this .bat is for testing
REM on machines without the EXE.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fabriq_exthostlist.ps1"
