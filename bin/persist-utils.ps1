. "$PSScriptRoot\fs-utils.ps1"

# Set-PersistLinks: batch-create folder links and generate a restore script.
# $LinkMap: hashtable mapping persist subdirectory name to original path,
#   use single-quoted delayed expressions, e.g.
#   @{ "appdata" = '$env:APPDATA\MyApp'; "cache" = '$env:USERPROFILE\.cache\myapp' }
Function Resolve-LinkPathExpression {
    param(
        [string]$PathExpression
    )
    return $ExecutionContext.InvokeCommand.ExpandString($PathExpression)
}

Function Write-PortableLog {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [switch]$LeadingNewline
    )
    Write-Host "[Portable Mode] $Message"
}

Function Set-PersistLinks {
    param(
        [string]$PersistDir,
        [hashtable]$LinkMap,
        [bool]$Verbose = $true
    )
    if ($Verbose) {
        Write-Host ""
    }
    foreach ($entry in $LinkMap.GetEnumerator()) {
        $resolvedPath = Resolve-LinkPathExpression -PathExpression ([string]$entry.Value)
        $targetDir = "$PersistDir\$($entry.Key)"
        Set-FolderLink -TargetDir $targetDir -JunctionDir $resolvedPath -Verbose:$Verbose
    }

    # Generate restore script for migrating back to official (non-portable) layout
    $lines = @(
        '# Restore persist data back to original directories.'
        '# Run this AFTER scoop uninstall to migrate from portable back to official install.'
        ''
        'function Write-RestoreLog {'
        '    param('
        '        [string]$Message,'
        '        [ConsoleColor]$Color = [ConsoleColor]::Cyan,'
        '        [switch]$LeadingNewline'
        '    )'
        '    Write-Host "[Portable Mode] $Message"'
        '}'
        ''
        '$linkMap = @{'
    )
    foreach ($entry in $LinkMap.GetEnumerator()) {
        $key = ([string]$entry.Key) -replace "'", "''"
        $value = ([string]$entry.Value) -replace "'", "''"
        $lines += "    '$key' = '$value'"
    }
    $lines += '}'
    $lines += ''
    $lines += 'foreach ($entry in $linkMap.GetEnumerator()) {'
    $lines += '    $src = Join-Path $PSScriptRoot $entry.Key'
    $lines += '    $dst = $ExecutionContext.InvokeCommand.ExpandString($entry.Value)'
    $lines += '    $parent = Split-Path $dst -Parent'
    $lines += '    if (Test-Path $src) {'
    $lines += '        Write-RestoreLog -Message "Copy user data ''$src'' -> ''$dst''."'
    $lines += '        if (-not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }'
    $lines += '        Copy-Item -Path $src -Destination $dst -Recurse -Force'
    $lines += '    } else {'
    $lines += '        Write-RestoreLog -Message "Skip ''$src'' (not found)."'
    $lines += '    }'
    $lines += '}'
    $restoreScriptPath = "$PersistDir\restore-official-data.ps1"
    Set-Content -Path $restoreScriptPath -Value ($lines -join "`r`n") -Encoding UTF8
    if ($Verbose) {
        Write-PortableLog -Message "Create restore script: '$restoreScriptPath'."
    }
}

# Remove-PersistLinks: batch-remove folder links and remind user about the restore script.
Function Remove-PersistLinks {
    param(
        [string]$PersistDir,
        [hashtable]$LinkMap,
        [bool]$Verbose = $true
    )
    if ($Verbose) {
        Write-Host ""
    }
    foreach ($entry in $LinkMap.GetEnumerator()) {
        $resolvedPath = Resolve-LinkPathExpression -PathExpression ([string]$entry.Value)
        $targetDir = "$PersistDir\$($entry.Key)"
        Remove-FolderLink -JunctionDir $resolvedPath -TargetDir $targetDir -Verbose:$Verbose
    }
    if (Test-Path "$PersistDir\restore-official-data.ps1") {
        Write-PortableLog -Message "To restore user data back to original directories, run:"
        Write-PortableLog -Message "powershell -File `"$PersistDir\restore-official-data.ps1`""
    }
}
