"""One command to check the whole mod without RE4: Lua script harnesses, then a build, then the real Minecraft
client against a fake RE4 (every scenario in scenarios.py), then Minecraft is closed again.

    python3 devtools/autotest/run_all.py [--only name,name] [--no-client]

Needs: Python 3 with lupa, Xvfb, Java 21, and the TestFlat world in minecraft-bridge-mod/run/saves.
Writes devtools/autotest/.report/report.json and prints a summary. Exit code 0 when nothing failed.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MOD = os.path.join(REPO, "minecraft-bridge-mod")
sys.path.insert(0, HERE)

import scenarios                      # noqa: E402
from fake_re4 import FakeRE4          # noqa: E402
from mc_client import MinecraftClient  # noqa: E402

GAME = os.environ.get("AUTOTEST_GAME", os.path.join(HERE, ".game"))   # a fake RE4 folder
DATA = os.path.join(GAME, "reframework", "data")
REPORT_DIR = os.path.join(HERE, ".report")

LUA_SUITES = [
    ("lua: real RE4 mobs spawner", [os.path.join(HERE, "lua", "native", "harness.py"), os.path.join(REPO, "minecraft_native.lua")],
     r"FAILS (\d+)"),
    ("lua: block stand-ins skip RE4's real blocks", [os.path.join(HERE, "lua", "blocks", "harness.py"),
                                                      os.path.join(REPO, "minecraft_blocks.lua")], r"FAILS (\d+)"),
    ("lua: enemies look at mobs", [os.path.join(HERE, "lua", "attention", "harness.py"), os.path.join(REPO, "minecraft_gameplay.lua")],
     r"\d+ passed, (\d+) failed"),
    ("lua: one Minecraft menu, saved settings", [os.path.join(HERE, "lua", "menu", "harness.py"), REPO], r"FAILS (\d+)"),
    ("lua: flinch test and Minecraft hits", [os.path.join(HERE, "lua", "hit", "harness_diag.py")], r"\d+ passed, (\d+) failed"),
    ("lua: attack test, enemies swing at mobs", [os.path.join(HERE, "lua", "hit", "test_attacks.py")], r"FAILS (\d+)"),
]


def run_lua_suites():
    out = []
    for name, args, pattern in LUA_SUITES:
        if not os.path.exists(args[0]):
            continue
        r = subprocess.run([sys.executable, "-I"] + args, capture_output=True, text=True, timeout=600,
                           cwd=os.path.dirname(args[0]))
        text = r.stdout + r.stderr
        m = None
        for m in re.finditer(pattern, text):
            pass
        failed = int(m.group(1)) if m else None
        fails = [l for l in text.splitlines() if l.startswith("FAIL") or l.startswith("  FAIL")]
        out.append({"name": name, "passed": failed == 0, "details": {"failed": failed, "failures": fails[:10],
                                                                     "tail": text.strip().splitlines()[-2:]}})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--no-client", action="store_true")
    args = ap.parse_args()
    only = set(filter(None, args.only.split(",")))
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(REPORT_DIR, exist_ok=True)
    results = run_lua_suites()

    mc = MinecraftClient(MOD, os.path.join(REPORT_DIR, "minecraft.log"))
    if not args.no_client:
        ok, out = mc.build()
        results.append({"name": "build", "passed": ok, "details": {"output": out[-2000:]}})
        if ok:
            try:
                started = mc.start(os.path.join(MOD, "run", "config", "re4bridge.txt"), os.path.join(DATA, "minecraft_bridge.json"))
                results.append({"name": "minecraft starts", "passed": started, "details": {}})
                if started:
                    re4 = FakeRE4(DATA, [os.path.join(REPO, "minecraft_control.lua"), os.path.join(REPO, "minecraft_terrain.lua")])
                    # Minecraft connects, anchors, gets RE4's terrain and takes commands (not a fixed time: it varies).
                    # "Loading terrain" can stay up to 30 s (it waits for a world chunk drawn, and the overlay draws
                    # none): typed commands would go to it, so wait until no screen is open
                    ready_by = time.time() + 60.0
                    while time.time() < ready_by:
                        re4.run_for(1.0)
                        b = re4.bridge()
                        if (b.get("in_world") and b.get("overlay") and (b.get("terrain_boxes") or 0) > 0 and b.get("authority")
                                and b.get("screen_open") is False):
                            break
                    re4.run_for(3.0)
                    for sc in scenarios.ALL:
                        if only and sc.__name__ not in only:
                            continue
                        t0 = time.time()
                        try:
                            r = sc(re4, mc)
                        except Exception:
                            r = {"name": sc.__name__, "passed": False, "details": {"error": traceback.format_exc()[-1500:]}}
                        r["details"]["seconds"] = round(time.time() - t0, 1)
                        results.append(r)
                        print(("PASS " if r["passed"] else ("SKIP " if r["passed"] is None else "FAIL ")) + r["name"], flush=True)
            finally:
                mc.stop()

    with open(os.path.join(REPORT_DIR, "report.json"), "w") as f:
        json.dump(results, f, indent=1)
    print("\n==== summary ====")
    for r in results:
        mark = "PASS" if r["passed"] else ("SKIP" if r["passed"] is None else "FAIL")
        print(f"{mark}  {r['name']}  {json.dumps(r['details'])[:300]}")
    return 0 if all(r["passed"] is not False for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
