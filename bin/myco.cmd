@echo off
rem  myco - cmd.exe entry point.
rem
rem  Arguments are handed to PowerShell as MYCO_ARGC / MYCO_ARG_n so that flags
rem  such as --model survive untouched. PowerShell decides what to do and, when
rem  a Copilot session is needed, writes a small batch plan. That plan is then
rem  called from this session so the directory change outlives myco.
rem
rem  setlocal is released before the plan runs, which both clears the temporary
rem  MYCO_ARG_* variables and lets the plan's "cd" take effect for the caller.

setlocal EnableExtensions

set "_MYCO_DIR=%~dp0"
set "_MYCO_PLAN=%TEMP%\myco-plan-%RANDOM%%RANDOM%.cmd"
set "_MYCO_PS=powershell.exe"
where /q powershell.exe || set "_MYCO_PS=pwsh.exe"

set "MYCO_ARGC=0"
:myco_parse
if "%~1"=="" goto :myco_parsed
set /a MYCO_ARGC+=1
call set "MYCO_ARG_%%MYCO_ARGC%%=%~1"
shift
goto :myco_parse
:myco_parsed

"%_MYCO_PS%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%_MYCO_DIR%..\lib\myco-run.ps1" -Shell cmd -PlanFile "%_MYCO_PLAN%" -CurrentDirectory "%CD%\."
set "_MYCO_RC=%ERRORLEVEL%"

endlocal & set "MYCO_PLAN_FILE=%_MYCO_PLAN%" & set "MYCO_RC=%_MYCO_RC%"

if not exist "%MYCO_PLAN_FILE%" goto :myco_done
call "%MYCO_PLAN_FILE%"
set "MYCO_RC=%ERRORLEVEL%"
del "%MYCO_PLAN_FILE%" >nul 2>&1

:myco_done
set "MYCO_PLAN_FILE=" & set "MYCO_RC=" & exit /b %MYCO_RC%
