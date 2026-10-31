# Arc Pro B70 xe toolkit (Linux, Thunderbolt 5 eGPU)

Tools, kernel patches and field notes for running an Intel Arc Pro B70 (Battlemage BMG-G31, `8086:e223`)
on Debian with the in-kernel `xe` driver. These cover fan control, VRAM overclocking and VRAM clock monitoring,
plus a boot-time setup that falls back to stock on any failure.

Maintained by synman. Supported: Debian kernels only, because the build fetches the Debian source package that matches `uname -v`. Ubuntu and other distributions would need their own source step.

This repo builds on others' work. It does not replace it:
- Intel's unmerged xe fan-control series 168027.
- [exzile/intel-arc-pro-fan-control](https://github.com/exzile/intel-arc-pro-fan-control), which packages that
  series and adds `xe_gt_oc` (VF curve, `mem_speed`, `temp_limit`).

This repo adds two kernel patches on top of exzile, plus tools and findings. See [NOTICE.md](NOTICE.md) for what came from where.

> **Warning.** Everything here changes GPU firmware settings through undocumented PCODE mailbox calls.
> On the reference card a VRAM rate of 22000 Mbps killed the GPU and locked the whole host. Read
> [docs/FINDINGS.md](docs/FINDINGS.md) before writing any value, and keep a way to hard-reset the machine.

## What this adds beyond exzile

| Addition | Where |
|---|---|
| PCODE failures logged with the raw status, and a `mem_speed` read that reports "nothing staged" instead of a guessed 19000 | `patches/0001-*` |
| The VRAM clock as a hwmon device `xe_oc` (`freq1_input` in Hz, `freq1_label` = `mclk`), cached so monitors can poll it for free | `patches/0002-*` |
| `mem_speed` capped at 21500, the highest rate that passed on the reference card | `patches/0002-*` |
| A container build against the running Debian kernel, with the source version matched to `uname -v`, and the hook edits that wire `xe_gt_oc` into the driver | `build/` |
| Secure Boot signing with an enrolled MOK | `build/sign-xe.sh` |
| A live driver swap that refuses a wrong sha, signer, vermagic or a wedged card, and rolls back to stock | `scripts/load-xe.sh` |
| Config-driven tuning: clock pin, VRAM D3cold, runtime PM, a 10-point fan table, VRAM rate | `scripts/b70-tune.sh`, `scripts/b70.conf.example` |
| A boot unit that leaves stock xe on any failure | `systemd/b70-preferred.service` |
| An LLM bench with a 1 Hz sensor sampler, and a coherence hash for catching silent memory errors. Written for this repo, MIT | `tools/` |
| Measured results and hard-won traps | `docs/FINDINGS.md` |

The VRAM clock readout is shown by the btop fork [synman/btop](https://github.com/synman/btop), branch `arrowlake`.

## Reference system

Every number in this repo was measured on this one system. Your card may differ.
- Card: ASRock Intel Arc Pro B70 Creator 32 GB, subsystem `1849:6025`.
- Dock: Sparkle Studio-G Ultra 850, Thunderbolt 5 (JHL9480).
- Host: Minisforum MS-02 Ultra (Core Ultra 9 285HX, JHL9580).
- OS: Debian 13 with kernel `7.2.9+deb13-amd64` from trixie-backports, Secure Boot on with lockdown.
- Userspace: Mesa 26.2.6 (Vulkan), llama.cpp.

## Prerequisites

- Debian with a backports kernel whose xe binds `8086:e223`, which 7.2 does. Also `linux-headers-$(uname -r)`.
- Docker, used only for the throwaway build container.
- Under Secure Boot: an enrolled Machine Owner Key. Debian's DKMS key at `/var/lib/dkms/mok.key` works once enrolled with `mokutil --import`.
- Nothing else may use xe. The swap unbinds every device xe drives.

## Quick start

```bash
sudo ./build/build-xe.sh                                     # -> work/out/xe.ko (BUILD-OK)
sudo ./build/sign-xe.sh work/out/xe.ko /var/lib/dkms/mok.key /var/lib/dkms/mok.pub
sudo install -D -m 644 work/out/xe.ko /opt/b70/xe.ko
sudo install -D -m 644 scripts/b70.conf.example /etc/b70/b70.conf   # then set PCI, MODULE_SHA, SIGNER, the users to stop
sudo ./scripts/load-xe.sh && tail -3 /var/log/b70.log        # RELOAD-OK
sudo ./scripts/b70-tune.sh                                   # TUNE-OK; at stock until you fill in tuning values
```

[docs/OPERATORS-GUIDE.md](docs/OPERATORS-GUIDE.md) covers each step, the checks, the boot unit and rollback.

## Layout

| Path | What it is |
|---|---|
| `patches/` | The two kernel patches, applied in order after exzile's |
| `build/build-xe.sh`, `build/in-container.sh` | The container build of `xe.ko` |
| `build/sign-xe.sh` | MOK signing |
| `scripts/load-xe.sh` | Live swap to the patched module, with rollback |
| `scripts/b70-tune.sh` | Applies `b70.conf` and reads every value back |
| `scripts/b70.conf.example` | All settings, with the reference card's values |
| `systemd/b70-preferred.service` | Runs both scripts at boot |
| `tools/` | `b70bench.py`, `b70sum.py`, `b70coh.py` |
| `docs/` | Findings and the operator's guide |

## Undo

Run `sudo systemctl disable b70-preferred.service`, then reboot. Nothing is installed in `/lib/modules`,
so every boot starts on stock xe, and every sysfs value resets with it.

## License

The scripts and docs are MIT ([LICENSE](LICENSE)). Each patch takes the license of the kernel file it modifies.
Here those are xe files marked `SPDX-License-Identifier: MIT`. The upstream pieces the build fetches keep their own licenses. See [NOTICE.md](NOTICE.md).
