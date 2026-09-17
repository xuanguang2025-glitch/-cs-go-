@echo off
chcp 65001 >nul
REM ============================================
REM  PROJECT STRIKE - 启动游戏
REM
REM  优先运行 build\PROJECT_STRIKE.exe —— 独立发布版,
REM  不需要 Godot 引擎, 拷到哪台机器都能跑。
REM
REM  如果还没有构建产物, 就退回用 .tools 里的 Godot 引擎
REM  直接运行工程(效果一样, 只是依赖引擎目录)。
REM ============================================
cd /d "%~dp0"

if exist "build\PROJECT_STRIKE.exe" (
    echo.
    echo   正在启动 PROJECT STRIKE ^(独立发布版^)
    echo   build\PROJECT_STRIKE.exe
    echo.
    cd /d "%~dp0build"
    start "" "PROJECT_STRIKE.exe"
    exit /b 0
)

echo.
echo   没有找到 build\PROJECT_STRIKE.exe
echo   改用 Godot 引擎直接运行工程...
echo   ^(想生成独立 exe, 双击 build_release.bat^)
echo.

if exist "..\.tools\GodotSteam_Editor.exe" (
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

echo   [错误] 既没有发布版, 也没有找到 Godot 引擎。
echo   期望引擎位置: ..\.tools\GodotSteam_Editor.exe
echo.
pause
exit /b 1
