#!/usr/bin/env bash
# Builds build/ubuntu.img: a raw bootable disk image assembled directly from
# the Ubuntu archive via debootstrap. No installer ISO needed.
#
# Counterpart to _autoinstall/build.sh (which builds a cidata.iso that drives
# the Ubuntu live-server installer). This script skips the installer entirely
# and lays down a working rootfs in one pass.
#
# Requires: Linux host (NOT macOS, NOT native Windows). Root.
#   sudo apt install debootstrap parted dosfstools
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/config"
OUT="$HERE/build"
IMG="$OUT/ubuntu.img"

SUITE="${SUITE:-resolute}"                     # Ubuntu codename (26.04 LTS = Resolute Raccoon)
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
SIZE_MB="${SIZE_MB:-8192}"
HOSTNAME_="${HOSTNAME_:-ubuntu-minimal}"
USERNAME="${USERNAME:-ubuntu}"
PASSWORD="${PASSWORD:-ubuntu}"

# ---- Preflight -----------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: build.sh requires a Linux host (debootstrap + chroot need it)." >&2
  echo "       On Windows, run build.ps1 — it shells out to WSL."              >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "error: run as root (sudo ./build.sh) — loop-mount + chroot need root." >&2
  exit 1
fi
for tool in debootstrap parted mkfs.vfat mkfs.ext4 losetup chroot openssl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: missing '$tool'. On Ubuntu: apt install debootstrap parted dosfstools openssl" >&2
    exit 1
  }
done

mkdir -p "$OUT"
rm -f "$IMG"

# ---- Parse the packages list --------------------------------------------
# Space-separated so we can pass directly to apt-get inside the chroot.
# Packages with complex postinst scripts (grub-efi-amd64, shim-signed,
# linux-generic) fail during debootstrap's second stage before /proc /sys
# /dev are available, so ALL packages are installed inside the chroot.
PACKAGES="$(grep -vE '^\s*(#|$)' "$CFG/packages.list" | paste -sd' ' -)"
if [[ -z "$PACKAGES" ]]; then
  echo "error: no packages in $CFG/packages.list" >&2
  exit 1
fi

# ---- Create the sparse raw image and partition it -----------------------
truncate -s "${SIZE_MB}M" "$IMG"
parted -s "$IMG" \
  mklabel gpt \
  mkpart ESP  fat32 1MiB 513MiB \
  set 1 esp on \
  mkpart root ext4  513MiB 100%

# ---- Loop-mount with partition scanning ---------------------------------
LOOP=$(losetup --find --show --partscan "$IMG")
MNT="$(mktemp -d)"
cleanup() {
  set +e
  umount -R "$MNT" 2>/dev/null
  rmdir  "$MNT"    2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkfs.vfat -F32 -n ESP  "${LOOP}p1" >/dev/null
mkfs.ext4 -L root -F   "${LOOP}p2" >/dev/null

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p1" "$MNT/boot/efi"

# ---- Bootstrap a minimal rootfs -----------------------------------------
# No --include: packages with complex postinst (grub, shim, kernel) are
# installed inside the chroot below, after /proc /sys /dev are mounted.
debootstrap --arch="$ARCH" --variant=minbase \
  "$SUITE" "$MNT" "$MIRROR"

# ---- Bind pseudo-fs so the chroot can build initramfs + install grub ----
for d in dev dev/pts proc sys run; do
  mount --rbind "/$d" "$MNT/$d"
  mount --make-rslave "$MNT/$d"
done

# ---- System config (mirrors autoinstall user-data) ----------------------
echo "$HOSTNAME_" > "$MNT/etc/hostname"

cat > "$MNT/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  $HOSTNAME_
EOF

cat > "$MNT/etc/fstab" <<EOF
LABEL=root  /          ext4  defaults     0 1
LABEL=ESP   /boot/efi  vfat  umask=0077   0 1
EOF

install -D -m 0600 "$CFG/netplan.yaml"       "$MNT/etc/netplan/01-netcfg.yaml"
install -D -m 0755 "$CFG/firstboot.sh"       "$MNT/usr/local/sbin/firstboot.sh"
install -D -m 0644 "$CFG/firstboot.service"  "$MNT/etc/systemd/system/firstboot.service"

# apt sources (debootstrap --variant=minbase writes a minimal sources.list)
cat > "$MNT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR $SUITE-updates main restricted universe multiverse
deb $MIRROR $SUITE-security main restricted universe multiverse
EOF

# Explicitly allow SSH password auth (some Ubuntu drop-ins disable it by default).
install -d -m 0755 "$MNT/etc/ssh/sshd_config.d"
echo 'PasswordAuthentication yes' > "$MNT/etc/ssh/sshd_config.d/10-local.conf"

# DNS: point /etc/resolv.conf at systemd-resolved's stub (debootstrap copies
# the host's resolv.conf in, which is meaningless inside the guest).
ln -sf /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

# Wipe machine-id so firstboot regenerates it per-clone.
: > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"

# Pre-hash the password (SHA-512 crypt) so we never pass plaintext through
# a shell heredoc. Special characters in $PASSWORD would otherwise break it.
PASSWORD_HASH="$(openssl passwd -6 "$PASSWORD")"
printf '%s:%s\n' "$USERNAME" "$PASSWORD_HASH" > "$MNT/tmp/.pw"
chmod 600 "$MNT/tmp/.pw"

# ---- Finish inside the chroot ------------------------------------------
chroot "$MNT" /bin/bash -eux <<CHROOT
export DEBIAN_FRONTEND=noninteractive

# ---- Install all target packages now that /proc /sys /dev are ready -----
apt-get update
apt-get install -y --no-install-recommends $PACKAGES

# user + sudo (password applied via chpasswd -e, which accepts pre-hashed)
useradd -m -s /bin/bash -G sudo "$USERNAME"
chpasswd -e < /tmp/.pw
rm -f /tmp/.pw
passwd -l root

# services
systemctl enable ssh
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable firstboot.service

# purge bloat (mirror of autoinstall late-commands)
apt-get purge -y snapd ubuntu-advantage-tools 2>/dev/null || true
apt-get autoremove -y
apt-get clean

# bootloader on the ESP. --removable writes /EFI/BOOT/BOOTX64.EFI so it
# boots on any EFI firmware without needing NVRAM entries (important for VMs).
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --removable --no-nvram
update-grub
CHROOT

# ---- Build standalone GRUB EFI binary with embedded search config ------
# grub-install embedded device hints from the build environment (loop devices)
# that don't exist in the VM. Replace its EFI binary with a standalone one
# that searches by filesystem label at boot time — works on any hardware.
cat > "$MNT/tmp/grub-embed.cfg" <<'EMBEDCFG'
search.fs_label root root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EMBEDCFG

chroot "$MNT" grub-mkstandalone \
  --format=x86_64-efi \
  --output=/boot/efi/EFI/BOOT/BOOTX64.EFI \
  --locales="" \
  --fonts="" \
  "boot/grub/grub.cfg=/tmp/grub-embed.cfg"

rm -f "$MNT/tmp/grub-embed.cfg"

# ---- Unmount cleanly ---------------------------------------------------
umount -R "$MNT"
losetup -d "$LOOP"
rmdir "$MNT"
trap - EXIT

echo
echo "built:    $IMG"
echo "user:     $USERNAME"
echo "password: $PASSWORD   (override with PASSWORD=xxx sudo ./build.sh)"
echo
echo "Boot it with ./run-vm.sh (converts raw -> VDI and creates an EFI VM)."
