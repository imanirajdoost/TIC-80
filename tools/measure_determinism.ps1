#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PlayerPath,
    [string]$GamesDirectory = (Join-Path $PSScriptRoot '..\testdata\tic80-top50'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\test-results\determinism'),
    [ValidateRange(2, 20)]
    [int]$Runs = 2,
    [ValidateRange(1, 86400)]
    [int]$DurationSeconds = 10,
    [ValidateRange(1, 1000)]
    [int]$FrameRate = 60,
    [ValidateRange(0, 1000000)]
    [int]$StartupFrames = 200,
    [ValidateRange(0, 1000000)]
    [int]$MaxGames = 0,
    [ValidateRange(0, 86400)]
    [int]$TimeoutSeconds = 0,
    [ValidateRange(0, 3600)]
    [int]$InterRunDelaySeconds = 0,
    [switch]$NoDummyInput
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function ConvertTo-ProcessArgument([string]$Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-ChecksumLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $Path |
            Where-Object { $_ -match '^[0-9a-fA-F]{8}$' } |
            ForEach-Object { $_.ToLowerInvariant() }
    )
}

function Get-ChecksumComparison([string[]]$Baseline, [string[]]$Candidate) {
    $shared = [Math]::Min($Baseline.Count, $Candidate.Count)
    $mismatched = 0
    $first = -1

    for ($i = 0; $i -lt $shared; $i++) {
        if ($Baseline[$i] -ne $Candidate[$i]) {
            $mismatched++
            if ($first -lt 0) { $first = $i }
        }
    }

    $mismatched += [Math]::Abs($Baseline.Count - $Candidate.Count)
    if ($first -lt 0 -and $Baseline.Count -ne $Candidate.Count) {
        $first = $shared
    }

    return [pscustomobject]@{
        Match = ($mismatched -eq 0)
        MismatchedFrames = $mismatched
        FirstMismatch = $first
    }
}

$repoRoot = Resolve-FullPath (Join-Path $PSScriptRoot '..')
$GamesDirectory = Resolve-FullPath $GamesDirectory
$OutputDirectory = Resolve-FullPath $OutputDirectory
$sweepScript = Join-Path $PSScriptRoot 'run_top_tic80_games.ps1'

if (-not (Test-Path -LiteralPath $sweepScript -PathType Leaf)) {
    throw "The sweep script was not found: $sweepScript"
}
if (-not (Test-Path -LiteralPath $GamesDirectory -PathType Container)) {
    throw "Games directory was not found: $GamesDirectory"
}

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
if (-not $PlayerPath -or -not (Test-Path -LiteralPath $PlayerPath -PathType Leaf)) {
    throw 'Could not find player-sdl. Build with -DBUILD_PLAYER=ON or pass -PlayerPath.'
}
$PlayerPath = Resolve-FullPath $PlayerPath

$games = @(Get-ChildItem -LiteralPath $GamesDirectory -Filter '*.tic' -File | Sort-Object Name)
if ($MaxGames -gt 0) {
    $games = @($games | Select-Object -First $MaxGames)
}
if ($games.Count -eq 0) {
    throw "No .tic cartridges were found in $GamesDirectory"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
$runSummaries = [System.Collections.Generic.List[object]]::new()
$powerShell = (Get-Process -Id $PID).Path

for ($run = 1; $run -le $Runs; $run++) {
    $runDirectory = Join-Path $OutputDirectory ("run-{0}" -f $run)
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add($sweepScript)
    $arguments.Add('-PlayerPath')
    $arguments.Add($PlayerPath)
    $arguments.Add('-GamesDirectory')
    $arguments.Add($GamesDirectory)
    $arguments.Add('-OutputDirectory')
    $arguments.Add($runDirectory)
    $arguments.Add('-DurationSeconds')
    $arguments.Add([string]$DurationSeconds)
    $arguments.Add('-FrameRate')
    $arguments.Add([string]$FrameRate)
    $arguments.Add('-StartupFrames')
    $arguments.Add([string]$StartupFrames)
    $arguments.Add('-MaxGames')
    $arguments.Add([string]$MaxGames)
    $arguments.Add('-TimeoutSeconds')
    $arguments.Add([string]$TimeoutSeconds)
    if ($NoDummyInput) { $arguments.Add('-NoDummyInput') }

    $argumentString = (@($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    Write-Host ("Run {0}/{1}: {2}" -f $run, $Runs, $runDirectory)
    $process = Start-Process -FilePath $powerShell -ArgumentList $argumentString -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru -Wait
    $summaryPath = Join-Path $runDirectory 'summary.json'
    $summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
        Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    } else { $null }

    $runSummaries.Add([pscustomobject]@{
        Run = $run
        ExitCode = $process.ExitCode
        Directory = $runDirectory
        Summary = $summary
    })

    if ($run -lt $Runs -and $InterRunDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InterRunDelaySeconds
    }
}

$expectedChecksumFrames = [Math]::Max(0, $DurationSeconds * $FrameRate - $StartupFrames)
$records = [System.Collections.Generic.List[object]]::new()

foreach ($game in $games) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($game.Name)
    $baseline = Get-ChecksumLines (Join-Path $runSummaries[0].Directory ($baseName + '.vram-crc32.txt'))
    $runDetails = [System.Collections.Generic.List[object]]::new()
    $stable = $true
    $mismatchedFrames = 0
    $firstMismatch = -1

    foreach ($runSummary in $runSummaries) {
        $checksumPath = Join-Path $runSummary.Directory ($baseName + '.vram-crc32.txt')
        $checksums = Get-ChecksumLines $checksumPath
        $sweepRecord = $null
        if ($runSummary.Summary) {
            $sweepRecord = @($runSummary.Summary.Results | Where-Object { $_.Cart -eq $game.Name }) | Select-Object -First 1
        }
        $runStatus = if ($sweepRecord) { [string]$sweepRecord.Status } else { 'NO_RESULT' }
        if ($runStatus -ne 'PASS' -or $checksums.Count -ne $expectedChecksumFrames) {
            $stable = $false
        }

        $comparison = Get-ChecksumComparison $baseline $checksums
        if ($runSummary.Run -gt 1 -and -not $comparison.Match) {
            $stable = $false
            $mismatchedFrames += $comparison.MismatchedFrames
            if ($firstMismatch -lt 0) { $firstMismatch = $comparison.FirstMismatch }
        }

        $runDetails.Add([pscustomobject]@{
            Run = $runSummary.Run
            Status = $runStatus
            ExitCode = $runSummary.ExitCode
            ChecksumFrames = $checksums.Count
            ChecksumPath = $checksumPath
            Sha256 = if (Test-Path -LiteralPath $checksumPath -PathType Leaf) {
                (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash.ToLowerInvariant()
            } else { $null }
        })
    }

    $records.Add([pscustomobject][ordered]@{
        Cart = $game.Name
        Status = if ($stable) { 'DETERMINISTIC' } else { 'MISMATCH' }
        Runs = $Runs
        ExpectedChecksumFrames = $expectedChecksumFrames
        BaselineChecksumFrames = $baseline.Count
        MismatchedFrames = $mismatchedFrames
        FirstMismatchChecksumFrame = $firstMismatch
        FirstMismatchEmulatedFrame = if ($firstMismatch -ge 0) { $StartupFrames + $firstMismatch + 1 } else { $null }
        RunDetails = $runDetails
    })
}

$deterministic = @($records | Where-Object Status -eq 'DETERMINISTIC').Count
$percent = if ($records.Count) { [Math]::Round(100.0 * $deterministic / $records.Count, 2) } else { 0.0 }
$summary = [pscustomobject][ordered]@{
    StartedAtUTC = $startedAtUtc
    PlayerPath = $PlayerPath
    GamesDirectory = $GamesDirectory
    OutputDirectory = $OutputDirectory
    Runs = $Runs
    DummyInputEnabled = (-not $NoDummyInput)
    DurationSeconds = $DurationSeconds
    FrameRate = $FrameRate
    StartupFramesExcludedFromCRC = $StartupFrames
    ExpectedChecksumFramesPerGame = $expectedChecksumFrames
    InterRunDelaySeconds = $InterRunDelaySeconds
    GamesCompared = $records.Count
    DeterministicGames = $deterministic
    DeterminismPercent = $percent
    TargetPercent = 90.0
    TargetMet = ($percent -gt 90.0)
    RunsSummary = $runSummaries
    Results = $records
}

$summaryPath = Join-Path $OutputDirectory 'summary.json'
$resultsPath = Join-Path $OutputDirectory 'results.csv'
$analysisPath = Join-Path $OutputDirectory 'analysis.md'
$summary | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$flatRecords = foreach ($record in $records) {
    [pscustomobject][ordered]@{
        Cart = $record.Cart
        Status = $record.Status
        Runs = $record.Runs
        ExpectedChecksumFrames = $record.ExpectedChecksumFrames
        BaselineChecksumFrames = $record.BaselineChecksumFrames
        MismatchedFrames = $record.MismatchedFrames
        FirstMismatchChecksumFrame = $record.FirstMismatchChecksumFrame
        FirstMismatchEmulatedFrame = $record.FirstMismatchEmulatedFrame
    }
}
$flatRecords | Export-Csv -LiteralPath $resultsPath -NoTypeInformation -Encoding UTF8

$analysisLines = [System.Collections.Generic.List[string]]::new()
$analysisLines.Add('# TIC-80 frame determinism report')
$analysisLines.Add('')
$analysisLines.Add(('- Result: {0}/{1} games produced identical post-warm-up VRAM frames across {2} runs ({3:N2}%).' -f $deterministic, $records.Count, $Runs, $percent))
$analysisLines.Add(('- Target: greater than 90%; met: {0}.' -f $summary.TargetMet))
$analysisLines.Add(('- Workload: {0} emulated frames per run; first {1} frames excluded; {2} checksums compared per game.' -f ($DurationSeconds * $FrameRate), $StartupFrames, $expectedChecksumFrames))
$analysisLines.Add(('- Input: {0}.' -f $(if ($NoDummyInput) { 'all-zero input' } else { 'deterministic dummy input' })) )
$analysisLines.Add('')
$analysisLines.Add('A game is deterministic only when every run completed and every post-warm-up checksum matched run 1 exactly.')
$analysisLines.Add('')
$analysisLines.Add('| Cart | Status | Mismatched frames | First emulated mismatch frame |')
$analysisLines.Add('| --- | --- | ---: | ---: |')
foreach ($record in $records) {
    $first = if ($null -eq $record.FirstMismatchEmulatedFrame) { '' } else { $record.FirstMismatchEmulatedFrame }
    $analysisLines.Add("| $($record.Cart) | $($record.Status) | $($record.MismatchedFrames) | $first |")
}
[System.IO.File]::WriteAllLines($analysisPath, $analysisLines)

Write-Host "Metrics: $summaryPath"
Write-Host "Analysis: $analysisPath"
Write-Host ('Determinism: {0}/{1} games ({2:N2}%).' -f $deterministic, $records.Count, $percent)
if (-not $summary.TargetMet) { exit 1 }
