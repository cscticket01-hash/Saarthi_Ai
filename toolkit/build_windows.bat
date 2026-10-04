@echo off
setlocal
cd /d "%~dp0"
py -3 -m pip install -r requirements-build.txt -r requirements-web.txt -r requirements-windows.txt
if errorlevel 1 exit /b 1
py -3 prepare_backend.py --out saarthi_lab/backend
if errorlevel 1 exit /b 1
py -3 -m PyInstaller --noconfirm --clean --onefile --windowed --name Saarthi-Test-Lab --collect-all playwright --hidden-import pywinauto --hidden-import psutil --add-data "saarthi_lab/static:saarthi_lab/static" --add-data "saarthi_lab/backend:saarthi_lab/backend" run_lab.py
if errorlevel 1 exit /b 1
echo EXE ready: dist\Saarthi-Test-Lab.exe
endlocal
