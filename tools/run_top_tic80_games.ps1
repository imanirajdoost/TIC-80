#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PlayerPath,
    [string]$GamesDirectory = (Join-Path $PSScriptRoot '..\testdata\tic80-top50'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\test-results\top50-1m'),
    [ValidateRange(1, 86400)]
    [int]$DurationSeconds = 60,
    [ValidateRange(1, 1000)]
    [int]$FrameRate = 60,
    [ValidateRange(0, 1000000)]
    [int]$StartupFrames = 200,
    [ValidateRange(0, 1000000)]
    [int]$MaxGames = 0,
    [ValidateRange(0, 86400)]
    [int]$TimeoutSeconds = 0,
    [switch]$NoDummyInput,
    [switch]$StopOnFailure
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function ConvertTo-ProcessArgument([string]$Value) {
    # Start-Process receives one native argument string on Windows PowerShell.
    # Quoting every value keeps paths with spaces safe and is harmless for flags.
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-ChecksumMetrics([string]$ChecksumPath) {
    $checksums = @()
    if (Test-Path -LiteralPath $ChecksumPath -PathType Leaf) {
        $checksums = @(
            Get-Content -LiteralPath $ChecksumPath |
                Where-Object { $_ -match '^[0-9a-fA-F]{8}$' } |
                ForEach-Object { $_.ToLowerInvariant() }
        )
    }

    $changed = 0
    for ($i = 1; $i -lt $checksums.Count; $i++) {
        if ($checksums[$i] -ne $checksums[$i - 1]) {
            $changed++
        }
    }

    $first = $null
    $last = $null
    if ($checksums.Count -gt 0) {
        $first = $checksums[0]
        $last = $checksums[$checksums.Count - 1]
    }

    return [pscustomobject]@{
        Count = $checksums.Count
        First = $first
        Last = $last
        Unique = @($checksums | Select-Object -Unique).Count
        Changed = $changed
    }
}

$repoRoot = Resolve-FullPath (Join-Path $PSScriptRoot '..')
$GamesDirectory = Resolve-FullPath $GamesDirectory
$OutputDirectory = Resolve-FullPath $OutputDirectory

if (-not $PlayerPath) {
    $playerCandidates = @(
        (Join-Path $repoRoot 'build\bin\player-sdl.exe'),
        (Join-Path $repoRoot 'build-dummy\bin\player-sdl.exe'),
        (Join-Path $repoRoot 'build\bin\player-sdl')
    )
    $PlayerPath = $playerCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

if (-not $PlayerPath) {
    throw 'Could not find player-sdl. Build with -DBUILD_PLAYER=ON or pass -PlayerPath.'
}

$PlayerPath = Resolve-FullPath $PlayerPath
if (-not (Test-Path -LiteralPath $PlayerPath -PathType Leaf)) {
    throw "Player executable was not found: $PlayerPath"
}
if (-not (Test-Path -LiteralPath $GamesDirectory -PathType Container)) {
    throw "Games directory was not found: $GamesDirectory"
}

$frameCount64 = [int64]$DurationSeconds * [int64]$FrameRate
if ($frameCount64 -gt [int32]::MaxValue) {
    throw 'DurationSeconds * FrameRate is too large for player-sdl --during.'
}
$frameCount = [int]$frameCount64
$expectedChecksumLines = [Math]::Max(0, $frameCount - $StartupFrames)
if ($TimeoutSeconds -eq 0) {
    $TimeoutSeconds = [Math]::Max($DurationSeconds + 30, $DurationSeconds * 2)
}

$games = @(Get-ChildItem -LiteralPath $GamesDirectory -Filter '*.tic' -File | Sort-Object Name)
if ($MaxGames -gt 0) {
    $games = @($games | Select-Object -First $MaxGames)
}
if ($games.Count -eq 0) {
    throw "No .tic cartridges found in $GamesDirectory"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$indexRows = @{}
$indexPath = Join-Path $GamesDirectory 'index.tsv'
if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
    foreach ($row in (Import-Csv -LiteralPath $indexPath -Delimiter ([char]9))) {
        $indexRows[$row.ROMFileName] = $row
    }
}

$playerDirectory = Split-Path -Parent $PlayerPath
$records = [System.Collections.Generic.List[object]]::new()
$startedAtUTC = (Get-Date).ToUniversalTime().ToString('o')
$oldDummyInput = [Environment]::GetEnvironmentVariable('TIC80_DUMMY_INPUTS', 'Process')

try {
    if (-not $NoDummyInput) {
        $env:TIC80_DUMMY_INPUTS = '1'
    }

    for ($gameIndex = 0; $gameIndex -lt $games.Count; $gameIndex++) {
        $game = $games[$gameIndex]
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($game.Name)
        $checksumPath = Join-Path $OutputDirectory ($baseName + '.vram-crc32.txt')
        $stdoutPath = Join-Path $OutputDirectory ($baseName + '.stdout.txt')
        $stderrPath = Join-Path $OutputDirectory ($baseName + '.stderr.txt')
        $rankMatch = [regex]::Match($game.Name, '^(\d+)')
        $rank = if ($rankMatch.Success) { [int]$rankMatch.Groups[1].Value } else { $gameIndex + 1 }
        $title = $game.BaseName
        if ($indexRows.ContainsKey($game.Name)) {
            $title = $indexRows[$game.Name].Title
        }

        $argumentString = '--during {0} --vram-crc {1} {2}' -f (ConvertTo-ProcessArgument ([string]$frameCount)), (ConvertTo-ProcessArgument $checksumPath), (ConvertTo-ProcessArgument $game.FullName)
        $command = '"{0}" {1}' -f $PlayerPath, $argumentString

        Write-Host ('[{0}/{1}] {2}' -f ($gameIndex + 1), $games.Count, $title)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $exitCode = $null
        $timedOut = $false
        $launchError = $null
        $process = $null

        try {
            $process = Start-Process -FilePath $PlayerPath -ArgumentList $argumentString -WorkingDirectory $playerDirectory -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru

            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                try { $process.Kill() } catch { }
                $process.WaitForExit()
            }
            if (-not $timedOut) {
                $exitCode = $process.ExitCode
            }
        }
        catch {
            $launchError = $_.Exception.Message
        }
        finally {
            $stopwatch.Stop()
        }

        $checksumMetrics = Get-ChecksumMetrics $checksumPath
        $coverage = if ($expectedChecksumLines -eq 0) {
            100.0
        } else {
            [Math]::Round(($checksumMetrics.Count * 100.0) / $expectedChecksumLines, 2)
        }
        $status = if ($launchError) {
            'ERROR'
        } elseif ($timedOut) {
            'TIMEOUT'
        } elseif ($exitCode -ne 0) {
            'EXIT_' + $exitCode
        } elseif ($checksumMetrics.Count -ne $expectedChecksumLines) {
            'INCOMPLETE'
        } else {
            'PASS'
        }

        $record = [pscustomobject][ordered]@{
            Rank = $rank
            Cart = $game.Name
            Title = $title
            Status = $status
            ExitCode = $exitCode
            TimedOut = $timedOut
            RequestedSeconds = $DurationSeconds
            RequestedFrames = $frameCount
            ExpectedChecksumFrames = $expectedChecksumLines
            ObservedChecksumFrames = $checksumMetrics.Count
            ChecksumCoveragePercent = $coverage
            ElapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            EffectiveFramesPerSecond = if ($stopwatch.Elapsed.TotalSeconds -gt 0) {
                [Math]::Round($frameCount / $stopwatch.Elapsed.TotalSeconds, 2)
            } else { 0 }
            UniqueChecksums = $checksumMetrics.Unique
            ChangedChecksumFrames = $checksumMetrics.Changed
            FirstChecksum = $checksumMetrics.First
            LastChecksum = $checksumMetrics.Last
            ChecksumPath = $checksumPath
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
            Command = $command
            Error = $launchError
        }
        $records.Add($record)

        if ($status -eq 'PASS') {
            Write-Host ('  PASS: {0:N2}s, {1:N2} effective frames/s, {2} checksum frames' -f $record.ElapsedSeconds, $record.EffectiveFramesPerSecond, $record.ObservedChecksumFrames)
        } else {
            Write-Warning ('  {0}: {1} checksum frames (expected {2})' -f $status, $record.ObservedChecksumFrames, $expectedChecksumLines)
            if ($StopOnFailure) {
                break
            }
        }
    }
}
finally {
    if ($null -eq $oldDummyInput) {
        Remove-Item Env:TIC80_DUMMY_INPUTS -ErrorAction SilentlyContinue
    } else {
        $env:TIC80_DUMMY_INPUTS = $oldDummyInput
    }
}

$summaryPath = Join-Path $OutputDirectory 'summary.json'
$resultsPath = Join-Path $OutputDirectory 'results.csv'
$analysisPath = Join-Path $OutputDirectory 'analysis.md'
$passed = @($records | Where-Object Status -eq 'PASS').Count
$failed = $records.Count - $passed
$averageElapsed = if ($records.Count -gt 0) {
    [Math]::Round((($records | Measure-Object -Property ElapsedSeconds -Average).Average), 3)
} else { 0 }

$summary = [pscustomobject][ordered]@{
    StartedAtUTC = $startedAtUTC
    PlayerPath = $PlayerPath
    GamesDirectory = $GamesDirectory
    OutputDirectory = $OutputDirectory
    DummyInputEnabled = (-not $NoDummyInput)
    DurationSeconds = $DurationSeconds
    FrameRate = $FrameRate
    RequestedFramesPerGame = $frameCount
    StartupFramesExcludedFromCRC = $StartupFrames
    ExpectedChecksumFramesPerGame = $expectedChecksumLines
    TimeoutSeconds = $TimeoutSeconds
    GamesRequested = $games.Count
    GamesCompleted = $records.Count
    Passed = $passed
    Failed = $failed
    AverageElapsedSeconds = $averageElapsed
    Results = $records
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$records | Export-Csv -LiteralPath $resultsPath -NoTypeInformation -Encoding UTF8

$analysisLines = [System.Collections.Generic.List[string]]::new()
$inputMode = if ($NoDummyInput) { 'zero input' } else { 'deterministic dummy input' }
$analysisLines.Add('# TIC-80 automated game sweep')
$analysisLines.Add('')
$analysisLines.Add(('- Requested: {0} game(s), {1} seconds / {2} frames per game.' -f $games.Count, $DurationSeconds, $frameCount))
$analysisLines.Add(('- Input mode: {0}.' -f $inputMode))
$analysisLines.Add(('- Result: {0} passed, {1} failed.' -f $passed, $failed))
$analysisLines.Add(('- Average process time: {0:N3} seconds.' -f $averageElapsed))
$analysisLines.Add('')
$analysisLines.Add('## Interpretation')
$analysisLines.Add('')
$analysisLines.Add(('- PASS means player-sdl exited with code 0 and emitted exactly {0} post-startup VRAM checksums.' -f $expectedChecksumLines))
$analysisLines.Add('- INCOMPLETE means the process exited but did not cover the requested frame window.')
$analysisLines.Add('- TIMEOUT means the watchdog killed a process that did not exit in time.')
$analysisLines.Add('- UniqueChecksums and ChangedChecksumFrames show whether the rendered VRAM changed during the run; they are diagnostics, not pass criteria.')
$analysisLines.Add('')
$analysisLines.Add('## Per-game results')
$analysisLines.Add('')
$analysisLines.Add('| Rank | Cart | Status | Elapsed (s) | Effective FPS | CRC frames | Unique CRCs |')
$analysisLines.Add('| ---: | --- | --- | ---: | ---: | ---: | ---: |')
foreach ($record in $records) {
    $analysisLines.Add("| $($record.Rank) | $($record.Cart) | $($record.Status) | $($record.ElapsedSeconds.ToString('N3')) | $($record.EffectiveFramesPerSecond.ToString('N2')) | $($record.ObservedChecksumFrames)/$($record.ExpectedChecksumFrames) | $($record.UniqueChecksums) |")
}
[System.IO.File]::WriteAllLines($analysisPath, $analysisLines)

Write-Host ''
Write-Host ('Completed: {0} passed, {1} failed.' -f $passed, $failed)
Write-Host "Metrics: $summaryPath"
Write-Host "Analysis: $analysisPath"
if ($failed -gt 0) {
    exit 1
}
