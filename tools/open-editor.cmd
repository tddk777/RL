@echo off
rem Opens this project in the Godot editor installed by setup-windows.ps1.
set "GODOT=E:\Tools\Godot\godot.cmd"
if not exist "%GODOT%" (
  echo Godot launcher not found at %GODOT%.
  echo Run: powershell -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
  exit /b 1
)
call "%GODOT%" --editor --path "%~dp0.."
