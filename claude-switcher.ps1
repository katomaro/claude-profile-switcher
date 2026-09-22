<#
.SYNOPSIS
    Claude Desktop Profile Switcher - Switch between multiple Claude accounts
.DESCRIPTION
    Swaps all Electron session files (auth tokens, cookies, local storage, etc.)
    to switch between different Claude accounts without re-logging in.
    Keeps vm_bundles (12GB+ Cowork VM) shared across profiles.
.NOTES
    Version: 1.1.0
    Requires: Windows 10/11, Claude Desktop 1.1.x+ (Microsoft Store or standalone installer)
    Admin may be needed for Cowork VM sessiondata repair (diskpart)
    -Force auto-closes Claude and cycles CoworkVMService (the latter needs admin)
#>

param(
    [Parameter(Position=0)] [string]$Action = "list",
    [Parameter(Position=1)] [string]$Name = "",
    # Force path: force-close Claude and cycle Claude's own Cowork VM service
    # (CoworkVMService) instead of asking you to close Claude by hand. Cycling
    # the service needs admin; without elevation it force-closes Claude only.
    [switch]$Force
)

# === Config ===
# Resolve the Claude Desktop data directory. Works for BOTH install types:
#   - Standalone installer:   %APPDATA%\Claude
#   - Microsoft Store / MSIX:  %LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Roaming\Claude
# The MSIX package family name is derived dynamically (never hardcoded) via the
# same Get-AppxPackage call Start-Claude already uses, then we pick whichever
# candidate actually holds the live login (config.json). On modern MSIX both
# paths resolve to the same physical files, so either works.
function Resolve-ClaudeDir {
    $candidates = @()
    $pkg = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        $candidates += "$env:LOCALAPPDATA\Packages\$($pkg.PackageFamilyName)\LocalCache\Roaming\Claude"
    }
    $candidates += "$env:APPDATA\Claude"

    # Prefer a candidate that actually contains the live login.
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "config.json")) { return $c }
    }
    # Otherwise prefer one that at least exists as a directory.
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    # Fall back to the standalone location so error messages point somewhere sane.
    return "$env:APPDATA\Claude"
}

$claudeDir   = Resolve-ClaudeDir
$instanceDir = "$env:USERPROFILE\.claude-instances"
$currentFile = "$instanceDir\_current_profile"

# Session files to swap per profile (everything auth/session related, ~5MB total)
# These store OAuth tokens, cookies, and browser session state
$sessionFiles = @(
    "config.json",       # OAuth token
    "Preferences",       # Electron preferences
    "DIPS",              # Bounce tracking DB
    "DIPS-wal",
    "SharedStorage",     # Shared storage DB
    "SharedStorage-wal",
    "ant-did"            # Anthropic device ID
)
$sessionDirs = @(
    "Local Storage",     # localStorage (auth state)
    "Session Storage",   # sessionStorage
    "Network",           # Cookies, HSTS, etc.
    "IndexedDB",         # IndexedDB databases
    "WebStorage"         # Web storage
)

# Files that are SHARED across profiles (never swapped):
#   vm_bundles/       - 12GB+ Cowork VM (file-locked by Hyper-V)
#   claude_desktop_config.json - MCP server config
#   Local State       - DPAPI encryption key
#   Cache/, Code Cache/, GPUCache/ - runtime caches

# === Helpers ===
function Write-OK   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Err  { param($m) Write-Host "  [ERR] $m" -ForegroundColor Red }
function Write-Warn { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Info { param($m) Write-Host "  [i] $m" -ForegroundColor DarkCyan }

function Get-CurrentProfile {
    if (Test-Path $currentFile) { return (Get-Content $currentFile -Raw).Trim() }
    return $null
}

function Get-Profiles {
    $profiles = @()
    if (Test-Path $instanceDir) {
        Get-ChildItem -Path $instanceDir -Directory | Where-Object {
            $_.Name -notmatch '^_' -and (Test-Path "$($_.FullName)\config.json")
        } | ForEach-Object { $profiles += $_.Name }
    }
    return $profiles
}

function Save-Session {
    param([string]$profileName)
    $dest = "$instanceDir\$profileName"
    if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    
    foreach ($f in $sessionFiles) {
        $src = "$claudeDir\$f"
        if (Test-Path $src) { Copy-Item $src "$dest\$f" -Force }
    }
    foreach ($d in $sessionDirs) {
        $src = "$claudeDir\$d"
        if (Test-Path $src) {
            $dDest = "$dest\$d"
            if (Test-Path $dDest) { Remove-Item $dDest -Recurse -Force }
            Copy-Item $src $dDest -Recurse -Force
        }
    }
}

function Load-Session {
    param([string]$profileName)
    $src = "$instanceDir\$profileName"
    
    foreach ($f in $sessionFiles) {
        $fSrc = "$src\$f"
        if (Test-Path $fSrc) { Copy-Item $fSrc "$claudeDir\$f" -Force }
    }
    foreach ($d in $sessionDirs) {
        $dSrc = "$src\$d"
        if (Test-Path $dSrc) {
            $dDest = "$claudeDir\$d"
            if (Test-Path $dDest) { Remove-Item $dDest -Recurse -Force }
            Copy-Item $dSrc $dDest -Recurse -Force
        }
    }
}

function Stop-ClaudeGracefully {
    param([int]$TimeoutSeconds = 600)

    Write-Host ""
    $claude = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
    if (-not $claude) {
        Write-OK "Claude Desktop is not running"
        return $true
    }

    Write-Warn "Please close Claude Desktop manually:"
    Write-Warn "  RIGHT-CLICK system tray icon -> Exit"
    Write-Info "Waiting for Claude to exit... (timeout: ${TimeoutSeconds}s)"
    Write-Host ""

    # We wait ONLY on the Claude process tree, NOT on 'vmwp'.
    # 'vmwp' (Hyper-V VM Worker Process) is shared system-wide: Windows runs one
    # per VM, so WSL2, Docker Desktop, Windows Sandbox, and any Hyper-V guest each
    # keep their own vmwp alive. Gating on "no vmwp" hangs forever on any machine
    # running another VM (the reported MSIX/"waiting for Claude to exit" hang).
    # The session files we swap are held by Claude.exe, not vmwp; vm_bundles (the
    # only disk vmwp locks) is never swapped, so its lock is irrelevant here.
    $elapsed = 0
    while ($true) {
        if (-not (Get-Process -Name "Claude" -ErrorAction SilentlyContinue)) {
            Write-OK "Claude exited cleanly (${elapsed}s)"
            # Brief settle so Electron/Chromium release file handles before we copy.
            Start-Sleep -Seconds 2
            return $true
        }

        if ($elapsed -ge $TimeoutSeconds) {
            Write-Err "Timed out after ${TimeoutSeconds}s waiting for Claude to exit."
            Write-Err "Close Claude Desktop fully (tray -> Exit) and re-run."
            return $false
        }

        Start-Sleep -Seconds 1
        $elapsed++

        if ($elapsed % 30 -eq 0) {
            Write-Info "${elapsed}s - still waiting for Claude to close..."
        }
    }
}

# Tracks whether WE stopped Claude's Cowork VM service, so we only ever restart
# what this run stopped (never touch a service the user is managing themselves).
$script:CoworkSvcStopped = $false

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Stop-CoworkService {
    # Stops CoworkVMService = Claude's OWN Cowork VM service (cowork-svc.exe).
    # This is scoped to Claude only: it does NOT touch vmms, WSL2, Docker, or any
    # other VM. It is the correct, safe alternative to the "Stop-Service vmms"
    # some issue reports suggest. Requires admin (the service runs as LocalSystem).
    $svc = Get-Service -Name "CoworkVMService" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return }

    if (-not (Test-IsAdmin)) {
        Write-Warn "Not elevated - leaving CoworkVMService running."
        Write-Warn "  Re-run from an admin PowerShell for the full --force cycle."
        return
    }
    try {
        Stop-Service -Name "CoworkVMService" -Force -ErrorAction Stop
        $script:CoworkSvcStopped = $true
        Write-OK "Stopped CoworkVMService (Claude's Cowork VM only)"
    } catch {
        Write-Warn "Could not stop CoworkVMService: $($_.Exception.Message)"
    }
}

function Start-CoworkService {
    # Restart the Cowork VM service only if THIS run stopped it.
    if (-not $script:CoworkSvcStopped) { return }
    try {
        Start-Service -Name "CoworkVMService" -ErrorAction Stop
        $script:CoworkSvcStopped = $false
        Write-OK "Restarted CoworkVMService"
    } catch {
        Write-Warn "Could not restart CoworkVMService: $($_.Exception.Message)"
        Write-Warn "  Start it manually: Start-Service CoworkVMService"
    }
}

function Stop-ClaudeForceful {
    # --force path: stop Claude's scoped Cowork VM service (if admin), then
    # force-kill Claude. No manual tray-Exit, no waiting on other VMs.
    Write-Host ""
    Stop-CoworkService

    if (Get-Process -Name "Claude" -ErrorAction SilentlyContinue) {
        Stop-Process -Name "Claude" -Force -ErrorAction SilentlyContinue
        Write-Warn "Force-closed Claude (unclean exit)."
        Write-Info "  For a clean shutdown, switch without --force and close Claude via the tray."
    } else {
        Write-OK "Claude Desktop is not running"
    }

    # Confirm it is actually gone before we start swapping files.
    $elapsed = 0
    while ((Get-Process -Name "Claude" -ErrorAction SilentlyContinue) -and $elapsed -lt 30) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
    if (Get-Process -Name "Claude" -ErrorAction SilentlyContinue) {
        Write-Err "Claude still running after force-kill; aborting to avoid a torn swap."
        Start-CoworkService   # leave the system as we found it
        return $false
    }

    Start-Sleep -Seconds 2
    return $true
}

function Repair-CoworkVM {
    # Cowork runs in a Hyper-V VM that needs sessiondata.vhdx
    # If this file is missing, VM fails with "HCS operation failed" error
    # Fix: recreate empty VHDX with diskpart (requires admin)
    $sdPath = "$claudeDir\vm_bundles\claudevm.bundle\sessiondata.vhdx"
    
    # Only check if vm_bundles exists (Cowork may not be installed)
    if (-not (Test-Path "$claudeDir\vm_bundles\claudevm.bundle")) { return }
    
    if (-not (Test-Path $sdPath)) {
        Write-Host ""
        Write-Host "  !! sessiondata.vhdx MISSING! Auto-rebuilding..." -ForegroundColor Red -BackgroundColor Yellow
        Write-Host ""
        
        $dpScript = [System.IO.Path]::GetTempFileName()
        @"
create vdisk file="$sdPath" maximum=1024 type=expandable
exit
"@ | Set-Content $dpScript -Encoding ASCII
        Start-Process diskpart -ArgumentList "/s `"$dpScript`"" -Verb RunAs -Wait
        Remove-Item $dpScript -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $sdPath) {
            Write-OK "sessiondata.vhdx rebuilt"
        } else {
            Write-Err "Failed to rebuild - run as admin: diskpart"
            Write-Err "  create vdisk file=`"$sdPath`" maximum=1024 type=expandable"
        }
    }
}

function Start-Claude {
    # Try Microsoft Store version first, then standalone
    $storeApp = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue
    if ($storeApp) {
        $familyName = $storeApp.PackageFamilyName
        Start-Process "explorer.exe" "shell:AppsFolder\${familyName}!Claude"
    } else {
        $exePath = "$env:LOCALAPPDATA\AnthropicClaude\claude.exe"
        if (Test-Path $exePath) {
            Start-Process $exePath
        } else {
            Write-Err "Claude Desktop not found. Please install it first."
            return
        }
    }
    Start-Sleep -Seconds 2
    Write-OK "Claude Desktop launched!"
}

function Switch-Profile {
    param([string]$target, [bool]$ForceClose)

    $current = Get-CurrentProfile
    $targetDir = "$instanceDir\$target"
    
    if (!(Test-Path "$targetDir\config.json")) {
        Write-Err "Profile '$target' not found."
        Write-Info "Available: $(( Get-Profiles ) -join ', ')"
        return
    }
    
    if ($current -eq $target) {
        Write-Warn "Already on profile '$target'"
        return
    }
    
    Write-Host "  ========================================"
    Write-Host "  Switching: $current -> $target" -ForegroundColor Cyan
    Write-Host "  ========================================"
    
    # Step 1: Close Claude (force path stops Claude's scoped Cowork service too)
    if ($ForceClose) { $closed = Stop-ClaudeForceful } else { $closed = Stop-ClaudeGracefully }
    if (-not $closed) { return }
    Stop-Process -Name "chrome-native-host" -Force -ErrorAction SilentlyContinue

    # Step 2: Save current session
    if ($current) {
        Save-Session $current
        Write-OK "Saved session to '$current'"
    }
    
    # Step 3: Load target session
    Load-Session $target
    Write-OK "Loaded session from '$target'"
    
    # Step 4: Ensure Cowork VM sessiondata exists
    Repair-CoworkVM

    # Step 5: Restart Claude's Cowork VM service if the --force path stopped it
    Start-CoworkService

    # Step 6: Update marker
    Set-Content -Path $currentFile -Value $target -NoNewline
    Write-OK "Profile set to '$target'"

    # Step 7: Launch
    Write-Host ""
    Write-Info "Starting Claude Desktop..."
    Start-Claude
    Write-Host ""
    Write-Host "  Done! Now on profile: $target" -ForegroundColor Green
    Write-Host ""
}

function New-Profile {
    param([string]$name, [bool]$ForceClose)

    $profileDir = "$instanceDir\$name"
    if (Test-Path "$profileDir\config.json") {
        Write-Warn "Profile '$name' already exists. Overwriting..."
    }

    if (!(Test-Path "$claudeDir\config.json")) {
        Write-Err "No config.json found. Please login to Claude Desktop first."
        return
    }

    # Must close Claude to copy locked files (Cookies etc)
    if ($ForceClose) { $closed = Stop-ClaudeForceful } else { $closed = Stop-ClaudeGracefully }
    if (-not $closed) { return }
    Stop-Process -Name "chrome-native-host" -Force -ErrorAction SilentlyContinue

    Save-Session $name
    # Restart Claude's Cowork VM service if the --force path stopped it
    Start-CoworkService
    Set-Content -Path $currentFile -Value $name -NoNewline
    Write-OK "Created profile '$name' from current login"
    Write-OK "Active profile set to '$name'"
}

# === Main ===
Write-Host ""
Write-Host "  Claude Profile Switcher v1.1.0" -ForegroundColor White
Write-Host "  github.com/NeezerGu/claude-profile-switcher" -ForegroundColor DarkGray

if (!(Test-Path $instanceDir)) { New-Item -ItemType Directory -Path $instanceDir -Force | Out-Null }

# Show which Claude data store we resolved, so MSIX vs standalone is never a mystery.
if (Test-Path $claudeDir) {
    Write-Info "Claude data dir: $claudeDir"
} else {
    Write-Warn "Claude data dir not found: $claudeDir"
    Write-Warn "  Install/launch Claude Desktop and log in first."
}

switch ($Action.ToLower()) {
    "list" {
        $current = Get-CurrentProfile
        $profiles = Get-Profiles
        if ($profiles.Count -eq 0) {
            Write-Info "No profiles yet. Run: .\claude-switcher.ps1 create <name>"
        } else {
            Write-Host "  Profiles:"
            foreach ($p in $profiles) {
                if ($p -eq $current) {
                    Write-Host "    - $p <-- active" -ForegroundColor Green
                } else {
                    Write-Host "    - $p" -ForegroundColor White
                }
            }
        }
    }
    "current" {
        $c = Get-CurrentProfile
        if ($c) { Write-Info "Current profile: $c" }
        else { Write-Info "No profile set" }
    }
    "switch" {
        if (!$Name) { Write-Err "Usage: .\claude-switcher.ps1 switch <profile> [-Force]"; return }
        Switch-Profile $Name $Force.IsPresent
    }
    "create" {
        if (!$Name) { Write-Err "Usage: .\claude-switcher.ps1 create <name> [-Force]"; return }
        New-Profile $Name $Force.IsPresent
    }
    "repair" {
        Write-Info "Checking Cowork VM..."
        Repair-CoworkVM
        Write-OK "Check complete"
    }
    default {
        Write-Host "  Usage: .\claude-switcher.ps1 <command> [name]"
        Write-Host ""
        Write-Host "  Commands:"
        Write-Host "    create <name>   - Save current login as a profile"
        Write-Host "    switch <name>   - Switch to a profile"
        Write-Host "    list            - List all profiles"
        Write-Host "    current         - Show active profile"
        Write-Host "    repair          - Fix Cowork VM if broken"
        Write-Host ""
        Write-Host "  Options:"
        Write-Host "    -Force          - Auto-close Claude and cycle CoworkVMService"
        Write-Host "                      instead of a manual tray-Exit (service cycle needs admin)"
        Write-Host ""
        Write-Host "  Quick Setup:"
        Write-Host "    1. Login to Account A in Claude Desktop"
        Write-Host "    2. .\claude-switcher.ps1 create personal"
        Write-Host "    3. Logout, login to Account B"
        Write-Host "    4. .\claude-switcher.ps1 create work"
        Write-Host "    5. .\claude-switcher.ps1 switch personal"
    }
}
Write-Host ""
