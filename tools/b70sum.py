#!/usr/bin/env python3
"""Summarize b70bench runs, one JSON line each: b70sum.py <label> [<label> ...] (reads B70_BENCH_DIR, default ./bench)"""
import csv, json, os, statistics as st, sys

for label in sys.argv[1:]:
    d = os.path.join(os.environ.get("B70_BENCH_DIR", "bench"), label)
    r = json.load(open(f"{d}/results.json"))
    rows = list(csv.DictReader(open(f"{d}/sensors.csv")))
    watts = []
    for a, b in zip(rows, rows[1:]):
        try:
            watts.append((int(b["energy_uj"]) - int(a["energy_uj"])) / 1e6 / (float(b["t"]) - float(a["t"])))
        except ValueError:
            pass
    def num(k):
        return [int(x[k]) for x in rows if x[k].lstrip("-").isdigit()]
    busy = [w for w in watts if w > 60]
    runs = r.get("runs", [])
    pp = lambda n: [x["pp_tps"] for x in runs if x["words"] == n]
    tg = lambda n: [x["tg_tps"] for x in runs if x["words"] == n]
    out = {
        "label": label, "settings": r["settings"], "samples": len(rows),
        "pp_2k_med": st.median(pp(1500)) if pp(1500) else None, "pp_2k_all": pp(1500),
        "tg_2k_med": st.median(tg(1500)) if tg(1500) else None,
        "pp_7k_med": st.median(pp(6000)) if pp(6000) else None,
        "tg_7k_med": st.median(tg(6000)) if tg(6000) else None,
        "cold": {k: r["cold"][k] for k in ("prompt_ms", "pp_tps", "tg_tps")} if "cold" in r else None,
        "watts_max": round(max(watts), 1) if watts else None,
        "watts_busy_mean": round(st.mean(busy), 1) if busy else None,
        "watts_idle_min": round(min(watts), 1) if watts else None,
        "act_min_busy": min((int(x["act"]) for x, w in zip(rows[1:], watts) if w > 60 and x["act"].isdigit()), default=None),
        "act_max": max(num("act"), default=None),
        "temp_pkg_max": max(num("temp_pkg"), default=0) / 1000,
        "temp_vram_max": max(num("temp_vram"), default=0) / 1000,
        "temp_mctrl_max": max(num("temp_mctrl"), default=0) / 1000,
        "fan_max": max(num("fan"), default=None),
        "reasons": sorted({x["reasons"] for x in rows}),
        "rpm_status": sorted({x["rpm_status"] for x in rows}),
        "error": r.get("error"),
    }
    print(json.dumps(out))
