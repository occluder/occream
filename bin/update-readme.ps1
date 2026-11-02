#Requires -Version 5.1

<#
.SYNOPSIS
    Regenerates the manifest table in the bucket's README.

.DESCRIPTION
    Reads every manifest in the bucket directory (except the template) and
    rebuilds the table between the <!-- manifests:start --> and
    <!-- manifests:end --> markers in README.md.

    The version comes from the manifest itself. The "Last updated" column is
    the date of the last commit that touched that manifest, or today's date
    when the manifest has changes that are not committed yet, falling back to
    the file's last write time when git is unavailable (for example in a
    shallow checkout). A pending change counts as today so the table can be
    regenerated before the update is committed, which is what lets the whole
    update land in a single commit.

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

# Built from code points to keep this file ASCII, so Windows PowerShell 5.1
# reads it correctly regardless of its encoding.
$globe = [System.Char]::ConvertFromUtf32(0x1F310) # globe, links to the homepage
$page = [System.Char]::ConvertFromUtf32(0x1F4C4) # page, links to the manifest file

$repoRoot = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $root = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $root) { $repoRoot = $root.Trim() }
}

function Get-RepoRelativePath {
    param([string]$Path)

    if (-not $repoRoot) { return $null }

    Push-Location -Path $repoRoot
    try {
        $relative = Resolve-Path -Path $Path -Relative -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }

    if (-not $relative) { return $null }

    $relative = "$relative" -replace '\\', '/'
    if ($relative.StartsWith('./')) { $relative = $relative.Substring(2) }
    # Anything above the repository root is not addressable by git.
    if ($relative.StartsWith('../')) { return $null }

    return $relative
}

function Get-ManifestLastUpdated {
    param([string]$Path)

    $relative = Get-RepoRelativePath -Path $Path
    if ($relative) {
        # Uncommitted changes are the update this run is about to commit.
        $pending = git -C $repoRoot status --porcelain -- $relative 2>$null
        if ($LASTEXITCODE -eq 0 -and $pending) {
            return (Get-Date).ToString('yyyy-MM-dd')
        }

        $date = git -C $repoRoot log -1 --format=%cs -- $relative 2>$null
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
            Homepage    = $manifest.homepage
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
    $links = @()
    if ($_.Homepage) { $links += "[$globe]($($_.Homepage))" }
    $links += "[$page](bucket/$($_.Name).json)"
    "| $($_.Name) $($links -join ' ') | $($_.Version) | $($_.LastUpdated) |"
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
