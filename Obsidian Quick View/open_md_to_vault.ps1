# open_md_to_vault.ps1 — .md double-click handler.
#
# Decides what to do based on where the source file already lives:
#
#   • If the source is ALREADY inside the main vault:
#       Just fire obsidian://open?vault=...&file=<vault-relative>
#       so Obsidian opens it in place. NO copy. NO TEMP. NO watcher.
#
#   • If the source is OUTSIDE the vault:
#       1. Copy → %TEMP% staging file.
#       2. Move staging file into the vault's TEMP subfolder.
#       3. Fire obsidian:// URL pointing at TEMP/<name>.
#       4. Watch workspace.json; when our file is no longer in any
#          leaf (user closed the tab), delete the temp file.
#       5. Register HKCU\RunOnce as a belt-and-suspenders cleanup.
#
# Wrap with ps2exe -noConsole -noOutput -noError to make the resulting
# .exe fully silent on double-click (no console window, no popups).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'

# ─── CONFIG ─── edit these for your environment ────────────────────
# Defaults assume a vault at:
#   %USERPROFILE%\OneDrive\Documents\Obsidian Vault
# named "Obsidian Vault" in Obsidian's vault list. If yours is elsewhere
# or named differently, change these lines (and re-wrap with ps2exe).
$VaultRoot      = Join-Path $env:USERPROFILE 'OneDrive\Documents\Obsidian Vault'
$VaultName      = 'Obsidian Vault'
$VaultTempDir   = Join-Path $VaultRoot 'TEMP'
$WorkspaceJson  = Join-Path $VaultRoot '.obsidian\workspace.json'
$LogPath        = Join-Path $env:USERPROFILE 'open_md_to_vault.log'
# ───────────────────────────────────────────────────────────────────

function Log($msg) {
    $ts = (Get-Date -Format 'HH:mm:ss.fff')
    Add-Content -LiteralPath $LogPath -Value ('[' + $ts + '] ' + $msg)
}

# Normalize a path to its canonical full form for prefix comparison.
function Get-CanonicalPath([string]$p) {
    return [System.IO.Path]::GetFullPath($p).TrimEnd([char]92)
}

# True if $childPath is inside $parentDir (case-insensitive,
# backslash-boundary-aware so "Foo Backup" doesn't match "Foo").
function Test-PathIsInside([string]$childPath, [string]$parentDir) {
    $c = (Get-CanonicalPath $childPath).ToLowerInvariant()
    $p = (Get-CanonicalPath $parentDir).ToLowerInvariant() + [char]92
    return $c.StartsWith($p)
}

# Walk workspace.json's tree looking for a leaf whose state.state.file
# matches the given vault-relative path. Returns $true if found.
function Find-FileInWorkspace($node, [string]$relPath) {
    if ($null -eq $node) { return $false }
    if ($node.state -and $node.state.state -and $node.state.state.file -eq $relPath) {
        return $true
    }
    if ($node.children) {
        foreach ($c in $node.children) {
            if (Find-FileInWorkspace -node $c -relPath $relPath) { return $true }
        }
    }
    return $false
}

# Fire obsidian://open?vault=...&file=<rel> via ShellExecute.
function Open-InObsidian([string]$vaultRelPath) {
    $vaultEnc = [uri]::EscapeDataString($VaultName)
    $fileEnc  = [uri]::EscapeDataString($vaultRelPath)
    $url      = 'obsidian://open?vault=' + $vaultEnc + '&file=' + $fileEnc
    Log ('url=' + $url)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $url
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    Log ('ShellExecute URL fired')
}

try {
    Log ('=== start ===  Path=' + $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Log ('ERROR: source not found')
        exit 1
    }

    # ── Gate: is the source already inside the main vault? ──────────
    $srcFull   = Get-CanonicalPath $Path
    $vaultFull = Get-CanonicalPath $VaultRoot

    if (Test-PathIsInside -childPath $srcFull -parentDir $vaultFull) {
        # File lives in the vault already — just open it in place.
        $rel = $srcFull.Substring($vaultFull.Length + 1).Replace([char]92, '/')
        Log ('source is INSIDE vault — relative=' + $rel + ' — opening in place, no copy')
        Open-InObsidian -vaultRelPath $rel
        Log ('=== end (in-place) ===')
        exit 0
    }

    Log ('source is OUTSIDE vault — proceeding with copy → TEMP → watch flow')

    # ── Outside-vault flow ──────────────────────────────────────────

    if (-not (Test-Path -LiteralPath $VaultTempDir)) {
        New-Item -ItemType Directory -Path $VaultTempDir -Force | Out-Null
        Log ('created vault TEMP subfolder')
    }

    $leaf      = Split-Path -Leaf $Path
    $leafNoExt = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext       = [System.IO.Path]::GetExtension($leaf)
    if ([string]::IsNullOrEmpty($ext)) { $ext = '.md' }

    # Pick the final filename, deduping on collision.
    $finalName = $leaf
    $finalPath = Join-Path -Path $VaultTempDir -ChildPath $finalName
    $n = 2
    while (Test-Path -LiteralPath $finalPath) {
        $finalName = ('{0} ({1}){2}' -f $leafNoExt, $n, $ext)
        $finalPath = Join-Path -Path $VaultTempDir -ChildPath $finalName
        $n++
    }
    Log ('final vault path=' + $finalPath)

    # Stage 1: copy to local %TEMP%.
    $tempStage = Join-Path -Path $env:TEMP -ChildPath ('obsmd_' + [guid]::NewGuid().Guid + $ext)
    Copy-Item -LiteralPath $Path -Destination $tempStage -Force
    Log ('copied to staging=' + $tempStage)

    # Stage 2: move staging file into the vault.
    Move-Item -LiteralPath $tempStage -Destination $finalPath -Force
    Log ('moved to vault')

    # Belt-and-suspenders RunOnce cleanup. If we get killed before the
    # watcher fires, this runs at next login and moves the (possibly
    # edited) temp file back over the original. `move /Y` overwrites.
    $runOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $runOnceName = 'ObsTempMoveBack_' + ([guid]::NewGuid().Guid.Substring(0,8))
    $runOnceCmd  = 'cmd /c move /Y "' + $finalPath + '" "' + $Path + '"'
    try {
        if (-not (Test-Path -LiteralPath $runOnceKey)) { New-Item -Path $runOnceKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $runOnceKey -Name $runOnceName -Value $runOnceCmd -PropertyType String -Force | Out-Null
        Log ('RunOnce fallback registered as ' + $runOnceName)
    } catch {
        Log ('RunOnce registration failed: ' + $_.Exception.Message)
    }

    # Stage 3: fire the obsidian:// URL.
    $fileRel = 'TEMP/' + $finalName
    Open-InObsidian -vaultRelPath $fileRel

    # Stage 4: watch workspace.json.
    if (-not (Test-Path -LiteralPath $WorkspaceJson)) {
        Log ('workspace.json absent — will not watch; exiting (file stays in TEMP, RunOnce will clean at next login)')
        exit 0
    }

    $wsDir = Split-Path -Parent $WorkspaceJson
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $wsDir
    $watcher.Filter = 'workspace.json'
    $watcher.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $watcher.EnableRaisingEvents = $true

    Log ('watching ' + $WorkspaceJson + ' for ' + $fileRel)

    $everSeen       = $false
    $start          = Get-Date
    $initialTimeout = 120
    $waitTimeoutMs  = 30000

    while ($true) {
        $null = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, $waitTimeoutMs)

        if (-not (Test-Path -LiteralPath $finalPath)) {
            Log ('temp file gone (user removed manually) — exiting')
            break
        }

        $json = $null
        for ($try = 0; $try -lt 3; $try++) {
            try {
                $raw = Get-Content -Raw -LiteralPath $WorkspaceJson -ErrorAction Stop
                $json = $raw | ConvertFrom-Json -ErrorAction Stop
                break
            } catch {
                Start-Sleep -Milliseconds 100
            }
        }
        if ($null -eq $json) {
            Log ('workspace.json read failed — skipping this tick')
            continue
        }

        $found = $false
        foreach ($region in 'main','left','right') {
            if ($json.$region -and (Find-FileInWorkspace -node $json.$region -relPath $fileRel)) {
                $found = $true
                break
            }
        }

        if ($found) {
            if (-not $everSeen) {
                Log ('file confirmed open in a leaf')
                $everSeen = $true
            }
        } else {
            if ($everSeen) {
                # Tab closed. Move the temp file back over the original
                # source — overwriting it. If the user made no edits the
                # overwrite is a no-op; if they edited, the edits land
                # at the original location automatically. Saves having
                # to detect "was this file edited?" separately.
                Log ('file no longer in any leaf — user closed the tab; moving back to source')
                try {
                    Move-Item -LiteralPath $finalPath -Destination $Path -Force -ErrorAction Stop
                    Log ('moved back to ' + $Path)
                } catch {
                    Log ('move-back failed: ' + $_.Exception.Message + ' — leaving temp in vault')
                }
                break
            }
            if (((Get-Date) - $start).TotalSeconds -gt $initialTimeout) {
                Log ('initial timeout — file never appeared in workspace; exiting without move-back')
                break
            }
        }
    }

    # Remove our RunOnce entry on graceful exit so cleanup doesn't
    # also fire at next login.
    try {
        Remove-ItemProperty -LiteralPath $runOnceKey -Name $runOnceName -ErrorAction SilentlyContinue
        Log ('RunOnce fallback removed')
    } catch {}

    Log ('=== end ===')
    exit 0
}
catch {
    Log ('EXCEPTION: ' + $_.Exception.Message)
    exit 2
}
