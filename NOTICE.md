# Attribution

This repo ships only its own patches, scripts and notes. The build fetches everything else from its source
at build time. Nothing below is redistributed here.

| Piece | Author and source | License | How this repo uses it |
|---|---|---|---|
| Linux kernel `drm/xe` driver | Intel and the kernel community, via Debian's `linux-source-7.2` package | xe files: MIT (per SPDX). The kernel: GPL-2.0 | The build extracts the Debian source that matches the running kernel |
| Fan control, series 168027, "[PATCH v1 0/5] Add fan control support" | Karthik Poosa (Intel), `intel-xe@lists.freedesktop.org`, https://patchwork.freedesktop.org/series/168027/ | GPL-2.0, as a kernel modification | Applied from exzile's `patch/xe-fan-control-168027-cachyos-7.1.2.patch`. It applies to Debian's 7.2.9 tree with `--fuzz=5` |
| The 168027 rebase for CachyOS 7.1.2 | https://github.com/PerkyZZ999/XeDriver_FanPatch | GPL-2.0 | Bundled in exzile's repo, which this build fetches |
| `xe_gt_oc.c`, `xe_gt_oc.h`: VF curve, `mem_speed`, `temp_limit`, PCODE probe | Published by exzile in https://github.com/exzile/intel-arc-pro-fan-control. The file header carries "Copyright Intel Corporation" and SPDX MIT, as xe files do | MIT | Fetched at commit `0fc18ceefbc5b6ff341926745f95f7c47058a741`. Our patches modify it |
| The hook edits that wire `xe_gt_oc` into `Makefile` and `xe_gt.c` | Written for this repo, following exzile's install steps | MIT | `build/in-container.sh`, step 5 |
| The VF/PCODE opcode research behind `xe_gt_oc` | exzile's `docs/OVERCLOCKING.md` and the reports it cites | — | Background for `docs/FINDINGS.md` |

Everything else in this repo was written for it by synman under MIT: the two patches, `build/`, `scripts/`, `systemd/`, `tools/` and `docs/`. What this repo itself contributes is listed in the README under "What this adds beyond exzile". The patches in
`patches/` are this repo's own changes. Each one says in its header what it applies on top of.

If series 168027 or an `xe_gt_oc` equivalent lands in mainline Linux, prefer the upstream driver.
