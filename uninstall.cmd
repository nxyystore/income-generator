@echo off
setlocal EnableDelayedExpansion

set REPO=nxyystore/income-generator
set INSTALLER_URL=https://raw.githubusercontent.com/%REPO%/installer
set IGM_DIR=%APPDATA%\IGM

echo.
echo IGM — Income Generator Uninstaller
echo.

REM --- Parse args: --yes / -y  skips confirmation
set SKIP_CONFIRM=0
for %%a in (%*) do (
    if /I "%%~a"=="--yes" set SKIP_CONFIRM=1
    if /I "%%~a"=="-y" set SKIP_CONFIRM=1
    if /I "%%~a"=="/y" set SKIP_CONFIRM=1
)

if %SKIP_CONFIRM%==0 (
    echo This will remove:
    echo   - %IGM_DIR%\igm.bat and the IGM folder
    echo   - User PATH entry for %IGM_DIR%
    echo   - WSL binary and repo (~/.local/bin/igm and ~/.igm) if WSL is available
    echo.
    set /p ANS="Continue? [y/N] "
    if /I not "!ANS!"=="y" if /I not "!ANS!"=="yes" (
        echo Aborted.
        exit /b 0
    )
    echo.
)

REM --- Run WSL-side uninstaller if WSL is available
wsl -e true >nul 2>&1
if %errorlevel% equ 0 (
    echo ==^> Removing WSL components...
    REM Pass --yes through to the shell script when this .cmd was called with --yes
    if %SKIP_CONFIRM%==1 (
        wsl -- sh -c "curl -fsSL '%INSTALLER_URL%/uninstall.sh' | sh -s -- --yes"
    ) else (
        wsl -- sh -c "curl -fsSL '%INSTALLER_URL%/uninstall.sh' | sh"
    )
    REM Fallback: if curl fetch fails (offline/local install), try local copy inside WSL home
    if !errorlevel! neq 0 (
        echo     Remote uninstall.sh failed — trying local WSL copy...
        wsl -- sh -c "if [ -f ~/.igm/uninstall.sh ]; then sh ~/.igm/uninstall.sh %*; elif [ -f ~/uninstall.sh ]; then sh ~/uninstall.sh %*; else echo '  ! No local uninstall.sh found. Remove ~/.local/bin/igm and ~/.igm manually inside WSL.'; fi"
    )
    echo     Done
) else (
    echo  ! WSL not available — skipping WSL-side cleanup.
    echo    If IGM was installed inside WSL, run inside WSL:
    echo      curl -fsSL %INSTALLER_URL%/uninstall.sh ^| sh
)

REM --- Remove Windows loader dir
if exist "%IGM_DIR%" (
    echo ==^> Removing %IGM_DIR%...
    rmdir /s /q "%IGM_DIR%" 2>nul
    if exist "%IGM_DIR%" (
        echo   ! Could not fully remove %IGM_DIR% — please delete it manually.
    ) else (
        echo     Done
    )
) else (
    echo  ! No Windows loader found at %IGM_DIR%
)

REM --- Remove IGM_DIR from User PATH
echo ==^> Cleaning User PATH...
powershell -NoProfile -Command "& { $d='%IGM_DIR%'; $p=[Environment]::GetEnvironmentVariable('PATH','User'); if (-not [string]::IsNullOrEmpty($p) -and $p -like ('*'+$d+'*')) { $parts=$p -split ';' | Where-Object { $_ -ne $d -and $_ -ne '' }; $new=$parts -join ';'; [Environment]::SetEnvironmentVariable('PATH',$new,'User'); Write-Host '    Done' } else { Write-Host '  ! No PATH entry to clean' } }" 2>nul

REM --- Clean current session PATH so `igm` stops resolving immediately
set "PATH=%PATH:;%IGM_DIR%=;%"
set "PATH=%PATH:%IGM_DIR%;=%"
set "PATH=%PATH:;%IGM_DIR%=%"
if "%PATH:~0,1%"==";" set "PATH=%PATH:~1%"

echo.
echo Uninstall complete.
echo Restart your terminal to refresh PATH. To reinstall, run install.cmd again.
echo.
endlocal
