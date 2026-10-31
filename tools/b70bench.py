#!/usr/bin/env python3
"""Bench a llama.cpp server running on the B70, with a 1 Hz sensor sampler.

Usage: b70bench.py <label> [--cold]
Env: B70_LLM_URL, B70_LLM_KEY_CMD (a command that prints the API key), B70_PCI, B70_BENCH_DIR (default ./bench).
Writes <B70_BENCH_DIR>/<label>/{results.json,sensors.csv} and touches done.
Six runs: about 2K and 7.4K prompt tokens, three each, 256 generated tokens, temperature 0, no prompt cache.
"""
import json, os, random, subprocess, sys, threading, time, urllib.request

LABEL = sys.argv[1]
COLD = "--cold" in sys.argv
OUT = os.path.join(os.environ.get("B70_BENCH_DIR", "bench"), LABEL)
os.makedirs(OUT, exist_ok=True)
URL = os.environ.get("B70_LLM_URL", "http://127.0.0.1:8080")   # a llama.cpp server running on the card
PCI = os.environ.get("B70_PCI", "0000:89:00.0")


def api_key():
    """The server's API key, from the command in B70_LLM_KEY_CMD (never printed or written); empty if unset."""
    cmd = os.environ.get("B70_LLM_KEY_CMD", "")
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True).stdout.strip() if cmd else ""
D = f"/sys/bus/pci/devices/{PCI}"
F = f"{D}/tile0/gt0/freq0"
H = next(f"{D}/hwmon/{h}" for h in os.listdir(f"{D}/hwmon") if open(f"{D}/hwmon/{h}/name").read().strip() == "xe")  # not xe_oc
KEY = api_key()


def rd(p):
    try:
        return open(p).read().strip()
    except Exception as e:  # xe fan1_input can fail with EAGAIN mid-read
        return "ERR" + type(e).__name__


def call(path, body=None, timeout=600):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {KEY}"} if KEY else {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


stop = threading.Event()


def sampler():
    with open(f"{OUT}/sensors.csv", "w") as f:
        f.write("t,act,cur,min,max,reasons,energy_uj,temp_pkg,temp_vram,temp_mctrl,fan,rpm_status\n")
        while not stop.is_set():
            row = [f"{time.time():.3f}", rd(f"{F}/act_freq"), rd(f"{F}/cur_freq"), rd(f"{F}/min_freq"),
                   rd(f"{F}/max_freq"), rd(f"{F}/throttle/reasons"), rd(f"{H}/energy1_input"),
                   rd(f"{H}/temp2_input"), rd(f"{H}/temp3_input"), rd(f"{H}/temp4_input"),
                   rd(f"{H}/fan1_input"), rd(f"{D}/power/runtime_status")]
            f.write(",".join(row) + "\n")
            f.flush()
            stop.wait(1.0)


WORDS = ("river stone lantern copper meadow signal harbor quiet amber thunder orchard velvet "
         "compass glacier ember willow canyon falcon marble prism tundra beacon").split()


def prompt(nwords):
    rng = random.Random(time.time_ns())
    body = " ".join(rng.choice(WORDS) for _ in range(nwords))
    return f"[{time.time_ns()}] Summarize the following text in detail.\n{body}\nSummary:"


def run(nwords, gen=256):
    t0 = time.time()
    r = call("/completion", {"prompt": prompt(nwords), "n_predict": gen, "ignore_eos": True,
                             "cache_prompt": False, "temperature": 0})
    tm = r["timings"]
    return {"words": nwords, "prompt_n": tm["prompt_n"], "pp_tps": round(tm["prompt_per_second"], 2),
            "prompt_ms": round(tm["prompt_ms"], 1), "gen_n": tm["predicted_n"],
            "tg_tps": round(tm["predicted_per_second"], 2), "wall_s": round(time.time() - t0, 2)}


res = {"label": LABEL, "start": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
       "settings": {k: rd(p) for k, p in {
           "min_freq": f"{F}/min_freq", "max_freq": f"{F}/max_freq", "power_profile": f"{F}/power_profile",
           "power1_cap": f"{H}/power1_cap", "vram_d3cold_threshold": f"{D}/vram_d3cold_threshold",
           "power_control": f"{D}/power/control"}.items()}}
slots = call("/slots")
if any(s.get("is_processing") for s in slots):
    res["error"] = "slot busy, bench not run"
else:
    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    time.sleep(3)
    res["runs"] = []
    for nwords in (1500, 6000):
        for _ in range(3):
            res["runs"].append(run(nwords))
    if COLD:
        time.sleep(60)
        c = run(1500, gen=32)
        c["cold_after_idle_s"] = 60
        res["cold"] = c
    time.sleep(2)
    stop.set()
    th.join()
res["end"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
json.dump(res, open(f"{OUT}/results.json", "w"), indent=1)
open(f"{OUT}/done", "w").write("ok\n")
