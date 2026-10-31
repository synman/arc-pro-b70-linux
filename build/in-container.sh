#!/usr/bin/env bash
# Runs inside the build container started by build-xe.sh. /work is the host workdir.
set -euo pipefail
exec > >(tee /work/build.log) 2>&1
step() { echo; echo "==> $(date -Is) $*"; }

step "1 packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq -t trixie-backports build-essential flex bison libssl-dev libelf-dev libdw-dev dwarves \
  bc zstd python3 patch kmod git ca-certificates xz-utils "linux-source-$SERIES=$DEBVER" >/dev/null
gcc --version | head -1

step "2 exzile at $EXZ_COMMIT"
git clone -q https://github.com/exzile/intel-arc-pro-fan-control.git /tmp/exz
git -C /tmp/exz checkout -q "$EXZ_COMMIT"
FANPATCH=/tmp/exz/patch/xe-fan-control-168027-cachyos-7.1.2.patch

step "3 source"
mkdir -p /tmp/k && tar -xf "/usr/src/linux-source-$SERIES.tar.xz" -C /tmp/k
SRC=/tmp/k/linux-source-$SERIES; XE=$SRC/drivers/gpu/drm/xe
grep -E "^(VERSION|PATCHLEVEL|SUBLEVEL) =" "$SRC/Makefile" | tr '\n' ' '; echo

step "4 fan patch (dry run first; a reject stops the build)"
( cd "$SRC" && patch -p1 --fuzz=5 --dry-run -s -i "$FANPATCH" && patch -p1 --fuzz=5 -s -i "$FANPATCH" )

step "5 xe_gt_oc files and their hooks in the Makefile and xe_gt.c"
cp /tmp/exz/kernel/xe_gt_oc.c /tmp/exz/kernel/xe_gt_oc.h "$XE/"
python3 - "$XE" <<'PY'
import sys
XE = sys.argv[1]
mk = XE + "/Makefile"; lines = open(mk).read().split("\n"); out = []; added = 0
for l in lines:
    out.append(l)
    if "xe_gt_freq.o" in l and not added:
        out.append(l[:len(l) - len(l.lstrip())] + "xe_gt_oc.o \\"); added = 1
if not added: sys.exit("Makefile anchor xe_gt_freq.o not found")
open(mk, "w").write("\n".join(out))
gt = XE + "/xe_gt.c"; s = open(gt).read()
inc = '#include "xe_gt_freq.h"\n'
if inc not in s: sys.exit("xe_gt.c include anchor not found")
s = s.replace(inc, inc + '#include "xe_gt_oc.h"\n', 1)
anchor = "\terr = xe_gt_freq_init(gt);\n\tif (err)\n\t\treturn err;\n"
if anchor not in s: sys.exit("xe_gt.c init anchor not found")
s = s.replace(anchor, anchor + "\n\terr = xe_gt_oc_init(gt);\n\tif (err)\n\t\treturn err;\n", 1)
open(gt, "w").write(s)
PY

step "6 this repo's patches"
for p in /work/patches/*.patch; do
  echo "applying $(basename "$p")"
  ( cd "$SRC" && patch -p1 --dry-run -s -i "$p" && patch -p1 -s -i "$p" )
done

step "7 configure against the running kernel"
cp /work/hdr/config "$SRC/.config"
( cd "$SRC" && ./scripts/config --set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS '' \
    && make olddefconfig >/dev/null && make -j"$(nproc)" modules_prepare >/dev/null )
cp /work/hdr/utsrelease.h "$SRC/include/generated/utsrelease.h"
cp /work/hdr/kernel.release "$SRC/include/config/kernel.release"
cp /work/hdr/Module.symvers "$SRC/Module.symvers"

step "8 build xe"
( cd "$SRC" && make -j"$(nproc)" M=drivers/gpu/drm/xe modules )
VM=$(modinfo -F vermagic "$XE/xe.ko" | awk '{print $1}')
[ "$VM" = "$KREL" ] || { echo "vermagic $VM does not match $KREL"; exit 3; }
strings "$XE/xe.ko" > /tmp/xe.strings   # read once: grep -q on a pipe would SIGPIPE strings under pipefail
for s in xe_oc freq1_label pwm1_auto_point1_pwm "oc: mem_speed %u commit"; do
  grep -qF -- "$s" /tmp/xe.strings || { echo "built module lacks '$s'"; exit 4; }
done

step "9 output"
mkdir -p /work/out
cp "$XE/xe.ko" /work/out/xe.ko
strip --strip-debug /work/out/xe.ko
echo BUILD-OK
