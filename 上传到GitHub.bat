@echo off
chcp 65001 >nul
title 上传轻阅 Lite 到 GitHub
echo.
echo ============================================
echo   一键上传到 GitHub（需要先装 Git for Windows）
echo   下载: https://git-scm.com/download/win
echo ============================================
echo.

where git >nul 2>nul
if errorlevel 1 (
  echo [x] 没找到 git。
  echo     请先装 Git for Windows，装完重开这个窗口再跑一次。
  echo.
  pause
  exit /b 1
)

cd /d "%~dp0"

set /p GHUSER=GitHub 用户名（不含 @）: 
set /p GHREPO=仓库名（刚才建的那个）: 

echo.
echo 接下来要粘 Personal Access Token，不是登录密码。
echo 没有的话去这个地址生成（勾 repo 权限）:
echo   https://github.com/settings/tokens/new?scopes=repo^&description=upload
echo.
set /p GHTOKEN=粘贴 Token（粘贴后不回显，正常）: 

if "%GHUSER%"=="" goto :err
if "%GHREPO%"=="" goto :err
if "%GHTOKEN%"=="" goto :err

echo.
echo [1/4] 初始化仓库...
git init -q
git add -A
git -c user.email="upload@local" -c user.name="upload" commit -q -m "轻阅 Lite 初始提交"
git branch -M main

echo [2/4] 绑定远端...
git remote remove origin 2>nul
git remote add origin https://github.com/%GHUSER%/%GHREPO%.git

echo [3/4] 推送...
set GIT_TERMINAL_PROMPT=0
git -c http.extraheader="Authorization: Basic %GHUSER%:%GHTOKEN%" push -u origin main 2>&1 | more

echo.
echo ============================================
echo   完成。打开这个地址就能看到代码：
echo   https://github.com/%GHUSER%/%GHREPO%
echo.
echo   下一步: 去 codemagic.io 用 GitHub 登录
echo   -^> Add application -^> 选这个仓库 -^> Start build
echo ============================================
echo.
pause

rem 清掉可能残留在 git config 里的凭据
git remote set-url origin https://github.com/%GHUSER%/%GHREPO%.git
exit /b 0

:err
echo.
echo [x] 有输入没填，重新跑一次。
pause
exit /b 1
