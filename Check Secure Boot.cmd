@echo off
title Secure Boot check
rem Runs SecureBootCheck.ps1; the script asks for admin rights itself.
echo This check makes no changes to your PC - it only reads your settings.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SecureBootCheck.ps1"
