# run-vm.ps1 -- Windows-native equivalent of run-vm.sh.
# Boots build\ubuntu.img (raw, produced by build.ps1 -> WSL -> build.sh) in
# VirtualBox. Converts raw -> VDI on the way in and enables EFI firmware.
#
# Counterpart to _autoinstall/run-vm.ps1. Differences:
#   - no UBUNTU_ISO parameter (the image is already bootable)
#   - --firmware efi instead of bios
#   - no cidata ISO attached

[CmdletBinding()]
param(
  [string]$VmName   = $(if ($env:VM_NAME)   { $env:VM_NAME }         else { 'ubuntu-minimal' }),
  [int]   $MemoryMb = $(if ($env:MEMORY_MB) { [int]$env:MEMORY_MB }  else { 4096 }),
  [int]   $Cpus     = $(if ($env:CPUS)      { [int]$env:CPUS }       else { 2 }),
  [int]   $SshPort  = $(if ($env:SSH_PORT)  { [int]$env:SSH_PORT }   else { 2222 })
)

$ErrorActionPreference = 'Stop'

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RawImg  = Join-Path $Here 'build\ubuntu.img'
$VmDir   = Join-Path $Here 'build\vm'
$DiskVdi = Join-Path $VmDir ("$VmName.vdi")

# ---- Locate VBoxManage.exe ----------------------------------------------
$cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
if ($cmd) {
  $VBox = $cmd.Path
} elseif (Test-Path 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe') {
  $VBox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
} else {
  throw 'VBoxManage.exe not found -- install VirtualBox: https://www.virtualbox.org/'
}

if (-not (Test-Path $RawImg)) {
  throw "Missing $RawImg -- run .\build.ps1 first (requires WSL)."
}

New-Item -ItemType Directory -Force -Path $VmDir | Out-Null

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
if (Test-Path $DiskVdi) { Remove-Item $DiskVdi -Force }

# ---- Convert raw -> VDI -------------------------------------------------
Invoke-VBox convertfromraw $RawImg $DiskVdi --format VDI

# ---- Create VM ----------------------------------------------------------
Invoke-VBox createvm --name $VmName --ostype Ubuntu_64 --register --basefolder $VmDir

Invoke-VBox modifyvm $VmName `
  --memory $MemoryMb --cpus $Cpus `
  --nic1 nat `
  --natpf1 "ssh,tcp,,$SshPort,,22" `
  --boot1 disk --boot2 none --boot3 none --boot4 none `
  --firmware efi `
  --graphicscontroller vmsvga `
  --vram 16

Invoke-VBox storagectl   $VmName --name SATA --add sata --controller IntelAhci --portcount 1
Invoke-VBox storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $DiskVdi

Invoke-VBox startvm $VmName

Write-Host ""
Write-Host "VM '$VmName' is booting straight from the debootstrap-built disk."
Write-Host ""
Write-Host "SSH in (after ~30-60s):"
Write-Host "  ssh -p $SshPort ubuntu@localhost"
Write-Host "  sudo systemctl status firstboot.service"
Write-Host "  sudo cat /etc/firstboot-complete"
Write-Host "  sudo cat /var/log/firstboot.log"
