@echo off
rem Runs the repro as many short-lived processes and reports the failure rate.
rem
rem The fault is concentrated in process warm-up, so it must be run as many short
rem processes: a single run only fails about 2.5%% of the time. Release never reproduces
rem it, by design -- there the callee is inlined and no tail call is emitted at all.
rem
rem   run.cmd [runs] [parallelism] [Debug^|Release]
rem   run.cmd 400 8 Debug -NoTailcalls      the control arm: expect 0 failures
rem
rem The process pool and log summary live in run.ps1; this wrapper only forwards to it so
rem there is one implementation to keep correct rather than two.

setlocal
set RUNS=%~1
set PAR=%~2
set CONFIG=%~3
if "%RUNS%"=="" set RUNS=400
if "%PAR%"=="" set PAR=8
if "%CONFIG%"=="" set CONFIG=Debug

where pwsh >nul 2>&1 && (set PS=pwsh) || (set PS=powershell)

%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" -Runs %RUNS% -Parallel %PAR% -Configuration %CONFIG% %~4 %~5
exit /b %ERRORLEVEL%
