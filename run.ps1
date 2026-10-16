<#
.SYNOPSIS
Runs the repro as many short-lived processes and reports the failure rate.

.DESCRIPTION
The fault is concentrated in process warm-up, so it must be run as many short processes:
a single run only fails about 2.5% of the time. Release never reproduces it, by design --
there the callee is inlined and no tail call is emitted at all.

.EXAMPLE
./run.ps1                   # 400 Debug runs, 8 at a time: expect ~10 failures
./run.ps1 -NoTailcalls      # the control arm: expect 0 failures
#>
param(
    [int]$Runs = 400,
    [int]$Parallel = 8,
    # A corrupted run can livelock instead of crashing, spinning at 100% of one core
    # indefinitely. Without a cap one such run stalls the whole pool.
    [int]$TimeoutSeconds = 300,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [switch]$NoTailcalls,
    [switch]$SkipBuild,
    # Point at an already-published App.exe (implies -SkipBuild). For a machine with no SDK:
    #   dotnet publish App/App.fsproj -c Debug -r win-x64 --self-contained
    # Debug is required -- a Release build inlines the callee and cannot reproduce.
    [string]$Exe
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$project = Join-Path $root 'App/App.fsproj'

if ($NoTailcalls) {
    $outDir = Join-Path $root "bin/notail/$Configuration/"
    $buildArgs = @("-p:Tailcalls=false", "-p:OutputPath=$outDir", "-p:IntermediateOutputPath=obj/notail/$Configuration/net10.0/")
    $target = Join-Path $outDir 'App.exe'
} else {
    $buildArgs = @()
    $target = Join-Path $root "App/bin/$Configuration/net10.0/App.exe"
}

if ($Exe) {
    $target = (Resolve-Path -LiteralPath $Exe).Path
    $SkipBuild = $true
}

if (-not $SkipBuild) {
    Write-Host "Building $Configuration$(if ($NoTailcalls) { ' (Tailcalls=false)' })..."
    & dotnet build $project -c $Configuration @buildArgs -v minimal | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
}
if (-not (Test-Path -LiteralPath $target)) { throw "Not built: $target" }

$logs = Join-Path ([IO.Path]::GetTempPath()) "tailcall-repro-$(Get-Date -Format yyyyMMdd-HHmmss)"
$null = New-Item -ItemType Directory -Force -Path $logs
Write-Host "Running $Runs processes, $Parallel at a time. Logs: $logs"

$running = [System.Collections.ArrayList]::new()
$failures = 0
$timeouts = 0
$abandoned = 0
$next = 1

while ($next -le $Runs -or $running.Count -gt 0) {
    while ($next -le $Runs -and $running.Count -lt $Parallel) {
        $p = Start-Process -FilePath $target -PassThru -NoNewWindow `
            -RedirectStandardOutput (Join-Path $logs "$next.out") -RedirectStandardError (Join-Path $logs "$next.err")
        $null = $running.Add([pscustomobject]@{ Run = $next; Proc = $p })
        $next++
    }

    Start-Sleep -Milliseconds 100

    foreach ($e in @($running)) {
        if (-not $e.Proc.HasExited -and ((Get-Date) - $e.Proc.StartTime).TotalSeconds -gt $TimeoutSeconds) {
            Write-Host "run $($e.Run): still alive after ${TimeoutSeconds}s - killing, counted as a failure"
            try { $e.Proc.Kill() } catch { }

            # A process corrupted badly enough can refuse to die: 0% CPU, and Kill denied even
            # with admin rights. Never block the batch on one -- give it a few seconds, then
            # abandon the slot and carry on. The stray process is reported at the end.
            if (-not $e.Proc.WaitForExit(10000)) {
                Write-Host "run $($e.Run): will not terminate (pid $($e.Proc.Id)) - abandoning it"
                $abandoned++
            }

            $timeouts++
            $failures++
            $running.Remove($e)
        } elseif ($e.Proc.HasExited) {
            # Success is judged from the program's own output, NOT from $e.Proc.ExitCode:
            # under Windows PowerShell 5.1 a Start-Process -PassThru object reports
            # ExitCode as $null even after WaitForExit, and $null -ne 0 is true, so every
            # run gets miscounted as a failure. A run that crashed, printed FAIL, or was
            # killed has no PASS line, so this is equivalent and host-independent.
            [void]$e.Proc.WaitForExit(5000)
            $outFile = Join-Path $logs "$($e.Run).out"

            $passed =
                (Test-Path -LiteralPath $outFile) -and
                ((Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue) -contains 'PASS')

            if (-not $passed) { $failures++ }

            $running.Remove($e)
        }
    }
}

Write-Host ""
Get-ChildItem -LiteralPath $logs -Filter *.out | Get-Content |
    Where-Object { $_ -like 'env *' } | Select-Object -First 1 | ForEach-Object { Write-Host $_ }
Write-Host "runs=$Runs failures=$failures timeouts=$timeouts abandoned=$abandoned"

$stray = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($target)) -ErrorAction SilentlyContinue)
if ($stray.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: $($stray.Count) process(es) from this run are still alive and would not"
    Write-Host "terminate. They are themselves a symptom. PIDs: $($stray.Id -join ', ')"
    Write-Host "If taskkill /F is denied even elevated, the process is wedged in the kernel and"
    Write-Host "only a reboot will clear it; the batch result above is still valid."
}
Get-ChildItem -LiteralPath $logs -Filter *.err | Get-Content |
    Where-Object { $_ -match 'Fatal error|Internal CLR|AccessViolation' } |
    Group-Object | Sort-Object Count -Descending | Select-Object Count, Name -First 5 | Format-Table -AutoSize
Get-ChildItem -LiteralPath $logs -Filter *.out | Get-Content |
    Where-Object { $_ -match '^FAIL ' } |
    ForEach-Object { $_ -replace 'row=\d+', 'row=N' -replace 'col=\d+', 'col=N' } |
    Group-Object | Sort-Object Count -Descending | Select-Object Count, Name -First 5 | Format-Table -AutoSize
if ($failures -gt 0) { exit 1 }
