#!/usr/bin/env python3
"""Coherence check: fixed prompts at temperature 0; prints a hash and the answers. Key never printed.

Usage: b70coh.py [label]. Env as b70bench.py. Record the hash at stock settings; after any tuning change the
same model and server must print the same hash. Use it as COHERENCE_CMD in b70.conf.
"""
import hashlib, json, os, subprocess, sys, urllib.request
URL = os.environ.get("B70_LLM_URL", "http://127.0.0.1:8080")   # a llama.cpp server running on the card
PCI = os.environ.get("B70_PCI", "0000:89:00.0")


def api_key():
    """The server's API key, from the command in B70_LLM_KEY_CMD (never printed or written); empty if unset."""
    cmd = os.environ.get("B70_LLM_KEY_CMD", "")
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True).stdout.strip() if cmd else ""
KEY = api_key()
QS = ["Q: What is 17 times 23? A:", "Q: What is the capital of Australia? A:",
      "Write the first ten prime numbers separated by commas:"]
outs = []
for q in QS:
    body = {"prompt": q, "n_predict": 48, "temperature": 0, "cache_prompt": False}
    req = urllib.request.Request(URL + "/completion", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {KEY}"} if KEY else {})})
    outs.append(json.loads(urllib.request.urlopen(req, timeout=300).read())["content"])
print(sys.argv[1] if len(sys.argv) > 1 else "", hashlib.sha256("\x00".join(outs).encode()).hexdigest()[:16])
for o in outs:
    print(repr(o[:120]))
