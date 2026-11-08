@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "PLATFORM=%~1"
set "DATA_DIR=%~2"
set "ROOT_DIR=%~dp0"

if not defined PLATFORM (
  echo Missing platform argument. Use MT4 or MT5. 1>&2
  exit /b 2
)
if not defined DATA_DIR (
  echo Missing MetaTrader data directory. 1>&2
  exit /b 3
)
if not defined TRADINGHERO_BRIDGE_TOKEN (
  echo Missing TRADINGHERO_BRIDGE_TOKEN environment variable. 1>&2
  exit /b 4
)

if /I "%PLATFORM%"=="MT4" (
  set "MQL_DIR=MQL4"
  set "BINARY_NAME=TradingHeroBridge.ex4"
  set "SOURCE_DIR=mt4"
  set "BRIDGE_URL=http://127.0.0.1"
) else if /I "%PLATFORM%"=="MT5" (
  set "MQL_DIR=MQL5"
  set "BINARY_NAME=TradingHeroBridge.ex5"
  set "SOURCE_DIR=mt5"
  set "BRIDGE_URL=http://127.0.0.1:81"
) else (
  echo Unsupported platform: %PLATFORM%. Use MT4 or MT5. 1>&2
  exit /b 5
)

if not exist "%DATA_DIR%\%MQL_DIR%\" (
  echo Invalid MetaTrader data directory: %DATA_DIR% 1>&2
  exit /b 6
)

set "SOURCE_FILE=%ROOT_DIR%%SOURCE_DIR%\%BINARY_NAME%"
set "EA_DIR=%DATA_DIR%\%MQL_DIR%\Experts\TradingHero"
set "CONFIG_DIR=%DATA_DIR%\%MQL_DIR%\Files\TradingHero"
set "CONFIG_FILE=%CONFIG_DIR%\bridge.conf"

if not exist "%SOURCE_FILE%" (
  echo Missing bridge binary: %SOURCE_FILE% 1>&2
  exit /b 7
)

if not exist "%EA_DIR%\" mkdir "%EA_DIR%" || exit /b 8
if not exist "%CONFIG_DIR%\" mkdir "%CONFIG_DIR%" || exit /b 9

copy /Y "%SOURCE_FILE%" "%EA_DIR%\%BINARY_NAME%" >nul || exit /b 10
> "%CONFIG_FILE%" (
  echo %BRIDGE_URL%
  echo %TRADINGHERO_BRIDGE_TOKEN%
) || exit /b 11

echo TradingHero MetaTrader bridge deployed successfully.
exit /b 0
