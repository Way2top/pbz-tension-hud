@echo off
chcp 65001 >nul
title 影之刃零 Tension HUD 正式版 v1.0.0 - 环境检查
echo ============================================
echo   影之刃零 Tension HUD  正式版 v1.0.0
echo   环境检查
echo ============================================
echo.
if exist "%~dp0platform\steam\dwmapi.dll" (
    echo [OK]   已检测到 UE4SS 加载器
) else (
    echo [缺失] 未检测到 UE4SS: platform\steam\dwmapi.dll
    echo        请先安装 UE4SS 3.0.1 再使用本 mod
)
if exist "%~dp0platform\steam\ue4ss\Mods\shared\UEHelpers\UEHelpers.lua" (
    echo [OK]   已检测到 UE4SS 共享库
) else (
    echo [缺失] 未检测到 UE4SS 共享库 shared\UEHelpers
)
if exist "%~dp0platform\steam\ue4ss\Mods\PBZTensionHUD\Scripts\main.lua" (
    echo [OK]   已检测到 mod 本体
) else (
    echo [缺失] 未检测到 mod 本体 - 请确认已解压到游戏根目录
)
if exist "%~dp0platform\steam\ue4ss\Mods\PBZTensionHUD\bin\PBZTensionHUD.exe" (
    echo [OK]   已检测到覆盖层程序
) else (
    echo [缺失] 未检测到覆盖层程序 bin\PBZTensionHUD.exe
)
echo.
echo 检查完毕。按任意键关闭。
pause >nul
