@echo off
chcp 65001 >nul 2>&1
title PCL 一键恢复工具
echo.
echo   PCL 一键恢复工具 - 正在启动...
echo.
powershell -ExecutionPolicy Bypass -NoProfile -STA -File "%~dp0PCL恢复工具.ps1"
if %errorlevel% neq 0 (
    echo.
    echo   [错误] 程序异常退出！
    echo   如反复出错，请右键此文件选择"以管理员身份运行"
    echo.
    pause
)
