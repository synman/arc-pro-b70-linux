#!/usr/bin/env bash
# Apply the tuning in b70.conf to the card and read every value back.
#
#   sudo ./scripts/b70-tune.sh [/etc/b70/b70.conf]
#
# Needs the patched xe loaded by load-xe.sh (it checks /run/b70-xe.sha). Idempotent: a value already in
# place is rewritten to itself, and the VRAM rate is written only when it differs, since that write needs
# every GPU user stopped. Every value resets on reboot or driver rebind. Ends TUNE-OK or TUNE-FAIL in $LOG.
set -u
CONF=${1:-/etc/b70/b70.conf}
# shellcheck source=/dev/null
. "$CONF" || { echo "cannot read $CONF"; exit 1; }
D=$PCI
DEV=/sys/bus/pci/devices/$D
F=$DEV/tile0/gt0/freq0
OC=$DEV/tile0/gt0/oc
WEDGE="xe $D.*(device wedged|GuC mmio request .*no reply|Force wake domain .* failed to ack)"
say() { echo "$(date -Is) b70-tune: $*" | tee -a "$LOG"; }
fail() { say "$*"; say TUNE-FAIL; exit 1; }
w() { echo "$2" > "$1" || fail "write $2 to $1 failed"; }
# Pick the hwmon by name: the patched driver adds a second one, xe_oc, which has no fan or power files.
H=$(for h in $DEV/hwmon/hwmon*; do [ "$(cat "$h/name")" = xe ] && echo "$h"; done)
holders() {
  local c r; c=$(readlink -f /dev/dri/by-path/pci-$D-card); r=$(readlink -f /dev/dri/by-path/pci-$D-render)
  for p in /proc/[0-9]*; do
    for f in "$p"/fd/*; do
      case "$(readlink "$f" 2>/dev/null)" in "$c"|"$r") echo "${p#/proc/} $(cat "$p"/comm 2>/dev/null)"; break ;; esac
    done
  done
}

[ "$(cat /run/b70-xe.sha 2>/dev/null)" = "$MODULE_SHA" ] || fail "patched xe not loaded; run load-xe.sh first"
journalctl -k -b --no-pager -o cat | grep -qE "$WEDGE" && fail "card wedged this boot; reboot the host"
[ -n "$H" ] || fail "no hwmon named xe under $DEV"

# Clocks, VRAM D3cold, runtime PM.
if [ -n "$CLOCK_PIN_MHZ" ]; then w $F/max_freq "$CLOCK_PIN_MHZ"; w $F/min_freq "$CLOCK_PIN_MHZ"; fi
[ -n "$D3COLD_THRESHOLD" ] && w $DEV/vram_d3cold_threshold "$D3COLD_THRESHOLD"
for b in $RPM_DEVICES; do w /sys/bus/pci/devices/$b/power/control on; done

# Fan table. pwm1_enable=1 alone loads the firmware's table, so every point is rewritten after it.
if [ -n "$FAN_TABLE" ]; then
  set -- $FAN_TABLE
  [ $# = 10 ] || fail "FAN_TABLE needs 10 points, has $#"
  w "$H/pwm1_enable" 1
  i=1; for pt in "$@"; do w "$H/pwm1_auto_point${i}_temp" $(( ${pt%%:*} * 1000 )); w "$H/pwm1_auto_point${i}_pwm" "${pt##*:}"; i=$((i+1)); done
fi

# VRAM rate. A write under GPU load wedged the card once, so every user is stopped first.
# A read before anything is staged this boot fails with EPROTO, which the kernel logs as -71: expected.
if [ -n "$MEM_MBPS" ]; then
  CUR=$(cat "$OC/mem_speed" 2>&1)
  if [ "$CUR" != "$MEM_MBPS" ]; then
    say "mem_speed reads [$CUR], writing $MEM_MBPS with GPU users stopped"
    MARK=$(date +%s)
    for c in $STOP_CONTAINERS; do docker stop -t 60 "$c" >/dev/null; done
    for s in $STOP_SERVICES; do systemctl stop "$s"; done
    for n in $KILL_COMMS; do for pid in $(holders | awk -v n="$n" '$2==n{print $1}'); do kill -TERM "$pid"; done; done
    sleep 3
    restart() {
      for s in $STOP_SERVICES; do systemctl start "$s"; done
      for c in $STOP_CONTAINERS; do docker start "$c" >/dev/null; done
    }
    LEFT=$(holders)
    [ -z "$LEFT" ] || { restart; fail "unexpected GPU holders: $LEFT"; }
    OUT=$( { echo "$MEM_MBPS" > "$OC/mem_speed"; } 2>&1 ); RC=$?
    say "write rc=$RC err=[$OUT] $(journalctl -k --since "@$MARK" --no-pager -o cat | grep 'oc: mem_speed' | tail -1)"
    sleep 60   # on the reference card the 22000 failure showed 31 s after the commit
    [ "$(journalctl -k --since "@$MARK" --no-pager -o cat | grep -cE "$WEDGE")" = 0 ] \
      || fail "card wedged after the write; GPU users left stopped; reboot the host, never reload xe"
    restart
    if [ -n "$HEALTH_CONTAINER" ]; then
      for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$HEALTH_CONTAINER")" = healthy ] && break; sleep 5; done
    fi
    [ $RC = 0 ] || fail "mem_speed write failed"
  fi
fi

T=""; for i in $(seq 1 10); do T="$T$(( $(cat $H/pwm1_auto_point${i}_temp) / 1000 )):$(cat $H/pwm1_auto_point${i}_pwm) "; done
PM=""; for b in $RPM_DEVICES; do PM="$PM$(cat /sys/bus/pci/devices/$b/power/control),"; done
say "readback min=$(cat $F/min_freq) max=$(cat $F/max_freq) d3cold=$(cat $DEV/vram_d3cold_threshold) pm=$PM fan_enable=$(cat $H/pwm1_enable) table=[$T] mem=$(cat $OC/mem_speed 2>&1)"
if [ -n "$COHERENCE_CMD" ]; then
  C=$(bash -c "$COHERENCE_CMD" 2>&1 | head -1)
  case "$C" in *"$COHERENCE_EXPECT"*) say "coherence $C" ;; *) fail "coherence mismatch: $C" ;; esac
fi
say TUNE-OK
