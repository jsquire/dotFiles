@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0crush-task.ps1" %*
