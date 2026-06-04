@echo off
rem ============================================================
rem Fabriq BackUper - Credentials viewer launcher
rem
rem Double-click THIS file to see the list of credentials that existed on the
rem old PC (reference only; no passwords). Runs the viewer with a process-scoped
rem -ExecutionPolicy Bypass, so a raw .ps1 policy block is sidestepped without
rem changing any system setting.
rem ============================================================
chcp 65001 > nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0_data\Show-Credentials.ps1"
