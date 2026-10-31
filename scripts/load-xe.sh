#!/usr/bin/env bash
# Swap the loaded stock xe for the signed patched build, with automatic rollback to stock.
#
#   sudo ./scripts/load-xe.sh [/etc/b70/b70.conf]
#
# Ends with exactly one of RELOAD-OK, ROLLED-BACK or ABORTED, in $LOG. Nothing is written to /lib/modules,
# so a reboot always brings stock xe back. Writes /run/b70-xe.sha on success; b70-tune.sh checks it.
#
# Warning: this unbinds and reloads the GPU driver. Every user of the card is stopped first. If any other
# GPU driven by xe is in use (another Arc card), it loses its driver too.
set -u
CONF=${1:-/etc/b70/b70.conf}
# shellcheck source=/dev/null
. "$CONF" || { echo "cannot read $CONF"; exit 1; }
exec >>"$LOG" 2>&1
D=$PCI
RENDER=/dev/dri/by-path/pci-$D-render
CARD=/dev/dri/by-path/pci-$D-card
say() { echo "$(date -Is) load-xe: $*"; }
bar2() { local s e f; read -r s e f < <(sed -n 3p /sys/bus/pci/devices/$D/resource); echo $(( e - s + 1 )); }
bound() { [ "$(basename "$(readlink -f /sys/bus/pci/devices/$D/driver 2>/dev/null)")" = xe ] && [ -e "$RENDER" ]; }
wait_bound() { for _ in $(seq 1 90); do bound && return 0; sleep 1; done; return 1; }
holders() {  # pid and name of every process with the card's device nodes open
  local c r; c=$(readlink -f "$CARD"); r=$(readlink -f "$RENDER")
  for p in /proc/[0-9]*; do
    for f in "$p"/fd/*; do
      case "$(readlink "$f" 2>/dev/null)" in "$c"|"$r") echo "${p#/proc/} $(cat "$p"/comm 2>/dev/null)"; break ;; esac
    done
  done
}
stop_users() {
  for c in $STOP_CONTAINERS; do docker stop -t 60 "$c" >/dev/null && say "$c stopped"; done
  for s in $STOP_SERVICES; do systemctl stop "$s" && say "$s stopped"; done
  for n in $KILL_COMMS; do for pid in $(holders | awk -v n="$n" '$2==n{print $1}'); do kill -TERM "$pid" && say "$n pid $pid ended"; done; done
  sleep 3
}
start_users() {
  for s in $STOP_SERVICES; do systemctl start "$s" && say "$s started" || say "$s start FAILED"; done
  for c in $STOP_CONTAINERS; do docker start "$c" >/dev/null && say "$c started" || say "$c start FAILED"; done
  [ -n "$HEALTH_CONTAINER" ] || return 0
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$HEALTH_CONTAINER" 2>/dev/null)" = healthy ] && { say "$HEALTH_CONTAINER healthy"; return 0; }
    sleep 5
  done
  say "$HEALTH_CONTAINER not healthy after 300 s"
}
stock_back() {
  rmmod xe 2>/dev/null && say "patched xe removed"
  modprobe xe && say "stock xe loaded" || say "modprobe xe FAILED"
  wait_bound && say "stock xe bound" || say "stock xe NOT bound"
}
by_name() { for h in /sys/bus/pci/devices/$D/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] && echo "$h"; done; }

say "=== start"; rm -f /run/b70-xe.sha
# Pre-checks. Nothing has changed yet, so a failure here is ABORTED with nothing to restart.
[ -n "$MODULE_SHA" ] && [ "$(sha256sum "$MODULE" | cut -d' ' -f1)" = "$MODULE_SHA" ] || { say "module sha mismatch"; say ABORTED; exit 1; }
[ "$(modinfo -F signer "$MODULE")" = "$SIGNER" ] || { say "module not signed by $SIGNER"; say ABORTED; exit 1; }
[ "$(modinfo -F vermagic "$MODULE" | awk '{print $1}')" = "$(uname -r)" ] || { say "vermagic mismatch (kernel updated? rebuild)"; say ABORTED; exit 1; }
bound || { say "xe not bound to $D"; say ABORTED; exit 1; }
# A wedged card hung the whole host during this teardown once. Reboot to recover instead.
if journalctl -k -b --no-pager -o cat | grep -qE "xe $D.*(device wedged|GuC mmio request .*no reply|Force wake domain .* failed to ack)"; then
  say "card is wedged this boot; reload refused, reboot the host"; say ABORTED; exit 1
fi
BAR_BEFORE=$(bar2); say "BAR2 $BAR_BEFORE, rollback path $(modprobe -n -v --show-depends xe | grep '/xe/xe.ko')"
MARK=$(date +%s)

stop_users
LEFT=$(holders)
if [ -n "$LEFT" ]; then say "unexpected holders: $LEFT"; start_users; say ABORTED; exit 1; fi
# The refs left after the fds close belong to components bound to the device; unbinding tears them down.
if ! echo "$D" > /sys/bus/pci/drivers/xe/unbind; then say "unbind failed"; start_users; say ABORTED; exit 1; fi
for _ in $(seq 1 30); do [ "$(cat /sys/module/xe/refcnt)" = 0 ] && break; sleep 1; done
if ! rmmod xe; then
  say "rmmod xe failed; rebinding stock"
  echo "$D" > /sys/bus/pci/drivers/xe/bind; wait_bound && say "stock xe rebound" || say "stock xe NOT rebound"
  start_users; say ABORTED; exit 1
fi
if ! insmod "$MODULE"; then say "insmod failed"; stock_back; start_users; say ROLLED-BACK; exit 1; fi
say "patched xe inserted"

FAIL=""
wait_bound || FAIL="$FAIL not-bound"
HW=$(by_name xe); OCH=$(by_name xe_oc)
[ -n "$HW" ] && [ -e "$HW/pwm1_enable" ] || FAIL="$FAIL no-pwm1"
[ -d /sys/bus/pci/devices/$D/tile0/gt0/oc ] || FAIL="$FAIL no-oc-dir"
[ -n "$OCH" ] && [ "$(cat "$OCH/freq1_label" 2>&1)" = mclk ] || FAIL="$FAIL no-xe_oc"
[ "$(bar2)" = "$BAR_BEFORE" ] || FAIL="$FAIL bar-changed"
# Known and harmless: the missing fan_control late-bind firmware blob (stock xe logs it too), and the
# probe's mem_speed seed failing with -71 when nothing has been staged since boot.
ERR=$(journalctl -k --since "@$MARK" --no-pager -o cat | grep -iE "xe $D.*(error|fail|wedged|timed out)|guc.*(fail|error)" \
      | grep -v "failed to load xe/fan_control_.*\.bin" | grep -v "PCODE Mailbox failed: -71 " | head -10)
[ -z "$ERR" ] || FAIL="$FAIL dmesg"
if [ -n "$FAIL" ]; then
  say "verify failed:$FAIL"; [ -n "$ERR" ] && echo "$ERR"
  stock_back; start_users; say ROLLED-BACK; exit 1
fi
say "xe_oc freq1_input=$(cat "$OCH/freq1_input" 2>&1) taint=$(cat /proc/sys/kernel/tainted)"
start_users
echo "$MODULE_SHA" > /run/b70-xe.sha
say RELOAD-OK
