param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\testdata\tic80-top50')
)

$ErrorActionPreference = 'Stop'
$baseUrl = 'https://tic80.com'
$catalogUrl = "$baseUrl/play/games/top"
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

function Get-TopGameCards([string]$Html) {
    $pattern = '(?s)<div class="col-md-4"><div class="cart">.*?<a href="(?<detail>/dev/[^"]+)"><img.*?</a>.*?<h2>(?<title>.*?)</h2>.*?<img[^>]+/img/love\.png[^>]*>\s*<span class="tiny-label">(?<likes>\d+)</span>.*?</div></div>'
    foreach ($match in [regex]::Matches($Html, $pattern)) {
        [pscustomobject]@{
            DetailPath = $match.Groups['detail'].Value
            Title = [System.Net.WebUtility]::HtmlDecode($match.Groups['title'].Value.Trim())
            Likes = [int]$match.Groups['likes'].Value
        }
    }
}

$games = [System.Collections.Generic.List[object]]::new()
$firstPage = (Invoke-WebRequest -Uri $catalogUrl -UseBasicParsing).Content
$games.AddRange([object[]](Get-TopGameCards $firstPage))

$page = 1
while ($games.Count -lt 50) {
    $partialUrl = "$catalogUrl`?page=$page&partial=1"
    $fragment = (Invoke-WebRequest -Uri $partialUrl -UseBasicParsing).Content
    $nextGames = @(Get-TopGameCards $fragment)
    if ($nextGames.Count -eq 0) { throw "Catalog page $page returned no games; only found $($games.Count)." }
    foreach ($game in $nextGames) { $games.Add($game) }
    $page++
}

$downloadDate = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
$index = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt 50; $i++) {
    $game = $games[$i]
    $detail = (Invoke-WebRequest -Uri "$baseUrl$($game.DetailPath)" -UseBasicParsing).Content
    $cartMatch = [regex]::Match($detail, 'href="(?<url>/cart/[^"]+\.tic)"')
    if (-not $cartMatch.Success) { throw "Could not find a downloadable .tic cartridge on $($game.DetailPath)" }
    $sourcePath = $cartMatch.Groups['url'].Value
    $sourceName = [System.IO.Path]::GetFileName($sourcePath)
    $localName = '{0:D2}_{1}' -f ($i + 1), $sourceName
    $localFile = Join-Path $outputPath $localName
    Invoke-WebRequest -Uri "$baseUrl$sourcePath" -OutFile $localFile
    $hash = (Get-FileHash -LiteralPath $localFile -Algorithm MD5).Hash.ToLowerInvariant()
    $index.Add([pscustomobject]@{
        Rank = $i + 1
        ROMFileName = $localName
        HashMD5 = $hash
        DateUTC = $downloadDate
        Title = $game.Title
        LikesAtDownload = $game.Likes
        SourceURL = "$baseUrl$sourcePath"
    })
    Write-Progress -Activity 'Downloading top rated TIC-80 games' -Status "$($i + 1) / 50: $($game.Title)" -PercentComplete ((($i + 1) / 50) * 100)
}

$indexPath = Join-Path $outputPath 'index.tsv'
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("Rank`tROMFileName`tHashMD5`tDateUTC`tTitle`tLikesAtDownload`tSourceURL")
foreach ($row in $index) {
    $safeTitle = $row.Title -replace '[\t\r\n]', ' '
    $lines.Add("$($row.Rank)`t$($row.ROMFileName)`t$($row.HashMD5)`t$($row.DateUTC)`t$safeTitle`t$($row.LikesAtDownload)`t$($row.SourceURL)")
}
[System.IO.File]::WriteAllLines($indexPath, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Host "Downloaded $($index.Count) cartridges to $outputPath"
Write-Host "Index: $indexPath"
