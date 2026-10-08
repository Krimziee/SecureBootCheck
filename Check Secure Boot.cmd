@echo off
rem Opens the Secure Boot and TPM 2.0 check window. It asks for admin rights itself,
rem only to READ the settings - this check makes no changes to your PC.
rem (For the text version: powershell -ExecutionPolicy Bypass -File SecureBootCheck.ps1)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SecureBootCheck.ps1" -Window
