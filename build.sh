#!/usr/bin/env bash
# Builds cidata.iso that the autoinstall VM boots alongside the Ubuntu ISO.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/autoinstall"
OUT="$HERE/build"
STAGE="$OUT/cidata-stage"
ISO="$OUT/cidata.iso"
PASSWORD="${PASSWORD:-ubuntu}"

mkdir -p "$OUT"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# ---- Find an ISO-creator -------------------------------------------------
if command -v genisoimage >/dev/null 2>&1; then
  MKISO=(genisoimage)
elif command -v mkisofs >/dev/null 2>&1; then
  MKISO=(mkisofs)
elif command -v xorriso >/dev/null 2>&1; then
  MKISO=(xorriso -as mkisofs)
else
  cat >&2 <<'EOF'
error: need one of genisoimage / mkisofs / xorriso on PATH
  Windows (Git Bash, admin):  choco install cdrtools
  WSL / Ubuntu:               sudo apt install -y genisoimage
  macOS:                      brew install cdrtools
EOF
  exit 1
fi

# ---- Hash the password ---------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  PASSWORD_HASH="$(openssl passwd -6 "$PASSWORD")"
elif command -v python3 >/dev/null 2>&1; then
  PASSWORD_HASH="$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$PASSWORD")"
else
  echo "error: need openssl or python3 to hash the password" >&2
  exit 1
fi

# ---- Stage files ---------------------------------------------------------
cp "$SRC/meta-data" "$STAGE/meta-data"
# awk -v is literal enough for crypt hashes (alphabet: ./0-9A-Za-z — no & or |)
awk -v h="$PASSWORD_HASH" '{ gsub(/__PASSWORD_HASH__/, h); print }' \
  "$SRC/user-data" > "$STAGE/user-data"

# Sanity check: template placeholder must be gone
if grep -q __PASSWORD_HASH__ "$STAGE/user-data"; then
  echo "error: password hash substitution failed" >&2
  exit 1
fi

# ---- Burn ISO ------------------------------------------------------------
"${MKISO[@]}" \
  -output "$ISO" \
  -volid cidata \
  -joliet -rock \
  "$STAGE/user-data" "$STAGE/meta-data"

echo
echo "built:    $ISO"
echo "user:     ubuntu"
echo "password: $PASSWORD   (override with PASSWORD=xxx ./build.sh)"
