@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "exit_code=%ERRORLEVEL%"
echo.
if not "%exit_code%"=="0" (
  echo Installation failed. Review the error above.
) else (
  echo Installation completed successfully.
)
pause
exit /b %exit_code%
