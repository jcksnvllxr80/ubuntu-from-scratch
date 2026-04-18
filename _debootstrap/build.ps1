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

$distroArg = @()
if ($Distro) { $distroArg = @('-d', $Distro) }

# Translate the Windows path to a WSL path (/mnt/c/...)
$WslHere = (& $wsl.Path @distroArg -- wslpath -a "$Here").Trim()
if ($LASTEXITCODE -ne 0 -or -not $WslHere) {
  throw "wslpath failed for '$Here'. Is WSL healthy? Try 'wsl --status'."
}

# ---- Prereq: build tools inside WSL -------------------------------------
# Check only -- don't install. If anything is missing, tell the user how.
$precheck = @'
set -e
missing=""
for t in debootstrap parted mkfs.vfat mkfs.ext4 losetup chroot openssl; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  echo "error: missing tools inside WSL:$missing" >&2
  echo "install once with:" >&2
  echo "  sudo apt install -y debootstrap parted dosfstools openssl" >&2
  exit 2
fi
'@

& $wsl.Path @distroArg -- bash -lc $precheck
if ($LASTEXITCODE -ne 0) { throw "WSL prerequisite check failed -- see message above." }

# Hand the password to WSL via WSLENV so we don't interpolate it into a shell
# string (avoids quoting headaches for passwords with special chars).
$env:PASSWORD = $Password
$env:WSLENV   = (@($env:WSLENV, 'PASSWORD') | Where-Object { $_ }) -join ':'

& $wsl.Path @distroArg -- bash -lc "cd '$WslHere' && sudo -E ./build.sh"
if ($LASTEXITCODE -ne 0) { throw "build.sh failed inside WSL." }

Write-Host ""
Write-Host ("built:    {0}\build\ubuntu.img" -f $Here)
Write-Host ("user:     ubuntu")
Write-Host ("password: {0}   (override with `$env:PASSWORD='xxx'; .\build.ps1)" -f $Password)
Write-Host ""
Write-Host "Boot it with .\run-vm.ps1"
