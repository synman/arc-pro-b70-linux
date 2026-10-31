# Findings on the reference B70

Card `8086:e223`, subsystem `1849:6025` (ASRock Creator), in a Thunderbolt 5 dock on Debian 13 with kernel 7.2.9.
Measured 2026-10-30 and 2026-10-31. These are one card's results, mostly one run each. Treat every number as
a starting point to re-measure, never as a safe value.

## VRAM rate (`oc/mem_speed`)

| Mbps | memtest_vulkan | Decode at ~2K tokens | Decode at ~7.4K tokens | Prefill at ~2K tokens |
|---|---|---|---|---|
| 19000, stock | pass | 73.12 tok/s | 61.43 | 1696 |
| 19500 | pass | 73.76 | 62.05 | 1708 |
| 20500 | pass | 74.51 | 62.69 | 1712 |
| 21000 | pass | 74.74 | 62.79 | 1708 |
| 21500 | pass | 75.15 | 63.19 | 1720 |
| 22000 | GT0 died, host locked | — | — | — |

- The model is Qwen3.6-35B-A3B Q5_K_M on llama.cpp with Vulkan. 21500 gives +2.8% decode for +13% memory speed. The MoE model is not purely bandwidth-bound.
- At 22000 the commit succeeded (`ret=0 data0=0x10001`). About 31 s later, at the first memtest, `xe_force_wake` warned and a TLB invalidation fence timed out. The B70 and its dock bridges fell off the bus, and the host had to be hard-reset. The GPU was otherwise idle.
- The B70's GDDR6 is rated 20 Gbps (Samsung K4ZAF325BC-SC20, per public teardowns of other B70 boards). Intel ships it at 19000. Anything above 20000 is past the datasheet.
- **Write `mem_speed` only with every GPU user stopped.** One write under an LLM load (19500, 2026-10-30) wedged GT0. It caused a forcewake ack timeout, then GuC no reply, then `device wedged`. Clean writes at the same rate with users stopped never wedged. The cause is a hypothesis, not proven.
- **Never reload xe on a wedged card.** Tearing down the wedged device once took the whole host down. Reboot instead. `load-xe.sh` refuses to run after a wedge this boot.
- The rate does not survive a reboot. A read before anything is staged this boot fails with `EPROTO`. The kernel logs `PCODE Mailbox failed: -71 Unknown (status 0x8)`, and that line is expected. With the patches, every boot logs it twice: once from the probe's cache seed, once from the tune script's pre-read.
- Windows' IGCL API says a VRAM speed set may need a device reset or reboot. The Linux path commits live. Live changes applied on this card, but whether a reset would be safer is unknown.
- Bench drift caution: a +8% jump once seen "at 19500" also appeared at 19000 in a later boot. Compare rates only inside one boot and one container, and use repeat runs.

## Other tuning

| Setting | Effect measured |
|---|---|
| GT0 clock pinned at 2800 MHz (min = max) | Within noise for the MoE model |
| `vram_d3cold_threshold` 0 | Within noise. A resident model already keeps the card out of D3cold |
| Runtime PM on for the card and the dock bridges | Within noise. It avoids wake latency |
| `power1_cap` 290 W | The firmware clamps it to 275 W. Read back after every write |
| `power_profile` | Only `base` and `power_saving` exist, and `base` is the top |
| VF curve −25 mV | Applied cleanly (the VF write path works on 1849:6025). Not kept |
| Fan table | The firmware default is loud at idle. The example table is quiet at about 47 °C idle and about 80% at a 270 W memtest load |

## Driver and build traps

- **Two hwmon dirs.** With patch 2 the card has hwmon `xe` (fans, power, temps) and `xe_oc` (VRAM clock). A script that takes the first `hwmon*` dir can land on `xe_oc` and see no fan files. Always pick by `name`.
- **Match the kernel source to the running kernel.** Debian's backports carry several `linux-source-7.2` versions at once. Our first builds were made from 7.2.11 source against a 7.2.9 kernel: vermagic matched and the module ran, but the xe code was not the kernel's own. `build-xe.sh` now installs the exact version `uname -v` names.
- **Secure Boot.** Lockdown accepts the module signed with an enrolled MOK. Taint shows `O`, and no `E`.
- **Keep the module out of `/lib/modules`.** Load it by `insmod` from your own path, so a reboot always brings stock xe and any failure leaves a working card.
- **Swap order.** Close every fd on the card. Then unbind the PCI device, because two module refs stay after the fds close: the MEI late-bind component and the HDA audio component. Then `rmmod xe` and `insmod`. Rollback is `rmmod xe; modprobe xe`.
- **A reload resets everything.** `min_freq`, `vram_d3cold_threshold` and `power/control` return to defaults, and so does the fan table. Re-apply after every load.
- **Expected stock noise.** Stock xe logs `failed to load xe/fan_control_8086_e223_1849_6025.bin (-2)` three times per probe. No such blob exists for this card, and the fan patch does not need one.
- **`fan1_input` flickers.** It returns `EAGAIN` or 0 when read again too soon, in runs of 2 to 4. In Python that can raise `TypeError` from codecs, not `OSError`. Catch `Exception`, and hold the last real value over a few misses.
- **Never enumerate PCODE domains blindly.** exzile reports a blind scan wedged a B60.
- **Build deps.** Install them with `-t trixie-backports`, or apt hits a `libelf1t64` conflict.

## Thunderbolt eGPU

- **Small BAR.** Hotplug sizing left the GPU branch with 256 MiB BAR2, and `resource2_resize` failed with `-ENOSPC`. Kernel 7.2.9 never moves a bridge's own BAR, so the BAR cannot grow at runtime. The fix was `thunderbolt.host_reset=0` on the kernel command line, with the dock powered before POST. Firmware then builds the tunnel and the card gets the full 32 GB BAR.
- **Side effect.** With `host_reset=0` the Linux thunderbolt driver fails to probe the JHL9580 host router. Hot-unplug and suspend are then unmanaged until reboot.
- **Compute needs the large BAR.** Intel's compute runtime (OpenCL and Level Zero) refuses a dGPU without Resizable BAR. Vulkan through Mesa does not need it.
- **Vulkan needs a new Mesa.** Debian trixie's Mesa 25.0.7 reports `No devices found` on the B70. Mesa 26.x, from sid or backports, drives it.
- **DRM numbers move.** `host_reset=0` changed the card and render numbers. Pin by `/dev/dri/by-path/pci-<addr>-render`, never by `renderDN`.
- **The dock keeps the card powered.** The dock's own PSU powers the card through a host reboot. A reboot may not reset the card's state.

## Whisper.cpp on the B70

`ggml-medium.en` ran on Vulkan with 4 threads, on a 600 s clip:

| Workers | Wall time | Speed |
|---|---|---|
| 1 | 31 s | 19x realtime |
| 2 | 51 s | 23.5x |
| 3 | 68 s | 26.5x |
| 4 | 87 s | 27.6x |

Each worker holds about 2.2 GB of VRAM. The Arrow Lake iGPU took 181.6 s for the same clip, so one B70 worker is about 6x faster.
