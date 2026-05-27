@echo off
title Fabriq KeepAwake - Do NOT close while backup is running
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0KeepAwake.ps1"
