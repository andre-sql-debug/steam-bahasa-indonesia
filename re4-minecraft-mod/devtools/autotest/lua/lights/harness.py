# Fake REFramework harness for minecraft_lights.lua: Minecraft's light blocks as RE4 point lights
#   python3 harness.py <minecraft_lights.lua>
import json
import sys

import lupa

SCRIPT = open(sys.argv[1]).read()
fails = 0


def check(name, cond, info=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (("  :: " + str(info)) if not cond else ""))
    if not cond:
        fails += 1


ENV = r'''
CB = {}
local function add(n, f) CB[n] = CB[n] or {}; table.insert(CB[n], f) end
re = { on_pre_application_entry = function(n, f) add("pre:" .. n, f) end, on_application_entry = function(n, f) add(n, f) end,
       on_draw_ui = function(f) add("ui", f) end, on_script_reset = function(f) add("reset", f) end }
function run(n) for _, f in ipairs(CB[n] or {}) do f() end end
function frames(n) for _ = 1, n do run("LateUpdateBehavior") end end
local V = {}; V.__index = V
Vector3f = { new = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end }
local function obj(t) t.call = function(self, m, ...) local f = t[m]; if f == nil then error("no method " .. m) end return f(...) end
    t.add_ref = function(self) return self end; return t end
LEON = true
LEON_POS = Vector3f.new(100, 5, 200)
SDK_CALLS = 0          -- any call into RE4 through sdk (none at all while the feature is off)
local tr = obj({ get_Position = function() return LEON_POS end })
local body = obj({ get_Transform = function() return tr end })
local ctx = obj({ get_BodyGameObject = function() return body end })
local cm = obj({ getPlayerContextRef = function() if LEON then return ctx end return nil end })
FAILING = FAILING or {}   -- light setters that don't exist in this "RE4"
CREATED, DESTROYED, SETS, MOVES = 0, 0, 0, 0
CALLS = {}             -- setter name -> calls
OBJECTS, DESTROYED_NAMES, FINDS = {}, {}, {}
local function make_go(name)
    local go
    local t = { pos = nil }
    t = obj({ set_Position = function(p) MOVES = MOVES + 1; t.pos = p end })
    go = obj({ name = name, draw = true, [".ctor"] = function() end, get_Transform = function() return t end,
        set_DrawSelf = function(b) go.draw = b end,
        ["createComponent(System.Type)"] = function(ty)
            if ty ~= "via.render.PointLight" then error("wrong type " .. tostring(ty)) end
            local light = { values = {} }
            light.call = function(self, m, v)
                if m == ".ctor" then return end
                if m:sub(1, 4) == "get_" then return light.values["set_" .. m:sub(5)] end
                CALLS[m] = (CALLS[m] or 0) + 1
                if FAILING[m] then error("no method " .. m) end
                SETS = SETS + 1
                light.values[m] = v
            end
            light.add_ref = function(self) return self end
            go.light = light
            return light
        end,
        ["destroy(via.GameObject)"] = function(g) DESTROYED = DESTROYED + 1; g.destroyed = true; DESTROYED_NAMES[g.name] = true end })
    go.tr = t
    CREATED = CREATED + 1
    OBJECTS[#OBJECTS + 1] = go
    return go
end
CREATE_TRIES = 0
local create = { call = function(self, _, name) CREATE_TRIES = CREATE_TRIES + 1; return make_go(name) end }
-- (finds the objects made that RE4 still has, like objects kept through a loading screen)
local scene = obj({ ["findGameObject(System.String)"] = function(name)
    FINDS[#FINDS + 1] = name
    for _, o in ipairs(OBJECTS) do if o.name == name and not o.destroyed then return o end end
    return nil
end })
LIGHT_TYPE = LIGHT_TYPE == nil and true or LIGHT_TYPE
sdk = { get_managed_singleton = function() SDK_CALLS = SDK_CALLS + 1; return cm end,
    game_namespace = function(n) return "chainsaw." .. n end,
    get_native_singleton = function() return {} end, call_native_func = function() return scene end,
    find_type_definition = function(n) if n == "via.GameObject" then return { get_method = function() return create end } end end,
    typeof = function(n) if n == "via.render.PointLight" and not LIGHT_TYPE then return nil end return n end }
json = { load_file = function(f) local s = py_files[f]; if s == nil then return nil end return py_json(s) end,
         dump_file = function(f, t) return true end }
UI = {}
imgui = { tree_node = function(l) UI[#UI + 1] = "node:" .. l; return true end, tree_pop = function() end,
          text = function(t) UI[#UI + 1] = "text:" .. t end, checkbox = function(l, v) UI[#UI + 1] = "check:" .. l; return false, v end,
          slider_float = function(l, v) return false, v end, same_line = function() end }
'''


class Env:
    """One fresh Lua state with the fake RE4 and the script loaded."""

    def __init__(self, failing=(), light_type=True):
        self.L = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.files = {}
        self.seq = 0
        g = self.L.globals()
        g.py_files = self.files
        g.py_json = self.py_json
        self.L.execute("FAILING = {" + ",".join(f'["{m}"] = true' for m in failing) + "}; LIGHT_TYPE = "
                       + ("true" if light_type else "false"))
        self.L.execute(ENV)
        self.L.execute(SCRIPT)
        self.G = g
        self.M = g.MinecraftRE4Lights

    def py_json(self, s):
        L = self.L

        def conv(v):
            if isinstance(v, dict):
                return L.table_from({k: conv(x) for k, x in v.items()})
            if isinstance(v, list):
                return L.table_from([conv(x) for x in v])
            return v
        return conv(json.loads(s))

    def bridge(self, lights, in_world=True, new_seq=True):
        if new_seq:
            self.seq += 1
        self.files["minecraft_bridge.json"] = json.dumps({"seq": self.seq, "in_world": in_world, "lights": lights})

    def frames(self, n, lights=None, **kw):
        """n RE4 frames; with lights, Minecraft writes them anew every 3rd frame (it writes 20 times a second)."""
        for i in range(n):
            if lights is not None and i % 3 == 0:
                self.bridge(lights, **kw)
            self.G.frames(1)

    def objects(self):
        return [self.G.OBJECTS[i] for i in range(1, len(self.G.OBJECTS) + 1)]

    def lit_objects(self):
        """The light objects switched on (two on one spot count twice)."""
        out = []
        for o in self.objects():
            if o.destroyed or not o.draw or o.light is None:
                continue
            v = o.light["values"]
            if v["set_Enabled"] is False or v["set_Intensity"] == 0:
                continue
            out.append(o)
        return out

    def lit(self):
        """The light objects switched on: (x, y, z) -> their light's values."""
        out = {}
        for o in self.lit_objects():
            p = o.tr.pos
            out[(round(p.x, 3), round(p.y, 3), round(p.z, 3))] = o.light["values"]
        return out

    def most_lit(self, n):
        """n RE4 frames without Minecraft writing anything: the most light objects switched on in any of them."""
        most = 0
        for _ in range(n):
            self.G.frames(1)
            most = max(most, len(self.lit_objects()))
        return most


def light(x, y, z, level=15, rgb="FF9A3C", inside=0):
    return f"{x:.3f},{y:.3f},{z:.3f},{level},{rgb},{inside};"


A = light(101.5, 5.7, 201.5, 14, "FF9A3C")            # a torch
B = light(98.5, 5.5, 203.5, 15, "FFE6A0", 1)          # glowstone (a full block around its light)
C = light(104.5, 6.5, 196.5, 10, "58D2FF")            # a soul lantern

# ---- off by default: nothing happens, no calls into RE4 at all
e = Env()
check("off by default", e.M.settings.enabled is False and e.M.debug.status == "off")
e.frames(120, A + B + C)
check("off: no objects, no calls into RE4", e.G.CREATED == 0 and e.G.SDK_CALLS == 0 and e.G.SETS == 0,
      (e.G.CREATED, e.G.SDK_CALLS, e.G.SETS))

# ---- on: one light object per Minecraft light, placed and coloured
e.M.settings.enabled = True
e.frames(10, A + B + C)
lit = e.lit()
check("on: three lights made", e.G.CREATED == 3 and len(lit) == 3 and e.M.debug.shown == 3 and e.M.debug.sent == 3,
      (e.G.CREATED, len(lit), e.M.debug.shown, e.M.debug.sent))
torch = lit.get((101.5, 5.7, 201.5))
check("torch placed at its spot", torch is not None, list(lit))
if torch is not None:
    col = torch["set_Color"]
    check("torch colour (warm orange)", abs(col.x - 1.0) < 1e-6 and abs(col.y - 0x9A / 255) < 1e-6 and abs(col.z - 0x3C / 255) < 1e-6,
          (col.x, col.y, col.z))
    check("torch intensity and range from its level (14)", abs(torch["set_Intensity"] - 800 * 14 / 15) < 1e-6
          and abs(torch["set_AttenuationRange"] - 8 * 14 / 15) < 1e-6, (torch["set_Intensity"], torch["set_AttenuationRange"]))
    check("plain colour, small spot, no shadows by default", torch["set_BlackBodyRadiation"] is False
          and torch["set_UsingSameIntensity"] is False and abs(torch["set_Radius"] - 0.1) < 1e-6 and torch["set_ShadowCastFlag"] is False
          and torch["set_ShadowEnable"] is False and torch["set_Enabled"] is True)
names = [o.name for o in e.objects()]
check("every light object has its own name", len(set(names)) == 3 and all(n.startswith("MinecraftLight_") for n in names), names)
check("all setters reported working", all(e.M.debug.setters[n] == "works" for n in
      ["set_Enabled", "set_Color", "set_Intensity", "set_AttenuationRange", "set_Radius", "set_ShadowCastFlag",
       "set_ShadowEnable", "set_BlackBodyRadiation", "set_UsingSameIntensity"]), dict(e.M.debug.setters.items()))
values = e.M.debug["values"]   # (lupa: .values is the table's own method)
check("first light's values read back", values is not None and values["get_Intensity"] not in (None, "failed", "nil"),
      values and dict(values.items()))
check("status on", e.M.debug.status == "on", e.M.debug.status)

# ---- unchanged lights: no calls into the lights, also when the nearest are picked again
e.G.SETS, e.G.MOVES = 0, 0
e.frames(100, A + B + C)
check("unchanged lights: no setter calls, nothing moved", e.G.SETS == 0 and e.G.MOVES == 0 and e.G.CREATED == 3,
      (e.G.SETS, e.G.MOVES, e.G.CREATED))

# ---- a light goes: its object is switched off and kept; a new light reuses it
e.frames(6, A + C)
gone = [o for o in e.objects() if abs(o.tr.pos.x - 98.5) < 1e-6][0]
check("removed light switched off (kept, not destroyed)", gone.draw is False and gone.light["values"]["set_Enabled"] is False
      and gone.light["values"]["set_Intensity"] == 0 and not gone.destroyed and e.M.debug.shown == 2, (gone.draw, e.M.debug.shown))
D = light(99.5, 5.5, 199.5, 7, "FF2A18")               # a redstone torch
e.G.SETS, e.G.MOVES = 0, 0
e.frames(6, A + C + D)
lit = e.lit()
check("new light reuses the kept object", e.G.CREATED == 3 and (99.5, 5.5, 199.5) in lit and len(lit) == 3 and e.G.MOVES == 1,
      (e.G.CREATED, list(lit), e.G.MOVES))
red = lit.get((99.5, 5.5, 199.5))
check("reused object coloured and set up for its new light", red is not None and abs(red["set_Color"].y - 0x2A / 255) < 1e-6
      and abs(red["set_Intensity"] - 800 * 7 / 15) < 1e-6 and red["set_Enabled"] is True)
# a changed level (a furnace going out and in) re-sets only that light, without moving it
e.G.SETS, e.G.MOVES = 0, 0
e.frames(6, A + C + light(99.5, 5.5, 199.5, 3, "FF2A18"))
check("changed level: that light set up again, not moved", e.G.MOVES == 0 and 0 < e.G.SETS <= 5
      and abs(e.lit()[(99.5, 5.5, 199.5)]["set_Intensity"] - 800 * 3 / 15) < 1e-6, (e.G.MOVES, e.G.SETS))

# ---- settings: brightness and shadows (never for a light inside its own full block)
e.frames(6, A + B + C)
e.M.settings.brightness = 2.0
e.M.settings.shadows = True
e.frames(6, A + B + C)
lit = e.lit()
check("brightness doubles the intensity", abs(lit[(101.5, 5.7, 201.5)]["set_Intensity"] - 2 * 800 * 14 / 15) < 1e-6)
check("shadows on for the torch, off for the glowstone inside its block",
      lit[(101.5, 5.7, 201.5)]["set_ShadowCastFlag"] is True and lit[(98.5, 5.5, 203.5)]["set_ShadowCastFlag"] is False
      and lit[(98.5, 5.5, 203.5)]["set_ShadowEnable"] is False)
e.M.settings.brightness, e.M.settings.shadows = 1.0, False

# ---- many lights: at most 16, the nearest to Leon, made a few per frame
many = "".join(light(100.5 + i, 5.5, 200.5, 15) for i in range(30))
created = e.G.CREATED
per_frame = []
for i in range(12):
    c = e.G.CREATED
    e.frames(1, many if i % 3 == 0 else None)
    per_frame.append(e.G.CREATED - c)
lit = e.lit()
xs = sorted(k[0] for k in lit)
check("cap: 16 lights on, 16 objects at most", len(lit) == 16 and e.G.CREATED == 16, (len(lit), e.G.CREATED))
check("cap: the 16 nearest Leon", xs == [100.5 + i for i in range(16)], xs)
check("at most 4 new objects per frame", max(per_frame) <= 4, per_frame)
# Leon walks to the far end: the nearest are picked again (within half a second), no new objects
e.G.LEON_POS = e.L.eval("Vector3f.new(129, 5, 200)")
e.frames(35, many)
xs = sorted(k[0] for k in e.lit())
check("Leon moved: the lights nearest him now", xs == [100.5 + i for i in range(14, 30)] and e.G.CREATED == 16, (xs, e.G.CREATED))
e.G.LEON_POS = e.L.eval("Vector3f.new(100, 5, 200)")

# ---- malformed entries are left out; Minecraft on its title screen: lights off
e.frames(6, light(101.5, 5.7, 201.5, 14) + "NaN,5.0,200.0,15,FFFFFF,0;" + "1.0,2.0,15,FFFFFF,0;" + "1,2,3,0,FFFFFF,0;")
check("malformed lights left out", e.M.debug.sent == 1 and len(e.lit()) == 1, (e.M.debug.sent, len(e.lit())))
e.frames(6, A + B, in_world=False)
check("title screen: no lights", len(e.lit()) == 0 and e.M.debug.shown == 0)

# ---- Minecraft stops writing: lights off; back: on again with the kept objects
e.frames(6, A + B + C)
e.frames(100)          # the bridge file stays as it was
check("Minecraft gone: lights off", len(e.lit()) == 0 and e.M.debug.status == "waiting for Minecraft", e.M.debug.status)
created = e.G.CREATED
e.frames(6, A + B + C)
check("Minecraft back: lights on again, no new objects", len(e.lit()) == 3 and e.G.CREATED == created)

# ---- Leon goes away (loading screen): our objects are forgotten untouched, then looked for by name
destroyed, sets = e.G.DESTROYED, e.G.SETS
live_names = sorted(o.name for o in e.objects() if not o.destroyed)
e.G.LEON = False
e.frames(30, A + B + C)
check("loading: nothing destroyed or set", e.G.DESTROYED == destroyed and e.G.SETS == sets, (e.G.DESTROYED - destroyed, e.G.SETS - sets))
check("loading: status waiting for Leon", e.M.debug.status == "waiting for Leon", e.M.debug.status)
e.G.LEON = True
created = e.G.CREATED
e.frames(6, A + B + C)
finds = sorted(e.G.FINDS.values())
check("Leon back: our lights from before looked up by name", finds == live_names, (finds, live_names))
check("Leon back: our lights from before destroyed", all(e.G.DESTROYED_NAMES[n] for n in live_names),
      [n for n in live_names if not e.G.DESTROYED_NAMES[n]])
check("Leon back: new light objects made", e.G.CREATED == created + 3 and len(e.lit_objects()) == 3,
      (e.G.CREATED - created, len(e.lit_objects())))

# ---- switched off: every light object destroyed, then nothing more


def script_objects():
    """The game objects the script has now (not the ones it forgot at the loading screen, which RE4 freed)."""
    t = e.M.state.objects
    return [t[i].go for i in range(1, len(t) + 1)]


mine = script_objects()
e.M.settings.enabled = False
e.frames(3, A + B + C)
check("switched off: all destroyed", len(mine) == 3 and all(o.destroyed for o in mine) and len(script_objects()) == 0
      and e.M.debug.status == "off", (len(mine), e.M.debug.status))
calls = e.G.SDK_CALLS
e.frames(60, A + B + C)
check("switched off: no calls into RE4 any more", e.G.SDK_CALLS == calls, e.G.SDK_CALLS - calls)

# ---- script reset destroys our lights
e.M.settings.enabled = True
e.frames(6, A + B + C)
mine = script_objects()
e.L.execute('run("reset")')
check("script reset destroys our lights", len(mine) == 3 and all(o.destroyed for o in mine))

# ---- setters RE4 doesn't have: tolerated, reported, given up after a few tries
e = Env(failing=("set_Color", "set_ShadowEnable", "set_Enabled", "set_BlackBodyRadiation"))
e.M.settings.enabled = True
e.frames(10, A + B + C)
s = dict(e.M.debug.setters.items())
check("failing setters: lights still made and placed", e.G.CREATED == 3 and e.M.debug.shown == 3 and len(e.M.debug.errors) == 0,
      (e.G.CREATED, e.M.debug.shown, list(e.M.debug.errors.values())))
check("failing setters reported", s.get("set_Color") == "failed" and s.get("set_Enabled") == "failed"
      and s.get("set_Intensity") == "works" and s.get("set_ShadowCastFlag") == "works", s)
e.frames(10, D)
e.frames(10, A + B + C + D)
check("a setter that never worked is given up after 3 tries", all(e.G.CALLS[n] == 3 for n in ("set_Color", "set_ShadowEnable", "set_Enabled")),
      {n: e.G.CALLS[n] for n in ("set_Color", "set_ShadowEnable", "set_Enabled")})
e.frames(6, A)
dark = [o for o in e.objects() if not o.draw]
check("lights no longer needed: no brightness when switching off doesn't work", len(dark) == 3
      and all(o.light["values"]["set_Intensity"] == 0 for o in dark), [o.light["values"]["set_Intensity"] for o in dark])
e.L.execute("UI = {}")
e.L.execute('run("ui")')
ui = [e.G.UI[i] for i in range(1, len(e.G.UI) + 1)]
check("menu section drawn on its own without the menu script", "node:Minecraft Lights" in ui
      and "check:Minecraft lights light RE4 (experimental)" in ui, ui)
check("menu shows which setters work", any("Color failed" in u and "Intensity works" in u for u in ui), [u for u in ui if "settings" in u])
check("registered with the one Minecraft menu", e.L.eval("MinecraftRE4Menu.settings.lights == MinecraftRE4Lights.settings")
      and e.G.MinecraftRE4Menu.sections.lights is not None)

# ---- RE4 without point lights: no errors thrown, no objects, not tried every frame
e = Env(light_type=False)
e.M.settings.enabled = True
e.frames(400, A + B + C)
check("no PointLight type: nothing made, reported", e.G.CREATED == 0 and len(e.M.debug.errors) >= 1
      and "could not be made" in e.M.debug.status, (e.G.CREATED, e.M.debug.status))
check("no PointLight type: tried again only every few seconds", len(e.M.debug.errors) <= 2, list(e.M.debug.errors.values()))

# ---- a bridge file left from a Minecraft that is gone (closed or crashed in a world): its lights never come on
e = Env()
e.bridge(A + B + C)
e.M.settings.enabled = True
most = e.most_lit(120)
check("leftover file when RE4 starts: no lights, no objects", most == 0 and e.G.CREATED == 0
      and e.M.debug.status == "waiting for Minecraft", (most, e.G.CREATED, e.M.debug.status))
e.frames(10, A + B + C)
check("leftover file: lights on once Minecraft writes", len(e.lit_objects()) == 3, len(e.lit_objects()))
# switched off, Minecraft writes once more and closes, switched on again: the old file still isn't lit
e.M.settings.enabled = False
e.frames(10)
e.bridge(A + B)
e.frames(3)
e.M.settings.enabled = True
created = e.G.CREATED
most = e.most_lit(120)
check("leftover file when switched on again: no lights, no objects", most == 0 and e.G.CREATED == created,
      (most, e.G.CREATED - created))
e.frames(10, A + B)
check("switched on again: lights on once Minecraft writes", len(e.lit_objects()) == 2, len(e.lit_objects()))

print("FAILS", fails)
sys.exit(1 if fails else 0)
