@echo off
rem ============================================================
rem  Fabriq BackUper - Outlook account viewer launcher
rem
rem  Double-click THIS file (not the .ps1). It runs the viewer with a
rem  process-scoped "-ExecutionPolicy Bypass", which overrides the machine's
rem  persisted policy (Restricted / RemoteSigned) WITHOUT changing any system
rem  setting, so a raw .ps1 execution-policy block is sidestepped.
rem ============================================================
chcp 65001 > nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Show-OutlookAccounts.ps1"
