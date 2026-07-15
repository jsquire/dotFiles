@echo off
rem Thin shim: the real launcher is copilot-local.ps1 (PowerShell renders the box-drawing UI
rem and ANSI colour reliably; cmd.exe cannot parse a UTF-8 batch file with box glyphs).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0copilot-local.ps1" %*