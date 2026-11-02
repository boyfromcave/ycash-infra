#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Run a syncing ycash6 mainnet node through a list of snapshot heights, pausing it for seconds at each.

  supervise.py --datadir D --bin BINDIR --snapdir S --heights 570000,1100006,... [--tip]

For each height H not yet captured the node runs as `ycashd -datadir=D -daemon=0 -stopatheight=H`.
`-stopatheight` (ycash6 `src/main.cpp`, ActivateBestChain) shuts the node down cleanly with its chain
state exactly at H and connects nothing above it. The moment it exits, the bundle's parts of the
datadir (blocks/, chainstate/, vaults/, yellowback/) are cloned into `S/H/datadir/main/` with APFS
copy-on-write (`cp -c`, seconds and almost no space: the clone shares every extent with the live
datadir until the node rewrites it), and the node is started again towards the next height. Packing,
the statement and the checks (`snapshot.py`) then run on the clone while the node syncs on.

With `--tip`, after the last height the node syncs to the network's tip; once its initial block
download is complete and its tip has equalled its best header for `--tip-settle` seconds of polling, it is stopped
with the `stop` RPC, cloned into `S/tip-<height>/` the same way, and started a last time with exactly
`ycashd -datadir=D -daemon=0`, which also ends a run without `--tip`.

A node already running on D (an earlier start, not this process's child) is adopted: stopped with
the `stop` RPC and restarted under supervision. A rerun resumes: captured heights are recorded in
`S/supervise.json`. Every pause is recorded in `S/<dir>/capture.json`. Stdlib only.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

STOP_LINE = "-stopatheight: the active chain is at height %d; shutting down"
TIP_RE = re.compile(r"UpdateTip: new best hash=([0-9a-f]{64}) height=(\d+)")
BUNDLE_DIRS = ("blocks", "chainstate", "vaults", "yellowback")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Supervisor:
    def __init__(self, a):
        self.a = a
        self.datadir = os.path.abspath(a.datadir)
        # where the node keeps the network's files: the datadir itself on mainnet (tests: regtest/)
        self.netpath = os.path.join(self.datadir, a.netdir) if a.netdir else self.datadir
        self.snapdir = os.path.abspath(a.snapdir)
        self.ycashd = os.path.join(a.bin, "ycashd")
        self.cli_bin = os.path.join(a.bin, "ycash-cli")
        self.state_path = os.path.join(self.snapdir, "supervise.json")
        os.makedirs(self.snapdir, exist_ok=True)
        self.state = {"done": {}}
        if os.path.exists(self.state_path):
            with open(self.state_path) as f:
                self.state = json.load(f)

    def log(self, msg):
        line = "%s supervise: %s" % (now(), msg)
        print(line, flush=True)

    def save(self):
        tmp = self.state_path + ".part"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp, self.state_path)

    def cli(self, *args, timeout=60):
        r = subprocess.run([self.cli_bin, "-datadir=%s" % self.datadir] + [str(x) for x in args],
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode != 0:
            raise RuntimeError("ycash-cli %s: %s" % (args[0], (r.stderr or r.stdout).strip()))
        return r.stdout.strip()

    def running_pid(self):
        """The pid of a ycashd already running on the datadir, or None."""
        try:
            with open(os.path.join(self.netpath, "ycashd.pid")) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
        except (OSError, ValueError):
            return None
        r = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
        return pid if "ycashd" in r.stdout and self.datadir in r.stdout else None

    def wait_pid_exit(self, pid, limit=1800):
        t0 = time.time()
        while time.time() - t0 < limit:
            try:
                os.kill(pid, 0)
            except OSError:
                return True
            time.sleep(1)
        return False

    def debug_tail(self, nbytes=4 << 20):
        p = os.path.join(self.netpath, "debug.log")
        with open(p, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", "replace")

    def start(self, stop_at=None):
        args = [self.ycashd, "-datadir=%s" % self.datadir, "-daemon=0"]
        args += self.a.node_arg
        if stop_at is not None:
            args.append("-stopatheight=%d" % stop_at)
        out = open(os.path.join(self.datadir, "stdout.log"), "ab")
        # its own session: the node outlives this process and never gets its signals
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                             start_new_session=True, close_fds=True)
        out.close()
        self.log("started pid %d: %s" % (p.pid, " ".join(args[1:])))
        return p

    def clone(self, name, height, stopped_at, t_stop, method):
        dst_root = os.path.join(self.snapdir, name)
        dst = os.path.join(dst_root, "datadir", "main")
        if os.path.exists(dst):
            raise RuntimeError("%s exists; refusing to overwrite a capture" % dst)
        os.makedirs(dst)
        t0 = time.time()
        for d in BUNDLE_DIRS:
            src = os.path.join(self.netpath, d)
            if os.path.isdir(src):
                subprocess.run(["cp", "-cR", src, os.path.join(dst, d)], check=True)
        t1 = time.time()
        rec = {"height": height, "method": method, "stopped_at": stopped_at,
               "clone_seconds": round(t1 - t0, 1), "datadir": self.datadir}
        return dst_root, rec, t1

    def finish_capture(self, dst_root, rec, t_stop, key):
        rec["restarted_at"] = now()
        rec["pause_seconds"] = round(time.time() - t_stop, 1)
        with open(os.path.join(dst_root, "capture.json"), "w") as f:
            json.dump(rec, f, indent=2, sort_keys=True)
            f.write("\n")
        self.state["done"][key] = rec
        self.save()
        self.log("captured %s: %s" % (key, json.dumps(rec, sort_keys=True)))

    def adopt(self):
        pid = self.running_pid()
        if pid is None:
            return None
        h = None
        try:
            h = int(self.cli("getblockcount"))
        except Exception as e:  # noqa: BLE001 - still starting: stop it all the same
            self.log("adopt: getblockcount failed (%s)" % e)
        self.log("adopting pid %d at height %s: stop" % (pid, h))
        for _ in range(60):
            try:
                self.cli("stop")
                break
            except Exception as e:  # noqa: BLE001 - warming up
                self.log("adopt: stop refused (%s), retrying" % e)
                time.sleep(10)
        if not self.wait_pid_exit(pid):
            raise RuntimeError("pid %d did not exit" % pid)
        self.log("pid %d exited" % pid)
        return h

    def wait_height(self, p, h):
        """Wait for node p (started with -stopatheight=h) to stop at h; restart it on any other exit."""
        retries = 0
        while True:
            rc = p.wait()
            t_stop = time.time()
            stopped_at = now()
            if rc == 0 and (STOP_LINE % h) in self.debug_tail():
                self.log("pid %d stopped at %d (status 0)" % (p.pid, h))
                dst_root, rec, _ = self.clone(str(h), h, stopped_at, t_stop, "stopatheight")
                return dst_root, rec, t_stop
            retries += 1
            self.log("pid %d exited with status %d without reaching %d (retry %d)" % (p.pid, rc, h, retries))
            if retries > 5:
                self.start()
                raise RuntimeError("node keeps exiting before %d; left running without -stopatheight" % h)
            time.sleep(30)
            p = self.start(stop_at=h)

    def tip_phase(self, p):
        same = 0
        while True:
            time.sleep(self.a.poll)
            if p.poll() is not None:
                self.log("pid %d exited with status %s during the tip phase; restarting" % (p.pid, p.returncode))
                p = self.start()
                continue
            try:
                info = json.loads(self.cli("getblockchaininfo"))
            except Exception as e:  # noqa: BLE001
                self.log("getblockchaininfo: %s" % e)
                continue
            b, hd = info["blocks"], info["headers"]
            ibd_done = info.get("initial_block_download_complete", False)
            # synced: the initial download is over and the tip is the best header, poll after poll
            same = same + 1 if ibd_done and b == hd else 0
            if same * self.a.poll >= self.a.tip_settle:
                break
        self.cli("stop")
        rc = p.wait()
        t_stop = time.time()
        stopped_at = now()
        m = TIP_RE.findall(self.debug_tail())
        if rc != 0 or not m:
            raise RuntimeError("tip stop: status %s, no UpdateTip in the log" % rc)
        h = int(m[-1][1])
        self.log("pid %d stopped at the tip, height %d" % (p.pid, h))
        dst_root, rec, _ = self.clone("tip-%d" % h, h, stopped_at, t_stop, "stop-rpc-at-tip")
        rec["blockhash_logged"] = m[-1][0]
        return h, dst_root, rec, t_stop

    def run(self):
        heights = [int(x) for x in self.a.heights.split(",") if x]
        todo = [h for h in heights if str(h) not in self.state["done"]]
        h0 = self.adopt()
        if h0 is not None:
            passed = [h for h in todo if h <= h0]
            if passed:
                self.log("heights already passed, not capturable without a rollback: %s" % passed)
                for h in passed:
                    self.state["done"][str(h)] = {"height": h, "skipped": "passed at adoption (%d)" % h0}
                self.save()
                todo = [h for h in todo if h > h0]
        tip = self.a.tip and "tip" not in self.state["done"]
        p = self.start(stop_at=todo[0]) if todo else None
        for i, h in enumerate(todo):
            dst_root, rec, t_stop = self.wait_height(p, h)
            # restart at once: towards the next height, or plain (the tip phase, or the end)
            p = self.start(stop_at=todo[i + 1]) if i + 1 < len(todo) else self.start()
            self.finish_capture(dst_root, rec, t_stop, str(h))
        if p is None:
            p = self.start()
        if tip:
            h, dst_root, rec, t_stop = self.tip_phase(p)
            self.start()
            self.finish_capture(dst_root, rec, t_stop, "tip")
        self.log("done; the node runs on without -stopatheight")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--datadir", required=True)
    ap.add_argument("--bin", required=True, help="the directory holding ycashd and ycash-cli")
    ap.add_argument("--snapdir", required=True)
    ap.add_argument("--heights", required=True, help="comma-separated, ascending")
    ap.add_argument("--tip", action="store_true", help="also capture at the network tip, then run on")
    ap.add_argument("--tip-settle", type=int, default=900, help="seconds the node must report itself synced before the tip capture")
    ap.add_argument("--poll", type=int, default=60)
    ap.add_argument("--node-arg", action="append", default=[],
                    help="an extra ycashd argument for every start (repeatable), e.g. -optimize-getheaders=0")
    ap.add_argument("--netdir", default="", help="the network's subdirectory of the datadir (mainnet: none)")
    a = ap.parse_args(argv)
    Supervisor(a).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
