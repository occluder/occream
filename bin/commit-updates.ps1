#Requires -Version 5.1

<#
.SYNOPSIS
    Commits everything a bucket update run changed as one commit and pushes it.

.DESCRIPTION
    Regenerates the README table and commits it together with the manifests it
    describes, so an update is one entry in the history instead of one commit
    for the manifest and another one for the README.

    The commit message follows the bucket convention: a single updated manifest
    is named in the subject ('<app>: Update to version <version>'), several
    manifests share an 'Update manifests' subject with one line per manifest in
    the body, and a run that only touches the README keeps the
    'README: Update manifest table [skip ci]' subject.

    Before pushing, the commit is rebased onto whatever landed on the remote in
    the meantime and the README is regenerated once more, so the table always
    matches the manifests of the pushed commit.

.PARAMETER BucketDir
    Bucket directory to commit. Defaults to the bucket next to this script.

.PARAMETER ReadmePath
    README file to commit. Defaults to the README next to this script.

.PARAMETER Branch
    Branch to push to. Defaults to the checked out branch.

.PARAMETER NoPush
    Commit locally without pulling or pushing.

.EXAMPLE
    ./bin/commit-updates.ps1

.EXAMPLE
    ./bin/commit-updates.ps1 -NoPush
#>
[CmdletBinding()]
param(
    [string]$BucketDir,
    [string]$ReadmePath,
    [string]$Branch,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

if (-not $BucketDir) { $BucketDir = Join-Path $PSScriptRoot '../bucket' }
if (-not $ReadmePath) { $ReadmePath = Join-Path $PSScriptRoot '../README.md' }

$updateReadme = Join-Path $PSScriptRoot 'update-readme.ps1'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required.'
}

function Invoke-Git {
    param([string[]]$Arguments)

    # Windows PowerShell 5.1 turns redirected native stderr into a terminating
    # error while $ErrorActionPreference is 'Stop', before the exit code can be
    # inspected. Collect the output first, then decide.
    $ErrorActionPreference = 'Continue'
    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code ${exitCode}:`n$($output -join "`n")"
    }

    return $output
}

function Get-RepoRelativePath {
    param([string]$Path, [string]$Root)

    Push-Location -Path $Root
    try {
        $relative = Resolve-Path -Path $Path -Relative -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }

    if (-not $relative) {
        throw "'$Path' does not exist."
    }

    $relative = "$relative" -replace '\\', '/'
    if ($relative.StartsWith('./')) { $relative = $relative.Substring(2) }
    if ($relative.StartsWith('../')) {
        throw "'$Path' is outside the repository at '$Root'."
    }

    return $relative
}

$repoRoot = (Invoke-Git @('rev-parse', '--show-toplevel')).Trim()
if (-not $repoRoot) { throw 'Not inside a git repository.' }

$bucketRel = Get-RepoRelativePath -Path $BucketDir -Root $repoRoot
$readmeRel = Get-RepoRelativePath -Path $ReadmePath -Root $repoRoot

Push-Location -Path $repoRoot
try {
    # The README belongs to the same change as the manifests it lists.
    & $updateReadme -BucketDir $BucketDir -ReadmePath $ReadmePath

    $pending = @(Invoke-Git @('status', '--porcelain', '--untracked-files=all', '--', $bucketRel, $readmeRel))
    if ($pending.Count -eq 0) {
        Write-Host 'No changes to commit.'
        return
    }

    $bucketPending = @(Invoke-Git @('status', '--porcelain', '--untracked-files=all', '--', $bucketRel))

    $manifestPaths = @()
    $manifestPaths += Invoke-Git @('diff', '--name-only', 'HEAD', '--', $bucketRel)
    $manifestPaths += Invoke-Git @('ls-files', '--others', '--exclude-standard', '--', $bucketRel)
    $manifestPaths = @($manifestPaths |
            Where-Object { $_ -and $_ -like '*.json' -and (Split-Path -Leaf $_) -ne 'app-name.json.template' -and (Test-Path $_) } |
            Sort-Object -Unique)

    $updates = @($manifestPaths | ForEach-Object {
            $manifest = Get-Content -Path $_ -Raw | ConvertFrom-Json
            [PSCustomObject]@{
                Name    = [System.IO.Path]::GetFileNameWithoutExtension($_)
                Version = $manifest.version
            }
        } | Where-Object { $_.Version })

    if ($updates.Count -eq 1) {
        $subject = "$($updates[0].Name): Update to version $($updates[0].Version)"
        $message = $subject
    } elseif ($updates.Count -gt 1) {
        $subject = 'Update manifests'
        $message = "$subject`n`n" + (($updates | ForEach-Object { "- $($_.Name): $($_.Version)" }) -join "`n")
    } elseif ($bucketPending.Count -gt 0) {
        # Removed or renamed manifests have no version to report.
        $subject = 'Update manifests'
        $message = $subject
    } else {
        $subject = 'README: Update manifest table [skip ci]'
        $message = $subject
    }

    Invoke-Git @('add', '--', $bucketRel, $readmeRel) | Out-Null
    Invoke-Git @('commit', '-m', $message) | Out-Null
    Write-Host "Committed: $subject"

    if ($NoPush) {
        Write-Host 'Not pushed (-NoPush).'
        return
    }

    $branchName = if ($Branch) { $Branch } else { (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Trim() }
    if ($branchName -eq 'HEAD') { throw 'Detached HEAD: pass -Branch.' }

    # Pick up anything that landed while the manifests were being updated.
    try {
        Invoke-Git @('pull', '--rebase', '--autostash', 'origin', $branchName) | Out-Null
    } catch {
        & git rebase --abort 2>$null
        throw
    }

    # The rebase can change the commit dates the table is built from.
    & $updateReadme -BucketDir $BucketDir -ReadmePath $ReadmePath
    if (@(Invoke-Git @('status', '--porcelain', '--', $readmeRel)).Count -gt 0) {
        Invoke-Git @('add', '--', $readmeRel) | Out-Null
        Invoke-Git @('commit', '--amend', '--no-edit') | Out-Null
        Write-Host 'README refreshed after rebase.'
    }

    Invoke-Git @('push', 'origin', $branchName) | Out-Null
    Write-Host "Pushed to origin/$branchName."
} finally {
    Pop-Location
}
