@echo off
rem  Installs myco from cmd.exe by delegating to install.ps1.
setlocal EnableExtensions

set "_MYCO_PS=powershell.exe"
where /q powershell.exe || set "_MYCO_PS=pwsh.exe"

"%_MYCO_PS%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
