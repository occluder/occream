#Requires -Version 5.1

<#
.SYNOPSIS
    Regenerates the manifest table in the bucket's README.

.DESCRIPTION
    Reads every manifest in the bucket directory (except the template) and
    rebuilds the table between the <!-- manifests:start --> and
    <!-- manifests:end --> markers in README.md.

    The version comes from the manifest itself. The "Last updated" column is
    the date of the last commit that touched that manifest, falling back to
    the file's last write time when git is unavailable (for example in a
    shallow checkout).

.PARAMETER BucketDir
    Bucket directory to scan. Defaults to the bucket next to this script.

.PARAMETER ReadmePath
    README file to update. Defaults to the README next to this script.

.EXAMPLE
    ./bin/update-readme.ps1
#>
[CmdletBinding()]
param(
    [string]$BucketDir,
    [string]$ReadmePath
)

$ErrorActionPreference = 'Stop'

if (-not $BucketDir) { $BucketDir = Join-Path $PSScriptRoot '../bucket' }
if (-not $ReadmePath) { $ReadmePath = Join-Path $PSScriptRoot '../README.md' }

$startMarker = '<!-- manifests:start -->'
$endMarker = '<!-- manifests:end -->'

function Get-ManifestLastUpdated {
    param([string]$Path)

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $date = git log -1 --format=%cs -- $Path 2>$null
        if ($LASTEXITCODE -eq 0 -and $date) {
            return $date.Trim()
        }
    }

    return (Get-Item $Path).LastWriteTime.ToString('yyyy-MM-dd')
}

$rows = Get-ChildItem -Path $BucketDir -Filter '*.json' |
    Where-Object { $_.Name -ne 'app-name.json.template' } |
    ForEach-Object {
        $manifest = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        [PSCustomObject]@{
            Name        = $_.BaseName
            Version     = $manifest.version
            LastUpdated = Get-ManifestLastUpdated -Path $_.FullName
        }
    } |
    Sort-Object Name

$readme = Get-Content -Path $ReadmePath -Raw
if ($readme -notmatch [regex]::Escape($startMarker) -or $readme -notmatch [regex]::Escape($endMarker)) {
    throw "Could not find the '$startMarker' and '$endMarker' markers in '$ReadmePath'."
}

$newline = if ($readme.Contains("`r`n")) { "`r`n" } else { "`n" }

$lines = @(
    '| Manifest | Version | Last updated |'
    '| --- | --- | --- |'
) + ($rows | ForEach-Object {
    "| [$($_.Name)](bucket/$($_.Name).json) | $($_.Version) | $($_.LastUpdated) |"
})

$table = $lines -join $newline
$pattern = "(?s)$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))"
$replacement = "$startMarker$newline$table$newline$endMarker"
$updated = [regex]::Replace($readme, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })

if ($updated -eq $readme) {
    Write-Host 'README.md is already up to date.'
    return
}

[System.IO.File]::WriteAllText($ReadmePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "README.md updated with $(@($rows).Count) manifest(s)."
