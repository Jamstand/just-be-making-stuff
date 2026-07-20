@echo off
REM Double-click this to open the AUTOCUT window.
REM It activates the local virtual environment and launches the UI.
cd /d "%~dp0"

if exist ".venv\Scripts\activate.bat" (
    call ".venv\Scripts\activate.bat"
) else (
    echo Could not find .venv in this folder.
    echo Run the one-time setup first ^(see README.md^): python -m venv .venv, then pip install -e .
    pause
    exit /b 1
)

vanscut ui
if errorlevel 1 pause
