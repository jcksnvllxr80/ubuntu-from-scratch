#!/usr/bin/env bash
# Boots build/ubuntu.img in VirtualBox.
#
# Counterpart to _autoinstall/run-vm.sh. Differences:
#   - no Ubuntu ISO is attached (the image is already bootable)
#   - VM firmware is EFI (grub-install --removable lives on the ESP)
#   - the raw image is converted to VDI on the way in
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

VM_NAME="${VM_NAME:-ubuntu-minimal}"
RAW_IMG="$HERE/build/ubuntu.img"
VM_DIR="$HERE/build/vm"
DISK_VDI="$VM_DIR/$VM_NAME.vdi"
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

if [[ ! -f "$RAW_IMG" ]]; then
  echo "error: $RAW_IMG missing — run 'sudo ./build.sh' first" >&2
  exit 1
fi

# ---- Path conversion helper (Git Bash on Windows needs Windows paths) ----
towin() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}

mkdir -p "$VM_DIR"

# ---- Scrub any previous VM with this name --------------------------------
if "${VBOX[@]}" list vms | grep -q "\"$VM_NAME\""; then
  "${VBOX[@]}" controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
  "${VBOX[@]}" unregistervm "$VM_NAME" --delete >/dev/null 2>&1 || true
fi
rm -f "$DISK_VDI"

# ---- Convert raw -> VDI -------------------------------------------------
"${VBOX[@]}" convertfromraw "$(towin "$RAW_IMG")" "$(towin "$DISK_VDI")" --format VDI

# ---- Create VM (EFI, no optical drive) ----------------------------------
"${VBOX[@]}" createvm --name "$VM_NAME" --ostype Ubuntu_64 --register \
  --basefolder "$(towin "$VM_DIR")"

"${VBOX[@]}" modifyvm "$VM_NAME" \
  --memory "$MEMORY_MB" --cpus "$CPUS" \
  --nic1 nat \
  --natpf1 "ssh,tcp,,$SSH_PORT,,22" \
  --boot1 disk --boot2 none --boot3 none --boot4 none \
  --firmware efi \
  --graphicscontroller vmsvga \
  --vram 16

"${VBOX[@]}" storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 1
"${VBOX[@]}" storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
  --type hdd --medium "$(towin "$DISK_VDI")"

# ---- Boot it ------------------------------------------------------------
"${VBOX[@]}" startvm "$VM_NAME"

cat <<EOF

VM '$VM_NAME' is booting straight from the debootstrap-built disk.
No installer runs — the rootfs was assembled at build time. firstboot.service
fires on the first boot and drops /etc/firstboot-complete when done.

SSH in (after ~30-60s):
  ssh -p $SSH_PORT ubuntu@localhost
  # password: ubuntu   (or whatever PASSWORD= you built with)

  sudo systemctl status firstboot.service    # expect: inactive/disabled, ran OK
  sudo cat /etc/firstboot-complete           # marker file
  sudo cat /var/log/firstboot.log            # firstboot output
EOF
