#!/usr/bin/env python3
"""minecraft_diagnostics.lua (loaded first, like REFramework's alphabetical autorun) + minecraft_gameplay.lua in one Lua
state: the Flinch test drives MinecraftRE4Hit.flinch, picks the method, writes minecraft_flinch.json; the gameplay then
uses it. Usage: harness_diag.py [gameplay.lua] [diagnostics.lua]"""
import os
import sys
from lupa import lua54

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..")) + os.sep
GAMEPLAY = sys.argv[1] if len(sys.argv) > 1 else REPO + "minecraft_gameplay.lua"
DIAG = sys.argv[2] if len(sys.argv) > 2 else REPO + "minecraft_diagnostics.lua"
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  :: " + str(detail)))


class World:
    def __init__(self, files=None, react=None, setup=""):
        self.L = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(open(os.path.join(HERE, "fake_reframework.lua")).read())
        self.L.execute(open(os.path.join(HERE, "fake_hit.lua")).read())
        self.L.execute("""
BRIDGE = { seq = 1, in_world = true, re4_control = true,
  move = { dx = 0, dz = 0, forward = 0, right = 0, up = 0, on_ground = true, flying = false },
  keys = {}, enemy_damage = {}, attack = { seq = 0, damage = 0 }, shot = { seq = 0, damage = 0 },
  engaged = "", authority = false }
FAKE.files["minecraft_bridge.json"] = BRIDGE
FAKE.files["minecraft_bridge_input.json"] = { yaw = 0, pitch = 0 }
MinecraftRE4Control = { mode = "minecraft", reason = "Minecraft", minecraft_screen = false }
FAKE.ticking = true
""")
        if react:
            self.L.execute("FAKE.react_rule = " + react)
        self.L.execute(setup)
        for path, name in ((DIAG, "@minecraft_diagnostics.lua"), (GAMEPLAY, "@minecraft_gameplay.lua")):
            res = self.L.eval("load")(open(path, encoding="utf-8").read(), name)
            chunk = res[0] if isinstance(res, tuple) else res
            if chunk is None:
                raise SystemExit("load failed: " + str(res))
            chunk()
        self.F = self.L.globals().FAKE
        self.H = self.L.globals().MinecraftRE4Hit

    def lua(self, c):
        return self.L.execute(c)

    def ev(self, c):
        return self.L.eval(c)

    def step(self, n=1):
        for _ in range(n):
            self.lua("if FAKE.ticking and (FAKE.frame % 3 == 0) then BRIDGE.seq = BRIDGE.seq + 1 end")
            self.F.step()

    def errors(self):
        return [dict(frame=e.frame, where=e.where, err=e.err[:300]) for e in (self.F.errors[i] for i in range(1, len(self.F.errors) + 1))]

    def ui(self):
        return [self.F.ui_text[i] for i in range(1, len(self.F.ui_text) + 1)]

    def press(self, label):
        self.F.buttons[label] = True

    def flinch_json(self):
        t = self.F.files["minecraft_flinch.json"]
        return None if t is None else {k: v for k, v in t.items()}

    def our_calls(self):
        return [r for r in (self.F.received[i] for i in range(1, len(self.F.received) + 1)) if r.building]


def run_flinch_test(w):
    w.press("Flinch test")
    w.step(1)    # draw sets pending; next frame starts
    w.step(45 + 90 * 3 + 5)


def scenario_fresh_works():
    print("\n== Flinch test: only 'fresh' reacts (no real hit, no last attack) ==")
    w = World(react="function(f, st) return f.AttackData ~= nil and f.DamageUserData ~= nil and (f.Wince or 0) > 0 end")
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 3 }, hp = 100 })")
    w.lua("FAKE.make_enemy({ id = 2, pos = { 0, 0, 30 }, hp = 100 })")
    w.step(200)
    hp_before = w.ev("FAKE.enemy_by_id[1].hp")
    run_flinch_test(w)
    calls = w.our_calls()
    check("the test made exactly one call (only 'fresh' available)", len(calls) == 1, len(calls))
    check("...on the nearest enemy", len(calls) == 1 and calls[0].hc._addr == w.ev("FAKE.enemy_by_id[1].hc")._addr)
    check("method set to 'fresh'", w.H.method == "fresh", w.H.method)
    j = w.flinch_json()
    check("minecraft_flinch.json written {works=true, method='fresh'}", j is not None and j.get("works") is True and j.get("method") == "fresh", j)
    check("HP restored after the test", w.ev("FAKE.enemy_by_id[1].hp") == hp_before)
    check("our hits not captured as templates / reactions", w.H.template is None and w.ev("FAKE.hook_errors[1]") is None)
    check("no Lua errors", not w.errors(), w.errors()[:2])
    # a Minecraft hit right after uses it
    n = len(w.our_calls())
    w.lua("BRIDGE.attack = { seq = 1, damage = 2, strength = 1 }")
    w.step(1)
    check("next Minecraft melee hit flinches with the tested method", len(w.our_calls()) == n + 1, len(w.our_calls()) - n)
    return w


def scenario_template_only():
    print("\n== Flinch test: only the real-hit template reacts; next session ==")
    rule = "function(f, st) return f.AttackData ~= nil and f.AttackData._tag == 'knife' end"
    w = World(react=rule)
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 3 }, hp = 100 })")
    w.lua("FAKE.make_enemy({ id = 2, pos = { 4, 0, 3 }, hp = 100 })")
    w.step(200)
    # the player knifes enemy 2 with RE4 (F7)
    w.lua("FAKE.real_hit(FAKE.enemy_by_id[2].hc, FAKE.re4_info({ wince = 40.0 }))")
    w.step(200)
    check("real hit captured", w.H.template is not None)
    rl = w.ev("#FAKE.received")
    run_flinch_test(w)
    check("method 'template' chosen and saved", w.H.method == "template" and (w.flinch_json() or {}).get("method") == "template", (w.H.method, w.flinch_json()))
    check("no Lua errors", not w.errors(), w.errors()[:2])
    saved = w.flinch_json()

    # next session: json says template, no real hit yet
    w2 = World(react=rule, setup="FAKE.files['minecraft_flinch.json'] = { works = true, method = 'template', time = 'x' }")
    w2.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 2 }, hp = 100000 })")
    w2.step(200)
    reacted = 0
    for i in range(3):
        w2.lua(f"BRIDGE.attack = {{ seq = {i + 1}, damage = 1, strength = 1 }}")
        w2.step(31)
    check("next session, 3 Minecraft hits before any knife hit: flinch still on", w2.H.method == "template", (w2.H.method, w2.H.status))
    w2.lua("FAKE.real_hit(FAKE.enemy_by_id[1].hc, FAKE.re4_info({ wince = 40.0 }))")
    w2.step(31)
    n = len(w2.our_calls())
    w2.lua("BRIDGE.attack = { seq = 10, damage = 1, strength = 1 }")
    w2.step(1)
    check("next session: after one knife hit, Minecraft hits flinch", len(w2.our_calls()) == n + 1, (w2.H.method, w2.H.status))


def scenario_nothing_reacts():
    print("\n== Flinch test: nothing reacts, an older json said 'fresh' works ==")
    w = World(react="function() return false end",
              setup="FAKE.files['minecraft_flinch.json'] = { works = true, method = 'fresh', time = 'old' }")
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 3 }, hp = 100 })")
    w.step(200)
    run_flinch_test(w)
    j = w.flinch_json()
    print("   after a failed test: method =", w.H.method, "| json =", j, "| status =", w.H.status)
    # (a test that finds nothing, e.g. on a busy enemy, keeps what an earlier test found to work)
    check("a failed Flinch test keeps the method an earlier test found", w.H.method == "fresh" and (j or {}).get("works") is True, (w.H.method, j))


def scenario_retest_after_off():
    print("\n== Flinch test re-enables after the method was turned off by failures ==")
    w = World(react="function(f) return f.AttackData ~= nil end",
              setup="FAKE.files['minecraft_flinch.json'] = { works = true, method = 'last_attack', time = 'old' }")
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 2 }, hp = 100000 })")
    w.step(200)
    for i in range(3):
        w.lua(f"BRIDGE.attack = {{ seq = {i + 1}, damage = 1, strength = 1 }}")
        w.step(31)
    # (no last attack data on an enemy = that way can't be used on it yet, not a failure)
    check("still on after 3 hits on an enemy without last attack data", w.H.method == "last_attack" and w.H.failures == 0, (w.H.method, w.H.failures))
    run_flinch_test(w)
    check("Flinch test turned it back on", w.H.method is not None, w.H.method)
    print("   after re-test: method", w.H.method, "failures", w.H.failures)
    w.F.hc_throws = True
    w.lua("BRIDGE.attack = { seq = 20, damage = 1, strength = 1 }")
    w.step(31)
    w.F.hc_throws = False
    check("one failure after the re-test does not turn it off again", w.H.method is not None, (w.H.method, w.H.failures, w.H.status))
    check("no Lua errors", not w.errors(), w.errors()[:2])


def scenario_report_lights():
    print("\n== Diagnostics report: Minecraft lights (which RE4 light setters worked, lights shown) ==")
    w = World()
    res = w.L.eval("load")(open(REPO + "minecraft_lights.lua", encoding="utf-8").read(), "@minecraft_lights.lua")
    (res[0] if isinstance(res, tuple) else res)()
    w.lua("json.dump_file = function(name, t) FAKE.files[name] = t; return true end")
    # (the fake's type definitions have no fields, which the report's type dumps list)
    w.lua("""local find = sdk.find_type_definition
sdk.find_type_definition = function(n)
    local td = find(n)
    if type(td) == "table" and td.get_fields == nil then td.get_fields = function() return {} end end
    return td
end""")
    w.lua("MinecraftRE4Lights.debug.setters.set_Color = 'works'; MinecraftRE4Lights.debug.setters.set_Radius = 'failed'")
    w.step(5)
    w.press("Save report now")
    w.step(3)
    report = w.F.files["minecraft_diagnostics.json"]
    lights = report and report["minecraft_lights"]
    check("report written with a Minecraft lights section", lights is not None and lights["enabled"] is False
          and lights["status"] == "off" and lights["setters"]["set_Color"] == "works" and lights["setters"]["set_Radius"] == "failed",
          lights and dict(lights.items()))
    check("no Lua errors", not w.errors(), w.errors()[:2])


def main():
    scenario_fresh_works()
    scenario_template_only()
    scenario_nothing_reacts()
    scenario_retest_after_off()
    scenario_report_lights()
    fails = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(fails)} passed, {len(fails)} failed")
    for name, _, d in fails:
        print("  FAILED:", name, "::", d)


if __name__ == "__main__":
    main()
