@echo off
rem ============================================================
rem Fabriq App Migration Check (source PC) launcher
rem Runs fabriq_appcheck.ps1 with ExecutionPolicy Bypass. Plain ASCII.
rem chcp 65001 so any console output renders UTF-8 correctly.
rem %* forwards operator flags (e.g. -VerboseScan) to the ps1.
rem ============================================================
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fabriq_appcheck.ps1" %*
