@echo off
rem ============================================================
rem PROJECT STRIKE - push to Gitee + GitHub at once
rem Usage: run "git add -A" and "git commit -m ..." first,
rem        then double-click this file to push both platforms.
rem ============================================================
cd /d "%~dp0"

echo [1/2] Pushing to Gitee (origin/master)...
git push origin master
if errorlevel 1 goto :fail

echo.
echo [2/2] Pushing to GitHub (github/main)...
git push github master:main
if errorlevel 1 goto :fail

echo.
echo ==========================================
echo   All pushes OK! (Gitee + GitHub)
echo ==========================================
pause
exit /b 0

:fail
echo.
echo Push FAILED - copy the error message above and ask for help.
pause
exit /b 1
