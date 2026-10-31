#!/usr/bin/env bash
# Build a patched xe.ko for the RUNNING Debian kernel, inside a throwaway container.
#
#   sudo ./build/build-xe.sh [workdir]        default workdir: ./work
#
# What goes in, in order:
#   1. the Debian linux-source package whose version matches the running kernel (from `uname -v`)
#   2. exzile/intel-arc-pro-fan-control at a pinned commit: Intel's fan-control series 168027 as adapted
#      there, and its xe_gt_oc.c / xe_gt_oc.h (VF curve, mem_speed, temp_limit)
#   3. this repo's patches/*.patch, in order
# Output: <workdir>/out/xe.ko, built against the running kernel's own config and Module.symvers.
# The module is unsigned. With Secure Boot on, sign it with ./build/sign-xe.sh before loading.
# Nothing outside <workdir> is written on the host, and nothing is installed.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
WORK=$(mkdir -p "${1:-$REPO/work}" && cd "${1:-$REPO/work}" && pwd -P)
EXZ_COMMIT=${EXZ_COMMIT:-0fc18ceefbc5b6ff341926745f95f7c47058a741}
IMAGE=${IMAGE:-debian:trixie-backports}

KREL=$(uname -r)
DEBVER=$(uname -v | sed -n 's/.*Debian \([^ ]*\) .*/\1/p')
SERIES=$(echo "$KREL" | cut -d. -f1,2)
HDR=/usr/src/linux-headers-$KREL
[ -n "$DEBVER" ] || { echo "cannot read the Debian kernel version from: $(uname -v)"; exit 1; }
for f in .config Module.symvers include/generated/utsrelease.h include/config/kernel.release; do
  [ -f "$HDR/$f" ] || { echo "missing $HDR/$f; install linux-headers-$KREL"; exit 1; }
done
echo "kernel $KREL, Debian $DEBVER, source package linux-source-$SERIES=$DEBVER"

mkdir -p "$WORK/hdr"
cp "$HDR/.config" "$WORK/hdr/config"
cp "$HDR/Module.symvers" "$HDR/include/generated/utsrelease.h" "$HDR/include/config/kernel.release" "$WORK/hdr/"
rm -rf "$WORK/patches" && cp -r "$REPO/patches" "$WORK/patches"
cp "$HERE/in-container.sh" "$WORK/in-container.sh"

docker run --rm -v "$WORK:/work" -e KREL="$KREL" -e DEBVER="$DEBVER" -e SERIES="$SERIES" -e EXZ_COMMIT="$EXZ_COMMIT" \
  "$IMAGE" bash /work/in-container.sh
sha256sum "$WORK/out/xe.ko"
