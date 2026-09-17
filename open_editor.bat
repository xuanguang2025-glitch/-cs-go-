@echo off
chcp 65001 >nul
REM ============================================
REM  PROJECT STRIKE - Open Godot Editor (4.4.1)
REM  Use this to edit scenes, tweak balance data,
REM  or export a standalone build.
REM  (GodotSteam_Editor.exe = 带 Steam API 的编辑器)
REM ============================================
cd /d "%~dp0"
if exist "..\.tools\GodotSteam_Editor.exe" (
    start "" "..\.tools\GodotSteam_Editor.exe" --editor --path "%~dp0"
    exit /b 0
)
if exist "..\.tools\Godot441.exe" (
    start "" "..\.tools\Godot441.exe" --editor --path "%~dp0"
    exit /b 0
)
if exist "..\.tools\Godot.exe" (
    start "" "..\.tools\Godot.exe" --editor --path "%~dp0"
    exit /b 0
)
echo [错误] 在 ..\.tools\ 下没有找到 Godot 引擎
pause
exit /b 1
