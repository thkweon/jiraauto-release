@echo off
setlocal
chcp 65001 > nul
echo =========================================
echo Jira Dashboard Remote Updater
echo =========================================

set "VERSION_URL=https://raw.githubusercontent.com/thkweon/jiraauto-release/main/version.json"
set "VERSION_FILE=version_remote.json"

echo [1/8] Waiting for backend to gracefully exit...
timeout /t 3 /nobreak > nul

echo [2/8] Ensuring all dashboard processes are stopped...
call :KillPortProcess 8000 python Backend
call :KillPortProcess 5173 node Frontend

echo [3/8] Preparing downloader...
if exist "downloader.py" del "downloader.py"
(
echo import urllib.request, sys, ssl
echo ctx = ssl.create_default_context^(^)
echo ctx.check_hostname = False
echo ctx.verify_mode = ssl.CERT_NONE
echo proxy = urllib.request.ProxyHandler^(^)
echo opener = urllib.request.build_opener^(proxy, urllib.request.HTTPSHandler^(context=ctx^)^)
echo urllib.request.install_opener^(opener^)
echo try:
echo     urllib.request.urlretrieve^(sys.argv[1], sys.argv[2]^)
echo except Exception as e:
echo     print^("Download Error:", e^)
echo     sys.exit^(1^)
) > downloader.py

set "PYTHON_EXE="
if exist "backend\venv\Scripts\python.exe" set "PYTHON_EXE=backend\venv\Scripts\python.exe"
if "%PYTHON_EXE%"=="" (
    where python >nul 2>&1
    if not errorlevel 1 set "PYTHON_EXE=python"
)
if "%PYTHON_EXE%"=="" (
    echo [ERROR] Python is not available. Run run.bat first to rebuild the environment.
    if exist "downloader.py" del "downloader.py"
    timeout /t 15
    exit /b 1
)

echo [4/8] Reading release metadata...
if not exist "%VERSION_FILE%" (
    "%PYTHON_EXE%" downloader.py "%VERSION_URL%" "%VERSION_FILE%"
)
if not exist "%VERSION_FILE%" (
    echo [ERROR] Failed to download version metadata.
    if exist "downloader.py" del "downloader.py"
    timeout /t 15
    exit /b 1
)

for /f "delims=" %%A in ('powershell -NoProfile -Command "if (Test-Path '%VERSION_FILE%') { (Get-Content '%VERSION_FILE%' -Raw | ConvertFrom-Json).download_url }"') do set "DOWNLOAD_URL=%%A"
for /f "delims=" %%B in ('powershell -NoProfile -Command "if (Test-Path '%VERSION_FILE%') { (Get-Content '%VERSION_FILE%' -Raw | ConvertFrom-Json).sha256 }"') do set "EXPECTED_HASH=%%B"

if "%DOWNLOAD_URL%"=="" (
    echo [ERROR] Failed to parse download_url.
    if exist "downloader.py" del "downloader.py"
    timeout /t 10
    exit /b 1
)
if "%EXPECTED_HASH%"=="" (
    echo [ERROR] Failed to parse update SHA256 hash.
    if exist "downloader.py" del "downloader.py"
    timeout /t 10
    exit /b 1
)

echo [5/8] Downloading update package...
if exist "update_temp.zip" del "update_temp.zip"
"%PYTHON_EXE%" downloader.py "%DOWNLOAD_URL%" "update_temp.zip"
if not exist "update_temp.zip" (
    echo [ERROR] Failed to download update package.
    if exist "downloader.py" del "downloader.py"
    timeout /t 15
    exit /b 1
)

echo [6/8] Verifying update package integrity...
for /f "delims=" %%H in ('powershell -NoProfile -Command "(Get-FileHash '.\update_temp.zip' -Algorithm SHA256).Hash"') do set "ACTUAL_HASH=%%H"
if /I not "%EXPECTED_HASH%"=="%ACTUAL_HASH%" (
    echo [ERROR] Integrity check failed!
    echo Expected: %EXPECTED_HASH%
    echo Actual  : %ACTUAL_HASH%
    del "update_temp.zip"
    if exist "downloader.py" del "downloader.py"
    timeout /t 10
    exit /b 1
)

echo [7/8] Extracting update and rebuilding dependencies...
powershell -NoProfile -Command "Expand-Archive -Path '.\update_temp.zip' -DestinationPath '.\' -Force"
if errorlevel 1 (
    echo [ERROR] Failed to extract update package.
    del "update_temp.zip"
    if exist "downloader.py" del "downloader.py"
    timeout /t 15
    exit /b 1
)
del "update_temp.zip"

if exist "backend\venv\Scripts\python.exe" (
    backend\venv\Scripts\python.exe -m pip install -r backend\requirements.txt
    if errorlevel 1 (
        echo [ERROR] Failed to update backend dependencies.
        if exist "downloader.py" del "downloader.py"
        timeout /t 15
        exit /b 1
    )
) else (
    echo [WARN] Backend virtual environment is missing. run.bat will rebuild it on next startup.
)

if exist "frontend\package.json" (
    pushd frontend
    call npm.cmd install --no-audit --fund=false
    if errorlevel 1 (
        popd
        echo [ERROR] Failed to update frontend dependencies.
        if exist "downloader.py" del "downloader.py"
        timeout /t 15
        exit /b 1
    )
    popd
) else (
    echo [WARN] frontend\package.json is missing. Skipping frontend dependency update.
)

echo [8/8] Finalizing update...
if exist "downloader.py" del "downloader.py"
move /Y "%VERSION_FILE%" version.json > nul

echo Update applied successfully! Restarting dashboard...
start "" "start_dashboard.vbs"
exit /b 0

:KillPortProcess
set "PORT=%~1"
set "EXPECTED_PROCESS=%~2"
set "LABEL=%~3"

echo [%LABEL%] Checking port %PORT%...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'SilentlyContinue';" ^
  "$connections = Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue;" ^
  "$processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique);" ^
  "if ($processIds.Count -eq 0) { Write-Host '[%LABEL%] No listening process found on port %PORT%.'; exit 0 }" ^
  "foreach ($processId in $processIds) {" ^
  "  $process = Get-Process -Id $processId;" ^
  "  if ($null -eq $process) { continue }" ^
  "  if ($process.ProcessName -notlike '%EXPECTED_PROCESS%*') {" ^
  "    Write-Host ('[%LABEL%] Skipped PID ' + $processId + ' (' + $process.ProcessName + ') because it is not %EXPECTED_PROCESS%.');" ^
  "    continue" ^
  "  }" ^
  "  Write-Host ('[%LABEL%] Stopping PID ' + $processId + ' (' + $process.ProcessName + ') on port %PORT%...');" ^
  "  Stop-Process -Id $processId -Force" ^
  "}"

exit /b 0
