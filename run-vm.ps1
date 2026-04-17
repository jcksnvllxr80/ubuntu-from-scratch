# run-vm.ps1 -- Windows-native equivalent of run-vm.sh.
# Creates a VirtualBox VM, attaches the Ubuntu live-server ISO + the
# build/cidata.iso produced by build.ps1, and starts it.
#
# Usage:
#   $env:UBUNTU_ISO='C:\iso\ubuntu-26.04-live-server-amd64.iso'
#   .\run-vm.ps1

[CmdletBinding()]
param(
  [string]$VmName     = $(if ($env:VM_NAME)      { $env:VM_NAME }      else { 'ubuntu-minimal' }),
  [string]$UbuntuIso  = $env:UBUNTU_ISO,
  [int]   $MemoryMb   = $(if ($env:MEMORY_MB)    { [int]$env:MEMORY_MB }    else { 4096 }),
  [int]   $Cpus       = $(if ($env:CPUS)         { [int]$env:CPUS }         else { 2 }),
  [int]   $DiskSizeMb = $(if ($env:DISK_SIZE_MB) { [int]$env:DISK_SIZE_MB } else { 20480 }),
  [int]   $SshPort    = $(if ($env:SSH_PORT)     { [int]$env:SSH_PORT }     else { 2222 })
)

$ErrorActionPreference = 'Stop'

$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$CidataIso = Join-Path $Here 'build\cidata.iso'
$VmDir     = Join-Path $Here 'build\vm'

# ---- Locate VBoxManage.exe ----------------------------------------------
$VBox = $null
$cmd  = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
if ($cmd) {
  $VBox = $cmd.Path
} elseif (Test-Path 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe') {
  $VBox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
} else {
  throw 'VBoxManage.exe not found -- install VirtualBox: https://www.virtualbox.org/'
}

# ---- Preconditions ------------------------------------------------------
if (-not $UbuntuIso -or -not (Test-Path $UbuntuIso)) {
  throw @"
Set UBUNTU_ISO or pass -UbuntuIso pointing at the live-server ISO.
  `$env:UBUNTU_ISO = 'C:\path\ubuntu-26.04-live-server-amd64.iso'; .\run-vm.ps1
  download: https://releases.ubuntu.com/26.04/
"@
}

if (-not (Test-Path $CidataIso)) {
  throw "Missing $CidataIso -- run .\build.ps1 first"
}

New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
$DiskPath = Join-Path $VmDir "$VmName.vdi"

# ---- Helper: invoke VBoxManage and throw on non-zero exit ---------------
function Invoke-VBox {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
  & $VBox @Args
  if ($LASTEXITCODE -ne 0) {
    throw ("VBoxManage failed (exit {0}): {1}" -f $LASTEXITCODE, ($Args -join ' '))
  }
}

# ---- Scrub any previous VM with this name -------------------------------
$existing = & $VBox list vms | Select-String -SimpleMatch "`"$VmName`""
if ($existing) {
  & $VBox controlvm $VmName poweroff 2>$null | Out-Null
  & $VBox unregistervm $VmName --delete 2>$null | Out-Null
}
if (Test-Path $DiskPath) { Remove-Item $DiskPath -Force }

# ---- Create VM ----------------------------------------------------------
Invoke-VBox createvm --name $VmName --ostype Ubuntu_64 --register --basefolder $VmDir

Invoke-VBox modifyvm $VmName `
  --memory $MemoryMb --cpus $Cpus `
  --nic1 nat `
  --natpf1 "ssh,tcp,,$SshPort,,22" `
  --boot1 dvd --boot2 disk --boot3 none --boot4 none `
  --firmware bios `
  --graphicscontroller vmsvga `
  --vram 16

Invoke-VBox createmedium disk --filename $DiskPath --size $DiskSizeMb --format VDI

Invoke-VBox storagectl   $VmName --name SATA --add sata --controller IntelAhci
Invoke-VBox storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $DiskPath

Invoke-VBox storagectl   $VmName --name IDE --add ide
Invoke-VBox storageattach $VmName --storagectl IDE --port 0 --device 0 --type dvddrive --medium $UbuntuIso
Invoke-VBox storageattach $VmName --storagectl IDE --port 1 --device 0 --type dvddrive --medium $CidataIso

Invoke-VBox startvm $VmName

Write-Host ""
Write-Host "VM '$VmName' is booting."
Write-Host ""
Write-Host "  At GRUB:        choose 'Try or Install Ubuntu Server'."
Write-Host "  If prompted:    press Enter to confirm autoinstall."
Write-Host "  Install time:   ~10-20 min (downloads packages)."
Write-Host ""
Write-Host "After it reboots on its own, firstboot runs automatically. SSH in:"
Write-Host "  ssh -p $SshPort ubuntu@localhost"
Write-Host "  sudo systemctl status firstboot.service"
Write-Host "  sudo cat /etc/firstboot-complete"
Write-Host "  sudo cat /var/log/firstboot.log"
