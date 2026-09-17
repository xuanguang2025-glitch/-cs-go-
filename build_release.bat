@echo off
chcp 65001 >nul
REM ============================================================
REM  PROJECT STRIKE - Release Builder
REM
REM  双击运行即可; 真正的实现在同目录 build_release.ps1
REM
REM  命令行用法: build_release.bat [版本号]
REM              build_release.bat 1.2.0.0
REM
REM  产物: build\PROJECT_STRIKE.exe
REM ============================================================
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0build_release.ps1" -Version "%~1"
pause
