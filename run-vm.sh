#!/usr/bin/env bash
# Creates a VirtualBox VM, attaches the Ubuntu ISO + cidata ISO, boots it.
# Run ./build.sh first to produce build/cidata.iso.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

VM_NAME="${VM_NAME:-ubuntu-minimal}"
UBUNTU_ISO="${UBUNTU_ISO:-}"
CIDATA_ISO="$HERE/build/cidata.iso"
VM_DIR="$HERE/build/vm"
DISK_SIZE_MB="${DISK_SIZE_MB:-20480}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPUS="${CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"

# ---- Locate VBoxManage (Windows-friendly) --------------------------------
if command -v VBoxManage >/dev/null 2>&1; then
  VBOX=(VBoxManage)
elif [[ -x "/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" ]]; then
  VBOX=("/c/Program Files/Oracle/VirtualBox/VBoxManage.exe")
else
  echo "error: VBoxManage not found — install VirtualBox first" >&2
  exit 1
fi

# ---- Preconditions -------------------------------------------------------
if [[ -z "$UBUNTU_ISO" || ! -f "$UBUNTU_ISO" ]]; then
  cat >&2 <<EOF
error: set UBUNTU_ISO to the path of the Ubuntu live-server ISO
  e.g. UBUNTU_ISO=~/Downloads/ubuntu-26.04-live-server-amd64.iso ./run-vm.sh
  download: https://releases.ubuntu.com/26.04/
EOF
  exit 1
fi

if [[ ! -f "$CIDATA_ISO" ]]; then
  echo "error: $CIDATA_ISO missing — run ./build.sh first" >&2
  exit 1
fi

# ---- Path conversion helper (Git Bash on Windows needs Windows paths) ----
towin() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}

mkdir -p "$VM_DIR"
DISK_PATH="$VM_DIR/$VM_NAME.vdi"

# ---- Scrub any previous VM with this name --------------------------------
if "${VBOX[@]}" list vms | grep -q "\"$VM_NAME\""; then
  "${VBOX[@]}" controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
  "${VBOX[@]}" unregistervm "$VM_NAME" --delete >/dev/null 2>&1 || true
fi
rm -f "$DISK_PATH"

# ---- Create VM -----------------------------------------------------------
"${VBOX[@]}" createvm --name "$VM_NAME" --ostype Ubuntu_64 --register \
  --basefolder "$(towin "$VM_DIR")"

"${VBOX[@]}" modifyvm "$VM_NAME" \
  --memory "$MEMORY_MB" --cpus "$CPUS" \
  --nic1 nat \
  --natpf1 "ssh,tcp,,$SSH_PORT,,22" \
  --boot1 dvd --boot2 disk --boot3 none --boot4 none \
  --firmware bios \
  --graphicscontroller vmsvga \
  --vram 16

"${VBOX[@]}" createmedium disk \
  --filename "$(towin "$DISK_PATH")" \
  --size "$DISK_SIZE_MB" --format VDI

"${VBOX[@]}" storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci
"${VBOX[@]}" storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
  --type hdd --medium "$(towin "$DISK_PATH")"

"${VBOX[@]}" storagectl "$VM_NAME" --name IDE --add ide
"${VBOX[@]}" storageattach "$VM_NAME" --storagectl IDE --port 0 --device 0 \
  --type dvddrive --medium "$(towin "$UBUNTU_ISO")"
"${VBOX[@]}" storageattach "$VM_NAME" --storagectl IDE --port 1 --device 0 \
  --type dvddrive --medium "$(towin "$CIDATA_ISO")"

# ---- Boot it -------------------------------------------------------------
"${VBOX[@]}" startvm "$VM_NAME"

cat <<EOF

VM '$VM_NAME' is booting.

At the GRUB menu:     choose "Try or Install Ubuntu Server" (default).
If prompted:          press Enter to confirm autoinstall.
Install time:         ~10-20 min (downloads packages).

After the VM reboots on its own, firstboot runs automatically.
SSH in to verify:
  ssh -p $SSH_PORT ubuntu@localhost
  # password: ubuntu   (or whatever PASSWORD= you built with)

  sudo systemctl status firstboot.service    # expect: inactive/disabled, ran OK
  sudo cat /etc/firstboot-complete           # marker file
  sudo cat /var/log/firstboot.log            # firstboot output
EOF
