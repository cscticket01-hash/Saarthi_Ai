@echo off
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel% equ 0 (
  py -3 run_lab.py
) else (
  python run_lab.py
)
if errorlevel 1 pause
