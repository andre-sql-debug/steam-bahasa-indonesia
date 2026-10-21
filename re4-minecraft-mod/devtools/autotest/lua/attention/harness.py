#!/usr/bin/env python3
"""Runs minecraft_gameplay.lua in a fake REFramework (lupa, Lua 5.4) and exercises the new 'attention' code
through the script's real callbacks."""
import os
import sys
from lupa import lua54

HERE = os.path.dirname(os.path.abspath(__file__))
GAMEPLAY = sys.argv[1] if len(sys.argv) > 1 else "/home/user/steam-bahasa-indonesia/re4-minecraft-mod/minecraft_gameplay.lua"

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  :: " + str(detail)))


class World:
    def __init__(self):
        self.L = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(open(os.path.join(HERE, "fake_reframework.lua")).read())
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
        src = open(GAMEPLAY, encoding="utf-8").read()
        res = self.L.eval("load")(src, "@minecraft_gameplay.lua")
        chunk = res[0] if isinstance(res, tuple) else res
        if chunk is None:
            raise SystemExit("load failed: " + str(res))
        chunk()
        self.F = self.L.globals().FAKE
        self.G = self.L.globals()
        self.frame_calls = []   # (frame, game calls)

    def lua(self, code):
        return self.L.execute(code)

    def step(self, n=1):
        out = []
        for _ in range(n):
            self.lua("""
if FAKE.ticking and (FAKE.frame % 3 == 0) then BRIDGE.seq = BRIDGE.seq + 1 end
""")
            c = self.F.step()
            self.frame_calls.append((int(self.F.frame), int(c)))
            out.append(int(c))
        return out

    @property
    def frame(self):
        return int(self.F.frame)

    def events(self, since=0):
        evs = []
        for i in range(1, len(self.F.events) + 1):
            e = self.F.events[i]
            if e.frame > since:
                evs.append({k: e[k] for k in ("frame", "kind", "id", "key", "alive", "in_list", "destroyed", "x", "y", "z", "is_vec")})
        return evs

    def errors(self):
        return [dict(frame=e.frame, where=e.where, err=e.err) for e in (self.F.errors[i] for i in range(1, len(self.F.errors) + 1))]

    def ui(self):
        return [self.F.ui_text[i] for i in range(1, len(self.F.ui_text) + 1)]

    def ui_line(self, prefix):
        for t in self.ui():
            if t.startswith(prefix):
                return t
        return None

    def make_enemies(self, n, look=True, start=1, extra_comps=12):
        for i in range(start, start + n):
            self.lua(f"FAKE.make_enemy({{ id = {i}, pos = {{ {i * 1.5:.1f}, 0, 5 }}, hp = 100, look = {'true' if look else 'false'}, extra_comps = {extra_comps} }})")

    def key(self, i):
        return str(self.L.eval(f"tostring(FAKE.enemy_by_id[{i}].addr)"))

    def engage(self, fights):
        """fights: {enemy_id: (x, y, z)}"""
        s = "".join(f"{self.key(i)},{x:.2f},{y:.2f},{z:.2f};" for i, (x, y, z) in fights.items())
        self.G.BRIDGE.engaged = s
        return s

    def set_mode(self, mode):
        self.lua(f'MinecraftRE4Control.mode = "{mode}"')

    def checkbox(self, label, value):
        self.F.checkbox[label] = value


def kinds(evs, kind, eid=None):
    return [e for e in evs if e["kind"] == kind and (eid is None or e["id"] == eid)]


def settle(w):
    # Leon appears: 180 settle frames; show the debug panel
    w.checkbox("Show debug info", True)
    w.step(200)


# ----------------------------------------------------------------------------------------------------------
def test_basic():
    print("\n== basic: 20 enemies, 3 fights ==")
    w = World()
    w.make_enemies(20)
    settle(w)
    check("no Lua errors while settling", not w.errors(), w.errors())
    check("mode is Minecraft", (w.ui_line("Mode: ") or "").startswith("Mode: Minecraft"), w.ui_line("Mode: "))
    check("no look-at calls without fights", not w.events(), w.events()[:3])
    base = w.step(20)
    base_avg = sum(base) / len(base)
    print(f"   baseline calls/frame with 20 enemies, no fights: min {min(base)} max {max(base)} avg {base_avg:.1f}")

    f0 = w.frame
    fights = {3: (10.0, 1.6, 2.5), 7: (-4.25, 0.5, 8.0), 15: (100.0, -3.0, 0.0)}
    w.engage(fights)
    costs = w.step(1)
    first_frame_cost = costs[0]
    costs += w.step(1)
    first_two = list(costs)
    costs = w.step(20)
    evs = w.events(f0)
    sets = kinds(evs, "set")
    print(f"   calls/frame with 3 fights (first 2 frames incl. handle lookup): {first_two}; then min {min(costs)} max {max(costs)} avg {sum(costs)/len(costs):.1f}")
    check("set only on the 3 engaged enemies", sorted({e["id"] for e in sets}) == [3, 7, 15], sorted({e['id'] for e in sets}))
    ok_vec = all(abs(e["x"] - fights[e["id"]][0]) < 1e-9 and abs(e["y"] - fights[e["id"]][1]) < 1e-9 and abs(e["z"] - fights[e["id"]][2]) < 1e-9 and e["is_vec"] for e in sets)
    check("set gets the mob's eyes as a Vector3f for the right key", ok_vec, sets[:3])
    check("set key matches the engaged key", all(e["key"] == w.key(e["id"]) for e in sets))
    per_enemy = {i: len(kinds(evs, "set", i)) for i in fights}
    check("set every 2 frames (11 refreshes in 22 frames)", all(10 <= v <= 11 for v in per_enemy.values()), per_enemy)
    check("no UInt32 overload, no clears during the fight", not kinds(evs, "set_uint") and not kinds(evs, "clear"), evs[:2])
    check("debug line", w.ui_line("Mob fights: ") == "Mob fights: 3 enemies fighting Minecraft mobs, 3 looking at them", w.ui_line("Mob fights: "))
    extra = max(costs) - max(base)
    check("per-frame cost bounded (<= 120 extra managed calls on refresh frames)", extra <= 120, extra)
    print(f"   extra managed calls on a refresh frame vs no fights: {extra}; first-frame (lookup) cost {first_frame_cost}")

    # mob moves: new target
    f1 = w.frame
    fights[7] = (-5.0, 0.5, 9.0)
    w.engage(fights)
    w.step(4)
    s7 = kinds(w.events(f1), "set", 7)
    check("updated target position is used", s7 and abs(s7[-1]["x"] + 5.0) < 1e-9 and abs(s7[-1]["z"] - 9.0) < 1e-9, s7[-1:] )

    # fight ends for 15 (odd or even frame)
    f2 = w.frame
    del fights[15]
    w.engage(fights)
    w.step(1)
    e = w.events(f2)
    check("fight ends -> clear on that enemy the same frame", [x["id"] for x in kinds(e, "clear")] == [15], e)
    w.step(10)
    e = w.events(f2)
    check("no more calls on 15 after its fight ended", len([x for x in e if x["id"] == 15]) == 1, [x for x in e if x["id"] == 15])

    # enemy 7 dies while Minecraft still sends it
    f3 = w.frame
    w.lua("FAKE.enemy_by_id[7].live = false")
    w.step(10)
    e = w.events(f3)
    e7 = [x for x in e if x["id"] == 7]
    check("death -> exactly one clear, no set after death", [x["kind"] for x in e7] == ["clear"], e7)
    check("clear at death happens within 2 frames", e7 and e7[0]["frame"] - f3 <= 2, e7)
    # Minecraft drops it later
    f4 = w.frame
    del fights[7]
    w.engage(fights)
    w.step(4)
    check("no call when the dead enemy's fight ends later", not [x for x in w.events(f4) if x["id"] == 7], w.events(f4))

    # enemy 3 leaves the list (unloaded) while still engaged
    f5 = w.frame
    w.lua("FAKE.remove_enemy(3, true)")
    w.step(6)
    e3 = [x for x in w.events(f5) if x["id"] == 3]
    # by design: an enemy RE4 no longer lists may already be freed, so its parts are never touched again
    check("enemy leaves the list -> no call on it at all", e3 == [], e3)
    w.step(4)
    check("no Lua errors", not w.errors(), w.errors()[:2])
    return w


def test_releases():
    print("\n== releases: re4 mode, disconnect, combat off, look setting off, in_world/re4_control, reset ==")
    w = World()
    w.make_enemies(20)
    settle(w)
    fights = {2: (1.0, 1.0, 1.0), 4: (2.0, 2.0, 2.0)}

    def engaged_running():
        w.engage(fights)
        w.step(4)
        assert kinds(w.events(w.frame - 4), "set"), "fight did not start"

    def released_now(label, action, restore, expect_clear_frame_delay=0, wait=1):
        engaged_running()
        action()          # (UI actions step the click frame themselves)
        f = w.frame
        w.step(wait)
        e = w.events(f)
        clears = kinds(e, "clear")
        check(f"{label}: both enemies cleared", sorted(x["id"] for x in clears) == [2, 4], e)
        if clears:
            check(f"{label}: cleared on frame +{expect_clear_frame_delay + wait if expect_clear_frame_delay else wait}",
                  all(x["frame"] - f <= wait for x in clears), [x["frame"] - f for x in clears])
        w.step(10)
        e2 = w.events(f)
        check(f"{label}: no set while released and no repeated clear", not kinds(e2, "set") and len(kinds(e2, "clear")) == 2,
              [(x['frame'] - f, x['kind'], x['id']) for x in e2])
        g = w.frame
        restore()
        w.step(70)
        e3 = w.events(g)
        check(f"{label}: looking resumes after", {x["id"] for x in kinds(e3, "set")} == {2, 4}, e3[:2])

    released_now("MinecraftRE4Control.mode == re4", lambda: w.set_mode("re4"), lambda: w.set_mode("minecraft"))
    released_now("mode re4_moves keeps looking (control)", lambda: None, lambda: None) if False else None

    # disconnect: Minecraft stops ticking -> stale after BRIDGE_TIMEOUT_FRAMES (60)
    engaged_running()
    f = w.frame
    w.lua("FAKE.ticking = false")
    w.step(70)
    e = w.events(f)
    clears = kinds(e, "clear")
    check("disconnect (stale bridge): both cleared once", sorted(x["id"] for x in clears) == [2, 4], e[-4:])
    last_set = max([x["frame"] for x in kinds(e, "set")] or [f])
    print(f"   stale: last set at +{last_set - f}, clear at +{clears[0]['frame'] - f if clears else None}")
    check("disconnect: no set after the clear", all(x["frame"] < clears[0]["frame"] for x in kinds(e, "set")) if clears else False)
    check("disconnect: mode text", (w.ui_line("Mode: ") or "").startswith("Mode: built-in"), w.ui_line("Mode: "))
    w.lua("FAKE.ticking = true")
    w.step(10)

    # (a checkbox changes in on_draw_ui at the end of a frame, so the release is one frame later)
    def ui_off(label):
        def f():
            w.checkbox(label, False)
            w.step(1)     # the frame in which the user clicks the box
        return f
    released_now("settings.combat false", ui_off("Melee combat (left-click)"),
                 lambda: w.checkbox("Melee combat (left-click)", True))
    released_now("enemies_look_at_mobs false", ui_off("Enemies look at the Minecraft mobs fighting them"),
                 lambda: w.checkbox("Enemies look at the Minecraft mobs fighting them", True))
    released_now("in_world false", lambda: w.lua("BRIDGE.in_world = false"), lambda: w.lua("BRIDGE.in_world = true"))
    released_now("re4_control false", lambda: w.lua("BRIDGE.re4_control = false"), lambda: w.lua("BRIDGE.re4_control = true"))
    # bridge file missing = stale after BRIDGE_TIMEOUT_FRAMES, like a disconnect
    engaged_running()
    f = w.frame
    w.lua('FAKE.files["minecraft_bridge.json"] = nil')
    w.step(70)
    e = w.events(f)
    cl = kinds(e, "clear")
    check("bridge file missing: cleared once when stale, no set after", sorted(x["id"] for x in cl) == [2, 4]
          and all(x["frame"] < cl[0]["frame"] for x in kinds(e, "set")), [(x['frame'] - f, x['kind'], x['id']) for x in e][-4:])
    w.lua('FAKE.files["minecraft_bridge.json"] = BRIDGE')
    w.step(10)

    # re4_moves (ladders, kicks): looking continues
    engaged_running()
    f = w.frame
    w.set_mode("re4_moves")
    w.step(6)
    e = w.events(f)
    check("re4_moves keeps the look (no clear)", not kinds(e, "clear") and kinds(e, "set"), e[:3])
    w.set_mode("minecraft")

    # script reset
    engaged_running()
    f = w.frame
    w.F.reset()
    e = [x for x in w.events(f - 1) if x["kind"] == "clear"]
    check("script reset clears every look once", sorted(x["id"] for x in kinds(e, "clear")) == [2, 4], e)
    check("no Lua errors", not w.errors(), w.errors()[:2])
    return w


def test_settle_and_loading():
    print("\n== teleport/settle and loading (player gone) during a fight ==")
    w = World()
    w.make_enemies(5)
    settle(w)
    fights = {1: (1.0, 1.0, 1.0), 2: (2.0, 2.0, 2.0)}
    w.engage(fights)
    w.step(4)
    # Leon walks (Minecraft moves him -> auth_pos is held), then the game teleports him (cutscene/door)
    w.lua("BRIDGE.move.dx = 0.2; BRIDGE.keys = { w = false }")
    w.step(3)
    f = w.frame
    w.lua("FAKE.leon.pos = Vector3f.new(FAKE.leon.pos.x + 30, FAKE.leon.pos.y, FAKE.leon.pos.z)")
    w.set_mode("re4")       # it is a cutscene
    w.step(3)
    w.lua("BRIDGE.move.dx = 0")
    w.step(60)
    e = w.events(f)
    clears = kinds(e, "clear")
    first_clear = (clears[0]["frame"] - f) if clears else None
    print(f"   cutscene teleport with mode re4: first clear at frame +{first_clear}")
    check("cutscene starting on the teleport frame (mode re4): looks released right away (<= 2 frames)", first_clear is not None and first_clear <= 2,
          f"first clear at +{first_clear} (settle window holds the look)")
    w.set_mode("minecraft")
    w.step(70)

    # Realistic order: the cutscene starts (mode re4) one frame before it moves Leon
    w.engage(fights)
    w.lua("BRIDGE.move.dx = 0.2")
    w.step(4)
    f = w.frame
    w.set_mode("re4")
    w.step(1)
    w.lua("FAKE.leon.pos = Vector3f.new(FAKE.leon.pos.x + 30, FAKE.leon.pos.y, FAKE.leon.pos.z)")
    w.step(5)
    cl = kinds(w.events(f), "clear")
    check("cutscene that moves Leon a frame later: released at once", cl and cl[0]["frame"] - f <= 1, cl)
    w.set_mode("minecraft")
    w.lua("BRIDGE.move.dx = 0")
    w.step(70)

    # A door/teleport without RE4 mode (settle window), and the enemy dies inside that window
    w.engage(fights)
    w.lua("BRIDGE.move.dx = 0.2")
    w.step(4)
    f = w.frame
    w.lua("FAKE.leon.pos = Vector3f.new(FAKE.leon.pos.x + 30, FAKE.leon.pos.y, FAKE.leon.pos.z)")
    w.step(2)
    w.lua("FAKE.enemy_by_id[1].live = false; FAKE.remove_enemy(1, true)")
    w.lua("BRIDGE.move.dx = 0")
    w.step(70)
    e1 = [x for x in w.events(f) if x["id"] == 1]
    print(f"   teleport settle: enemy 1 removed at +2, its look calls: {[(x['frame'] - f, x['kind'], 'destroyed' if x['destroyed'] else '') for x in e1]}")
    check("enemy removed during a teleport settle: no call on it afterwards", not [x for x in e1 if x["destroyed"]], e1)

    # Loading: Leon disappears, the area's enemies are destroyed while Minecraft still reports the fight
    w2 = World()
    w2.make_enemies(5)
    settle(w2)
    w2.engage({1: (1.0, 1.0, 1.0), 2: (2.0, 2.0, 2.0)})
    w2.step(4)
    f = w2.frame
    w2.lua("FAKE.player_present = false")
    w2.step(5)
    w2.lua("FAKE.remove_enemy(1, true); FAKE.remove_enemy(2, true)")
    w2.make_enemies(3, start=10)
    w2.step(30)
    w2.lua("FAKE.player_present = true")
    w2.engage({})          # the new area: no fights
    w2.step(200)
    e = w2.events(f)
    on_destroyed = [x for x in e if x["destroyed"]]
    print(f"   loading: events after Leon left: {[(x['frame'] - f, x['kind'], x['id'], 'destroyed' if x['destroyed'] else '') for x in e]}")
    check("loading: no look-at calls on destroyed enemies of the old area", not on_destroyed,
          [(x['frame'] - f, x['kind'], x['id']) for x in on_destroyed])
    check("loading: looks released when Leon goes away (before the enemies are destroyed)",
          any(x["kind"] == "clear" and x["frame"] - f <= 2 for x in e), "no clear while player is gone")

    # Address reuse: an old enemy's address is reused by a new enemy during the load, Minecraft still sends the key
    w3 = World()
    w3.make_enemies(3)
    settle(w3)
    k = w3.key(1)
    w3.engage({1: (1.0, 1.0, 1.0)})
    w3.step(4)
    f = w3.frame
    w3.lua("FAKE.player_present = false")
    w3.step(5)
    w3.lua(f"FAKE.remove_enemy(1, true); FAKE.make_enemy({{ id = 99, addr = FAKE.enemy_by_id[1].addr, pos = {{ 0, 0, 3 }}, hp = 100 }})")
    w3.step(10)
    w3.lua("FAKE.player_present = true")
    w3.step(200)
    e = w3.events(f)
    bad = [x for x in e if x["kind"] == "set" and x["destroyed"]]
    print(f"   address reuse: set calls on the destroyed old enemy: {len(bad)}, on the new enemy 99: {len(kinds(e, 'set', 99))}")
    check("address reuse: never set on the destroyed enemy's component", not bad, f"{len(bad)} sets on destroyed enemy 1 (key {k})")
    return w


def test_missing_component_and_cost():
    print("\n== enemies without the look-at component, lookup cost ==")
    w = World()
    w.make_enemies(20, look=False, extra_comps=40)
    settle(w)
    base = w.step(10)
    fights = {i: (float(i), 1.0, 1.0) for i in (1, 2, 3)}
    w.engage(fights)
    f = w.frame
    costs = w.step(400)
    lookups = [c for c in costs]
    print(f"   no-component enemies: base max {max(base)}, max with 3 fights {max(costs)}, typical {sorted(costs)[len(costs)//2]}")
    spikes = [(i + 1, c) for i, c in enumerate(costs) if c > max(base) + 120]
    print(f"   spike frames (frame offset, calls): {spikes}")
    check("no set/clear calls when the component is missing", not w.events(f))
    check("debug says 0 looking", w.ui_line("Mob fights: ") == "Mob fights: 3 enemies fighting Minecraft mobs, 0 looking at them", w.ui_line("Mob fights: "))

    # 20 enemies, all engaged at once (worst case first frame)
    w2 = World()
    w2.make_enemies(20, extra_comps=40)
    settle(w2)
    base = w2.step(10)
    w2.engage({i: (float(i), 1.0, 1.0) for i in range(1, 21)})
    costs = w2.step(6)
    print(f"   20 fights at once, components at index 8 of 41: frame costs {costs} (baseline {max(base)})")
    check("20 fights: all 20 look", len({e['id'] for e in kinds(w2.events(0), 'set')}) == 20)
    return w


def test_set_failure_loses_clear():
    print("\n== setForceLookAtTarget throws once ==")
    w = World()
    w.make_enemies(3)
    settle(w)
    w.engage({1: (1.0, 1.0, 1.0)})
    w.step(4)
    w.lua("FAKE.set_fails[1] = true")
    w.step(2)
    w.lua("FAKE.set_fails[1] = nil")
    w.step(4)
    f = w.frame
    w.engage({})
    w.step(4)
    st_looking = w.L.eval("FAKE.enemy_by_id[1].looking_at ~= nil")
    e = w.events(f)
    check("after a failed set, ending the fight still clears the earlier look", kinds(e, "clear", 1) or not st_looking,
          f"enemy 1 still forced to look at its last target after fight end: looking_at set={st_looking}, clears={kinds(e, 'clear', 1)}")
    # and the look is not retried for 300 frames while still engaged
    w.engage({1: (1.0, 1.0, 1.0)})
    w.lua("FAKE.set_fails[1] = true")
    w.step(4)
    w.lua("FAKE.set_fails[1] = nil")
    g = w.frame
    w.step(100)
    print(f"   sets in the 100 frames after one transient failure: {len(kinds(w.events(g), 'set', 1))}")


def test_combat_paths():
    print("\n== existing combat paths alongside fights ==")
    w = World()
    w.make_enemies(4)
    # put enemy 1 right in front of Leon (yaw 0 = +Z), within reach
    w.lua("FAKE.enemy_by_id[1].pos = Vector3f.new(0, 0, 1.5)")
    w.lua("FAKE.enemy_by_id[2].pos = Vector3f.new(0, 0, 20)")
    settle(w)
    w.engage({1: (0.0, 1.6, 3.0), 2: (0.0, 1.6, 18.0)})
    w.step(4)
    # Minecraft damage through stand-ins (the first read is the baseline)
    k2 = w.key(2)
    w.lua(f'BRIDGE.enemy_damage["{k2}"] = 5.0')
    w.step(2)
    hp2_a = w.L.eval("FAKE.enemy_by_id[2].hp")
    w.lua(f'BRIDGE.enemy_damage["{k2}"] = 9.0')
    w.step(2)
    hp2_b = w.L.eval("FAKE.enemy_by_id[2].hp")
    check("enemy_damage applied to the right enemy (stand-in damage)", hp2_b < hp2_a, (hp2_a, hp2_b))
    # melee attack from Minecraft
    w.lua("BRIDGE.attack = { seq = 1, damage = 6, strength = 1 }")
    w.step(2)
    hp1_a = w.L.eval("FAKE.enemy_by_id[1].hp")
    w.lua("BRIDGE.attack = { seq = 2, damage = 6, strength = 1 }")
    w.step(2)
    hp1_b = w.L.eval("FAKE.enemy_by_id[1].hp")
    check("melee attack hits the enemy in front", hp1_b < hp1_a, (hp1_a, hp1_b, w.ui_line("Combat: ")))
    # arrow
    w.lua("BRIDGE.shot = { seq = 1, damage = 4 }")
    w.step(2)
    hp2_c = w.L.eval("FAKE.enemy_by_id[2].hp")
    w.lua("BRIDGE.shot = { seq = 2, damage = 4 }")
    w.step(2)
    hp_after = (w.L.eval("FAKE.enemy_by_id[1].hp"), w.L.eval("FAKE.enemy_by_id[2].hp"))
    check("arrow hits an enemy", hp_after[0] < hp1_b or hp_after[1] < hp2_c, (hp1_b, hp2_c, hp_after, w.ui_line("Combat: ")))
    # kill enemy 2 through Minecraft damage -> dead() + attention clear, in the same frame or next
    f = w.frame
    w.lua(f'BRIDGE.enemy_damage["{k2}"] = 200.0')
    w.step(4)
    dead_called = w.L.eval("FAKE.enemy_by_id[2].dead_called")
    e2 = [x for x in w.events(f) if x["id"] == 2]
    check("killing blow: dead() called once and the look cleared once, no set after", dead_called == 1 and [x["kind"] for x in e2] == ["clear"],
          (dead_called, e2))
    # movement from Minecraft still moves Leon
    p0 = w.L.eval("FAKE.leon.pos.x")
    w.lua("BRIDGE.move.dx = 0.2")
    w.step(10)
    p1 = w.L.eval("FAKE.leon.pos.x")
    w.lua("BRIDGE.move.dx = 0")
    check("Minecraft movement still moves Leon", p1 > p0, (p0, p1, w.ui_line("Movement: ")))
    check("no Lua errors", not w.errors(), w.errors()[:2])
    missing = {k: v for k, v in w.F.missing.items()}
    print(f"   methods the script called that the fake lacks (all pcall'd): {missing}")


def test_builtin_mode_unaffected():
    print("\n== built-in mode (no Minecraft) ==")
    w = World()
    w.lua('FAKE.files["minecraft_bridge.json"] = nil')
    w.make_enemies(3)
    settle(w)
    w.lua("FAKE.keys_down[0x57] = true")
    p0 = w.L.eval("FAKE.leon.pos.z")
    w.step(30)
    p1 = w.L.eval("FAKE.leon.pos.z")
    check("built-in walking still moves Leon", p1 > p0, (p0, p1, w.ui_line("Movement: ")))
    check("no look-at calls without Minecraft", not w.events())
    check("no Lua errors", not w.errors(), w.errors()[:2])


def test_parse_edge_cases():
    print("\n== engaged string edge cases ==")
    w = World()
    w.make_enemies(3)
    settle(w)
    k1, k2 = w.key(1), w.key(2)
    cases = {
        "no trailing ;": (f"{k1},1.00,2.00,3.00", set()),
        "garbage entry then good": (f"x,y;{k1},1.00,2.00,3.00;", {1}),
        "NaN coord": (f"{k1},NaN,2.00,3.00;{k2},1.00,2.00,3.00;", {2}),
        "unknown key": ("123,1.00,2.00,3.00;", set()),
        "empty": ("", set()),
        "negative/exponent": (f"{k1},-1.50,2e1,-3.00;", {1}),
    }
    for name, (s, expect) in cases.items():
        w.G.BRIDGE.engaged = s
        f = w.frame
        w.step(4)
        got = {e["id"] for e in kinds(w.events(f), "set")}
        check(f"parse '{name}'", got == expect, got)
        w.G.BRIDGE.engaged = ""
        w.step(2)
    w.lua("BRIDGE.engaged = 5")
    w.step(4)
    w.lua("BRIDGE.engaged = nil")
    w.step(4)
    check("non-string engaged: no errors", not w.errors(), w.errors()[:2])


if __name__ == "__main__":
    test_basic()
    test_releases()
    test_settle_and_loading()
    test_missing_component_and_cost()
    test_set_failure_loses_clear()
    test_combat_paths()
    test_builtin_mode_unaffected()
    test_parse_edge_cases()
    fails = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(fails)} passed, {len(fails)} failed")
    for name, _, detail in fails:
        print("  FAIL", name, "::", str(detail)[:400])
