#!/usr/bin/env bash
# Sign the built module with your enrolled Machine Owner Key, for Secure Boot with module signature enforcement.
#
#   sudo ./build/sign-xe.sh <xe.ko> <mok.key> <mok.der-or-pem>
#
# Debian's DKMS key is the usual choice: /var/lib/dkms/mok.key and /var/lib/dkms/mok.pub, enrolled with
# `mokutil --import`. The key is only passed by path to the kernel's sign-file; it is never read here.
set -euo pipefail
KO=$1; KEY=$2; CERT=$3
SIGNFILE=$(ls /usr/lib/linux-kbuild-*/scripts/sign-file 2>/dev/null | sort -V | tail -1)
[ -x "$SIGNFILE" ] || { echo "sign-file not found; install linux-kbuild for your kernel"; exit 1; }
sha256sum "$KO" | sed 's/  / unsigned  /'
"$SIGNFILE" sha256 "$KEY" "$CERT" "$KO"
echo "signer: $(modinfo -F signer "$KO")  hash: $(modinfo -F sig_hashalgo "$KO")  vermagic: $(modinfo -F vermagic "$KO")"
sha256sum "$KO" | sed 's/  / signed  /'
echo "Put the signed sha256 in b70.conf as MODULE_SHA."
