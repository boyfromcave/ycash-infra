#!/usr/bin/env python3
"""Fill the params volume once: the two Sapling proving files from download.z.cash (or $PARAMS_URL),
SHA-256 checked against the hashes zcutil/fetch-params.sh pins; a present file with the right hash
is kept. Runs as the faucet Deployment's init container."""
import hashlib
import os
import sys
import urllib.request

DIR = os.environ.get("PARAMS_DIR", "/params")
URL = os.environ.get("PARAMS_URL", "https://download.z.cash/downloads/")
FILES = {
    "sapling-spend.params": "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13",
    "sapling-output.params": "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


for name, want in FILES.items():
    path = os.path.join(DIR, name)
    if os.path.isfile(path) and sha256(path) == want:
        print(f"fetch-params: {name} present and verified", flush=True)
        continue
    tmp = path + ".part"
    print(f"fetch-params: downloading {URL}{name}", flush=True)
    with urllib.request.urlopen(URL + name, timeout=60) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    got = sha256(tmp)
    if got != want:
        os.remove(tmp)
        print(f"fetch-params: {name}: SHA-256 {got} != {want}", file=sys.stderr, flush=True)
        sys.exit(1)
    os.replace(tmp, path)
    print(f"fetch-params: {name} verified ({os.path.getsize(path)} bytes)", flush=True)
