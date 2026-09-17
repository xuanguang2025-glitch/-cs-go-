@echo off
chcp 65001 >nul
REM ============================================
REM  PROJECT STRIKE - 用引擎直接运行工程 (Godot 4.4.1)
REM  (本文件是 UTF-8 编码, 先切 65001 代码页, 否则中文报错会乱码)
REM  想玩独立发布版请改用 play_game.bat
REM ============================================
cd /d "%~dp0"
if exist "..\.tools\GodotSteam_Editor.exe" (
    REM Steam 集成版: 用 GodotSteam 引擎运行, 游戏内 Steam 单例可用
    start "" "..\.tools\GodotSteam_Editor.exe" --path "%~dp0" --resolution 1600x900
    exit /b 0
)
if exist "..\.tools\Godot441.exe" (
    start "" "..\.tools\Godot441.exe" --path "%~dp0" --resolution 1600x900
    exit /b 0
)
if exist "..\.tools\Godot.exe" (
    start "" "..\.tools\Godot.exe" --path "%~dp0" --resolution 1600x900
    exit /b 0
)
echo [错误] 在 ..\.tools\ 下没有找到 Godot 引擎
echo 期望: GodotSteam_Editor.exe (Steam 版) 或 Godot441.exe / Godot.exe
pause
exit /b 1
