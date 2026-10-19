@echo off
rem One click: downloads whatever is missing (Strata, portable Python, engine, model), then starts the API.
setlocal
title Qwen3.8-Flash-Next
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_next.ps1" %*
if errorlevel 1 pause
exit /b %ERRORLEVEL%
