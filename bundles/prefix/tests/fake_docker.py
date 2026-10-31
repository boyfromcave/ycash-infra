# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""A stand-in for the `docker` CLI, just enough of it to run run-local.sh end to end offline.

The pack image's commands run harvest.py directly, with the -v mounts mapped back to host paths.
The zebrad image becomes a fake Zebra (tests/test_run_local.py) whose tip climbs as it is polled;
the ycashd image a fake ycashd (tests/test_run_local_mainnet.py) that answers with or without a network.
It models the Zebra v7.0.0 behaviour the 2026-10-28 smoke run hit: started with `--network none`
it never answers RPC (network init waits for DNS seeders before the RPC server starts).
State lives in $FAKE_DOCKER_DIR: <name>.pid, .port, .cookie, .log, .net, .requests.
"""

import json
import os
import signal
import subprocess
import sys
import time

D = os.environ["FAKE_DOCKER_DIR"]
TESTS = os.path.dirname(os.path.abspath(__file__))
HARVEST = os.path.join(os.path.dirname(TESTS), "harvest.py")
COOKIE = "__cookie__:ZmFrZQ=="


def f(name, ext):
    return os.path.join(D, name + ext)


def alive(name):
    try:
        with open(f(name, ".pid")) as fh:
            pid = int(fh.read())
        with open("/proc/%d/stat" % pid) as fh:
            return fh.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, ValueError):
        return False


def kill(name):
    try:
        with open(f(name, ".pid")) as fh:
            pid = int(fh.read())
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if not alive(name):
                break
            time.sleep(0.1)
    except (OSError, ValueError):
        pass


def parse_run(args):
    o = {"detach": False, "name": None, "network": None, "volumes": [], "env": {}}
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-d", "--rm"):
            o["detach"] |= a == "-d"
        elif a in ("--name", "--network", "--user", "-v", "-e", "--stop-signal", "--stop-timeout"):
            v = args[i + 1]
            i += 1
            if a == "--name":
                o["name"] = v
            elif a == "--network":
                o["network"] = v
            elif a == "-v":
                host, cont = v.split(":")[:2]
                o["volumes"].append((host, cont))
            elif a == "-e":
                k, _, val = v.partition("=")
                o["env"][k] = val
        else:
            return o, a, args[i + 1:]
        i += 1
    sys.exit("fake docker: no image")


def run(args):
    o, image, cmd = parse_run(args)
    if o["detach"] and "ycashd" in image:
        name = o["name"]
        with open(f(name, ".net"), "w") as fh:
            fh.write(o["network"])
        with open(f(name, ".history"), "a") as fh:
            fh.write(json.dumps({"network": o["network"], "args": cmd}) + "\n")
        state = dict((c, h) for h, c in o["volumes"])["/var/lib/ycash"]
        log = open(f(name, ".log"), "w")
        p = subprocess.Popen([sys.executable, "-I", os.path.join(TESTS, "test_run_local_mainnet.py"),
                              "--serve", D, name, state], stdout=log, stderr=log, start_new_session=True)
        with open(f(name, ".pid"), "w") as fh:
            fh.write(str(p.pid))
        print(name)
        return 0
    if o["detach"]:  # zebrad
        name = o["name"]
        with open(f(name, ".net"), "w") as fh:
            fh.write(o["network"])
        with open(f(name, ".env"), "w") as fh:
            json.dump(o["env"], fh)
        log = open(f(name, ".log"), "w")
        if o["network"] == "none":
            # Zebra 7.0.0 without DNS: add_initial_peers retries forever, RPC never starts
            code = ("import time\nwhile True:\n print('empty peer list after DNS resolution, "
                    "retrying after 5 seconds', flush=True)\n time.sleep(5)\n")
            p = subprocess.Popen([sys.executable, "-I", "-c", code], stdout=log, stderr=log,
                                 start_new_session=True)
        else:
            p = subprocess.Popen([sys.executable, "-I", os.path.join(TESTS, "test_run_local.py"),
                                  "--serve", D, name], stdout=log, stderr=log, start_new_session=True)
        with open(f(name, ".pid"), "w") as fh:
            fh.write(str(p.pid))
        print(name)
        return 0
    # the pack image: map container paths in the arguments back to the host
    vols = sorted(o["volumes"], key=lambda v: -len(v[1]))

    def host(a):
        for h, c in vols:
            if a == c or a.startswith(c + "/"):
                return h + a[len(c):]
        return a
    cmd = [host(a) for a in cmd]
    net = o["network"] or ""
    if net.startswith("container:") and cmd and cmd[0] in ("tip", "export", "chaininfo", "treestate", "crosscheck"):
        with open(f(net.split(":", 1)[1], ".port")) as fh:
            cmd[1:1] = ["--rpc-url", "http://127.0.0.1:%s" % fh.read().strip()]
    return subprocess.call([sys.executable, "-I", HARVEST] + cmd)


def main(argv):
    os.makedirs(D, exist_ok=True)
    cmd, rest = argv[0], argv[1:]
    if cmd == "build":
        return 0
    if cmd == "run":
        return run(rest)
    if cmd == "inspect":
        fmt, name = rest[1], rest[2]
        if not os.path.exists(f(name, ".pid")):
            return 1
        print("true" if alive(name) and ".Running" in fmt else ("false" if ".Running" in fmt else "0"))
        return 0
    if cmd == "exec":  # exec <name> cat <cookie path>: the cookie exists once the RPC server is up
        name = rest[0]
        if not (alive(name) and os.path.exists(f(name, ".cookie"))):
            return 1
        with open(f(name, ".cookie")) as fh:
            sys.stdout.write(fh.read())
        return 0
    if cmd == "logs":
        name = rest[-1]
        if not os.path.exists(f(name, ".log")):
            return 1
        with open(f(name, ".log")) as fh:
            sys.stdout.write("".join(fh.readlines()[-int(rest[1]):]))
        return 0
    if cmd == "stop":
        if not os.path.exists(f(rest[0], ".pid")):
            return 1
        kill(rest[0])
        return 0
    if cmd == "rm":
        names = [a for a in rest if not a.startswith("-")]
        code = 0
        for name in names:
            if not os.path.exists(f(name, ".pid")):
                code = 1
                continue
            kill(name)
            for ext in (".pid", ".port", ".cookie"):
                if os.path.exists(f(name, ext)):
                    os.remove(f(name, ext))
        return code
    sys.exit("fake docker: unsupported command %r" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
