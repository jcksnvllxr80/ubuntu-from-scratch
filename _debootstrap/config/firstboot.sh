#!/bin/bash
# Runs exactly once on the first real boot of the built image.
# Counterpart to the firstboot script embedded in the autoinstall user-data.
set -euo pipefail
LOG=/var/log/firstboot.log
exec > >(tee -a "$LOG") 2>&1

echo "[firstboot] starting $(date -Iseconds)"
echo "[firstboot] hostname=$(hostname)  kernel=$(uname -r)"

# Prove we ran by dropping a marker the service can check.
echo "firstboot completed at $(date -Iseconds)" > /etc/firstboot-complete

# Generate a fresh machine-id (debootstrap left it empty so each cloned
# image gets its own identity on first boot).
if [[ ! -s /etc/machine-id ]]; then
  systemd-machine-id-setup
fi

# Regenerate SSH host keys so every cloned image has unique fingerprints.
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server

# ---- DESKTOP-ONLY FIRSTBOOT STEPS ---------------------------
# If you add a desktop, you may want to enable gdm3 here:
# systemctl enable gdm3
# ---- END DESKTOP-ONLY --------------------------------------

echo "[firstboot] done $(date -Iseconds)"
systemctl disable firstboot.service
