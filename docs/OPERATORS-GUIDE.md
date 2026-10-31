# Operator's guide

Build, sign, load, tune and persist the patched xe, and how to undo each step. Every command runs as root.
Read [FINDINGS.md](FINDINGS.md) first.

## 1. Preflight

```bash
uname -r; uname -v                          # a Debian kernel; uname -v names the package version
lspci -D -nn -d 8086:e223                   # the card's PCI address
readlink /sys/bus/pci/devices/<addr>/driver # must end in xe
ls /dev/dri/by-path/ | grep <addr>          # card and render nodes
mokutil --sb-state; mokutil --list-enrolled | grep -i -A1 subject   # under Secure Boot: your key is enrolled
lsof /dev/dri/by-path/pci-<addr>-render     # everything you must stop before a swap
```

Before you go on:
- Note every container, service and process that holds the card. They go in `STOP_CONTAINERS`, `STOP_SERVICES` and `KILL_COMMS`.
- Check no other device is bound to xe. The swap unbinds xe for everything it drives.

## 2. Build

```bash
./build/build-xe.sh                 # default workdir ./work; log in work/build.log
```

Success ends with `BUILD-OK` and prints the sha256 of `work/out/xe.ko`.
- The fan patch and each repo patch get a dry run first. A reject stops the build, which usually means a different kernel series. Report it, never force it.
- The build checks that the vermagic equals `uname -r`, and that the module contains `xe_oc`, `freq1_label`, the fan points and the commit log line.

## 3. Sign (Secure Boot)

```bash
./build/sign-xe.sh work/out/xe.ko /var/lib/dkms/mok.key /var/lib/dkms/mok.pub
install -D -m 644 work/out/xe.ko /opt/b70/xe.ko
```

Copy the printed signed sha256 into `MODULE_SHA`. `load-xe.sh` loads nothing else.

## 4. Configure

```bash
install -D -m 644 scripts/b70.conf.example /etc/b70/b70.conf
```

Then edit it. Each setting is described in the file.
- Set `PCI`, `MODULE_SHA`, the three "stop" lists, and `LOG`.
- The tuning values ship empty, which means stock. Fill them in one at a time, and measure after each. The reference card's values are in the comments.
- `RPM_DEVICES` is the card plus each bridge above it. Read them with `ls -l /sys/bus/pci/devices/<addr>`: the path shows every parent.

## 5. Load

```bash
./scripts/load-xe.sh
tail -20 /var/log/b70.log
```

The log ends with one of three results:

| Result | Meaning | What to do |
|---|---|---|
| `RELOAD-OK` | The patched xe is bound, the checks passed, the users are restarted, and `/run/b70-xe.sha` is written | Go on to tune |
| `ROLLED-BACK` | `insmod` failed, or the patched module loaded and failed a check | Read the `insmod failed` or `verify failed:` line. Stock xe is back |
| `ABORTED` | A check failed before the patched module was inserted: sha, signer, vermagic, not bound, wedged, a holder left open, unbind or `rmmod` failed. The card stays on stock xe | Read the line before it. Users that were stopped are started again |

The checks:
- the device is bound
- the `xe` hwmon has `pwm1_enable`
- the `oc` dir exists
- the `xe_oc` hwmon reads `mclk`
- BAR2 is unchanged
- no new xe or GuC errors in dmesg, apart from the two expected lines in FINDINGS

Confirm by hand:

```bash
for h in /sys/bus/pci/devices/<addr>/hwmon/hwmon*; do echo "$h $(cat $h/name)"; done   # xe and xe_oc
cat /sys/bus/pci/devices/<addr>/hwmon/hwmon*/freq1_input 2>/dev/null                    # e.g. 2375000000 at stock
```

## 6. Tune

```bash
./scripts/b70-tune.sh                # ends TUNE-OK, with a readback line of every value
```

- A changed `MEM_MBPS` stops every GPU user, writes the rate, and watches the kernel log for 60 s for a wedge. Only then does it restart the users.
- A bad rate can also fail later, under the first real load. On the reference card 22000 failed 31 s after the commit, at the first memtest. So test a new rate before anything depends on it: stop the users, run memtest_vulkan, and only then enable the boot unit.
- If it reports a wedge, the users stay stopped. **Reboot the host. Do not reload xe.**
- Before trusting a new memory rate, run a full-VRAM test such as memtest_vulkan. Also run `tools/b70coh.py` and compare its hash with the stock one.

## 7. Persist across reboots

```bash
install -D -m 755 scripts/load-xe.sh /opt/b70/scripts/load-xe.sh
install -D -m 755 scripts/b70-tune.sh /opt/b70/scripts/b70-tune.sh
install -m 644 systemd/b70-preferred.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now b70-preferred.service
systemctl status b70-preferred.service; tail -40 /var/log/b70.log
```

- The unit runs after docker. It stops at the first failed step, so a failed load never tunes.
- Expect about two minutes of GPU downtime per boot while the swap runs.
- After a dock hot-replug without a reboot, run `systemctl restart b70-preferred.service`.
- After a kernel update, the vermagic check makes the load `ABORTED`, and the boot runs on stock xe. Rebuild and re-sign (steps 2 and 3), then update `MODULE_SHA`.
- Better: build for the new kernel before you reboot into it, so the first boot already loads the patched xe. Install the new kernel and its headers first, then name both versions:

  ```bash
  apt install -t trixie-backports linux-image-amd64 linux-headers-<new-release>   # e.g. 7.2.11+deb13-amd64
  KREL=<new-release> DEBVER=<new-debian-version> ./build/build-xe.sh               # e.g. DEBVER=7.2.11-1~bpo13+1
  ./build/sign-xe.sh work/out/xe.ko /var/lib/dkms/mok.key /var/lib/dkms/mok.pub
  install -m 644 work/out/xe.ko /opt/b70/xe.ko                                      # then set MODULE_SHA, then reboot
  ```

  `DEBVER` is the package version `apt-cache policy linux-image-<new-release>` shows. Until the reboot, the running kernel's load will refuse the new module on vermagic, so do not restart the unit in between.
- Check every other out-of-tree module before a kernel jump. DKMS rebuilds packaged ones automatically, but a hand-built module, such as a patched GPU driver of any vendor, stays tied to the old kernel and silently falls back to stock.

## 8. Roll back

| To | Do |
|---|---|
| Stock xe now | Stop the GPU users, then `echo <addr> > /sys/bus/pci/drivers/xe/unbind; rmmod xe; modprobe xe` |
| Stock at boot | `systemctl disable b70-preferred.service` and reboot |
| A wedged card | Reboot. If the host hangs, hard-reset it |
| Remove everything | Disable the unit, then delete `/etc/systemd/system/b70-preferred.service`, `/opt/b70`, `/etc/b70`, `/var/log/b70.log`, `/run/b70-xe.sha` and the repo's `work/`, then reboot |

## 9. Bench

```bash
export B70_LLM_URL=http://<server>:8080 B70_LLM_KEY_CMD='<command that prints the key>' B70_PCI=<addr>
tools/b70bench.py stock && tools/b70sum.py stock
tools/b70coh.py stock               # record this hash; set COHERENCE_CMD/COHERENCE_EXPECT to enforce it
```

`b70bench.py` refuses to run while a server slot is busy, so it never measures a shared load.

## Keep this current

Update this guide and FINDINGS when:
- you move to a new kernel series
- the exzile pin changes
- a patch changes
- a measured value changes
