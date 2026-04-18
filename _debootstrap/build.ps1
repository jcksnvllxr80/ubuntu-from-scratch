# build.ps1 -- Windows wrapper for build.sh.
#
# debootstrap is Linux-only (needs loop mount + chroot), so this script runs
# the real builder inside WSL. WSL + its build tools are PREREQUISITES -- this
# script does not install them. See README.md for setup.
#
# Counterpart to _autoinstall/build.ps1, which can run natively on Windows
# because it only needs to burn a small ISO via IMAPI2.
#
# Usage:
#   .\build.ps1
#   $env:PASSWORD='mypass'; .\build.ps1
#   .\build.ps1 -Distro Ubuntu-24.04

[CmdletBinding()]
param(
  [string]$Password = $(if ($env:PASSWORD) { $env:PASSWORD } else { 'ubuntu' }),
  [string]$Distro   = $(if ($env:WSL_DISTRO) { $env:WSL_DISTRO } else { '' })
)

$ErrorActionPreference = 'Stop'

# ---- Prereq: WSL itself -------------------------------------------------
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
  throw @"
wsl.exe not found. WSL is a prerequisite for this script.

Install it once, then re-run:
  wsl --install -d Ubuntu
  (reboot if prompted)

See README.md for full prerequisites.
"@
}

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- Pick a WSL distro --------------------------------------------------
# Parse `wsl --list --quiet` (strips NUL bytes that WSL emits on older builds).
$rawList = & $wsl.Path --list --quiet 2>$null
$distros = ($rawList | ForEach-Object { $_ -replace '[\x00]','' } | Where-Object { $_.Trim() -ne '' } | Sort-Object)

if ($distros.Count -eq 0) {
  throw "No WSL distros found. Install one with: wsl --install -d Ubuntu"
}

if (-not $Distro) {
  Write-Host ""
  Write-Host "Available WSL distros:"
  for ($i = 0; $i -lt $distros.Count; $i++) {
    Write-Host ("  [{0}] {1}" -f ($i + 1), $distros[$i])
  }
  Write-Host ""
  do {
    $choice = Read-Host ("Select distro [1-{0}]" -f $distros.Count)
  } while (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $distros.Count)
  $Distro = $distros[[int]$choice - 1]
  Write-Host ("Using: {0}`n" -f $Distro)
}

$distroArg = @('-d', $Distro)

# Translate the Windows path to a WSL path (/mnt/c/...)
$safeHere = $Here -replace '\\','\\\\'
$WslHereRaw = & $wsl.Path @distroArg -- wslpath -a -- $safeHere 2>&1
$WslHere = ($WslHereRaw -join "`n").Trim()
if ($LASTEXITCODE -ne 0 -or -not $WslHere) {
  throw "wslpath failed for '$Here'. Is WSL healthy? Try 'wsl --status'. Output: $WslHereRaw"
}

# ---- Prereq: build tools inside WSL -------------------------------------
# Auto-install any missing tools, then verify. Runs as the WSL user but
# calls sudo for the install, so the user must have passwordless sudo or
# will be prompted once.
$precheckLines = @(
  'set -e'
  'missing=""'
  'for t in debootstrap parted mkfs.vfat mkfs.ext4 losetup chroot openssl; do'
  '  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"'
  'done'
  'if [ -n "$missing" ]; then'
  '  echo "WSL: installing missing tools:$missing"'
  '  sudo apt-get update -qq'
  '  sudo apt-get install -y debootstrap parted dosfstools e2fsprogs openssl'
  'fi'
)
$tmpWin = [System.IO.Path]::GetTempFileName() + '.sh'
[System.IO.File]::WriteAllText($tmpWin, ($precheckLines -join "`n") + "`n", [System.Text.Encoding]::ASCII)
$tmpWsl = (& $wsl.Path @distroArg -- wslpath -a ($tmpWin -replace '\\','/')).Trim()
& $wsl.Path @distroArg -- bash "$tmpWsl"
$precheckExit = $LASTEXITCODE
Remove-Item $tmpWin -ErrorAction SilentlyContinue
if ($precheckExit -ne 0) { throw "WSL prerequisite install failed -- see message above." }

# Hand the password to WSL via WSLENV so we don't interpolate it into a shell
# string (avoids quoting headaches for passwords with special chars).
$env:PASSWORD = $Password
$env:WSLENV   = (@($env:WSLENV, 'PASSWORD') | Where-Object { $_ }) -join ':'

# Strip Windows CR from build.sh, config scripts, and packages.list (safe to repeat).
& $wsl.Path @distroArg -- bash -c "sed -i 's/\r//' '$WslHere/build.sh' '$WslHere/config/firstboot.sh' '$WslHere/config/packages.list'"

& $wsl.Path @distroArg -- bash -lc "cd '$WslHere' && sudo -E ./build.sh"
if ($LASTEXITCODE -ne 0) { throw "build.sh failed inside WSL." }

Write-Host ""
Write-Host ("built:    {0}\build\ubuntu.img" -f $Here)
Write-Host ("user:     ubuntu")
Write-Host ("password: {0}   (override with `$env:PASSWORD='xxx'; .\build.ps1)" -f $Password)
Write-Host ""
Write-Host "Boot it with .\run-vm.ps1"
