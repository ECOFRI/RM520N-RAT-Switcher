@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0RM520N-RAT.ps1" -Mode diag
echo.
echo The diagnostics were copied to the clipboard when clipboard access was available.
pause
