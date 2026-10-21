# Fake REFramework harness for minecraft_menu.lua (with the real minecraft_native.lua registering into it)
#   python3 harness.py <repo folder>
import json
import os
import sys

import lupa

REPO = sys.argv[1]
L = lupa.LuaRuntime(unpack_returned_tuples=True)
FILES = {}
DUMPS = []
L.globals().py_files = FILES
L.globals().py_dumps = DUMPS


def py_json(s):
    def conv(v):
        if isinstance(v, dict):
            return L.table_from({k: conv(x) for k, x in v.items()})
        if isinstance(v, list):
            return L.table_from([conv(x) for x in v])
        return v
    return conv(json.loads(s))


def py_dump(t):
    def conv(v):
        if lupa.lua_type(v) == 'table':
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [conv(v[k]) for k in sorted(keys)]
            return {str(k): conv(v[k]) for k in keys}
        return v
    return json.dumps(conv(t))


L.globals().py_json = py_json
L.globals().py_dump = py_dump
L.execute(r'''
CB = {}
local function add(n, f) CB[n] = CB[n] or {}; table.insert(CB[n], f) end
re = { on_pre_application_entry = function(n, f) add("pre:" .. n, f) end, on_application_entry = function(n, f) add(n, f) end,
       on_draw_ui = function(f) add("ui", f) end, on_script_reset = function(f) add("reset", f) end,
       on_frame = function(f) add("frame", f) end }
function run(n) for _, f in ipairs(CB[n] or {}) do f() end end
function frames(n) for _ = 1, n do run("frame") end end
Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
Quaternion = { new = function(w, x, y, z) return { w = w, x = x, y = y, z = z } end }
local cm = { call = function() return nil end }
sdk = { get_managed_singleton = function() return nil end, game_namespace = function(n) return "chainsaw." .. n end,
    find_type_definition = function() return nil end, typeof = function(n) return n end,
    create_resource = function() return nil end }
json = { load_file = function(f) local s = py_files[f]; if s == nil then return nil end return py_json(s) end,
         dump_file = function(f, t) py_files[f] = py_dump(t); py_dumps[#py_dumps + 1] = f; return true end }
-- imgui: records what is drawn; PRESS[label] = true makes a button/checkbox act once
UI, PRESS = {}, {}
imgui = {
    tree_node = function(l) UI[#UI + 1] = "node:" .. l; return true end,
    tree_pop = function() UI[#UI + 1] = "pop" end,
    text = function(t) UI[#UI + 1] = "text:" .. t end,
    same_line = function() end,
    button = function(l) UI[#UI + 1] = "button:" .. l; local p = PRESS[l]; PRESS[l] = nil; return p == true end,
    checkbox = function(l, v) UI[#UI + 1] = "check:" .. l; if PRESS[l] then PRESS[l] = nil; return true, not v end return false, v end,
    slider_int = function(l, v) return false, v end, slider_float = function(l, v) return false, v end,
}
function draw() UI = {}; run("ui"); return UI end
''')
G = L.globals()
fails = 0


def check(name, cond, info=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (("  :: " + str(info)) if not cond else ""))
    if not cond:
        fails += 1


def ui():
    t = G.draw()
    return [t[i] for i in range(1, len(t) + 1)]


# A stand-in for minecraft_gameplay.lua (same registration lines), then the real native script
L.execute(r'''
GAMEPLAY = { flinch = true, share_death = true, no_damage = true, fly_speed = 10.9, show_debug = false }
local function draw_ui() if imgui.tree_node("Minecraft Gameplay") then imgui.text("gameplay body"); imgui.tree_pop() end end
MinecraftRE4Menu = MinecraftRE4Menu or { sections = {}, settings = {} }
MinecraftRE4Menu.sections.gameplay = { order = 10, draw = draw_ui }
MinecraftRE4Menu.settings.gameplay = GAMEPLAY
re.on_draw_ui(function() if not MinecraftRE4Menu.present then draw_ui() end end)
''')
L.execute(open(os.path.join(REPO, "minecraft_native.lua")).read())
L.execute(open(os.path.join(REPO, "minecraft_lights.lua")).read())

drawn = ui()
check("without the menu script: each script draws its own section",
      "node:Minecraft Gameplay" in drawn and "node:Minecraft Real Mobs" in drawn and "node:Minecraft" not in drawn, drawn)

FILES["minecraft_settings.json"] = json.dumps({
    "gameplay": {"flinch": False, "fly_speed": "fast", "gone": 1, "show_debug": True},
    "native": {"enabled": True},
    "lights": {"enabled": True, "brightness": 1.5},
    "nosuchscript": {"x": 1}})
L.execute(open(os.path.join(REPO, "minecraft_menu.lua")).read())
check("menu marks itself present", G.MinecraftRE4Menu.present is True)
G.frames(1)
gp = G.GAMEPLAY
check("saved value put back on the first frame", gp.flinch is False)
check("a saved value of the wrong kind is ignored", gp.fly_speed == 10.9, gp.fly_speed)
check("debug switches are not restored", gp.show_debug is False)
check("unknown saved keys are not added", gp.gone is None)
check("other scripts' saved settings too (native)", G.MinecraftRE4Menu.settings.native.enabled is True)
check("Minecraft lights: saved settings put back", G.MinecraftRE4Lights.settings.enabled is True
      and G.MinecraftRE4Lights.settings.brightness == 1.5)

drawn = ui()
nodes = [d for d in drawn if d.startswith("node:")]
check("one Minecraft menu, sections inside in order", nodes[:3] == ["node:Minecraft", "node:Minecraft Gameplay", "node:Minecraft Real Mobs"], nodes)
check("scripts don't draw their own copy when the menu is there", nodes.count("node:Minecraft Gameplay") == 1, nodes)
check("quick settings shown", "check:Shared death (Minecraft and Leon die together)" in drawn and "check:Real RE4 mobs (experimental)" in drawn
      and "check:Minecraft lights light RE4 (experimental)" in drawn)
check("Minecraft lights section in the menu, after the real mobs", nodes.index("node:Minecraft Lights") > nodes.index("node:Minecraft Real Mobs"), nodes)
check("not connected line without Minecraft", any("not connected" in d for d in drawn), drawn[:4])

before = len([d for d in DUMPS if d == "minecraft_settings.json"])
G.frames(60)
after = len([d for d in DUMPS if d == "minecraft_settings.json"])
check("unchanged settings are not rewritten", after == before, (before, after))

G.PRESS["Shared death (Minecraft and Leon die together)"] = True
ui()
check("quick toggle changes the setting", gp.share_death is False)
G.frames(30)
saved = json.loads(FILES["minecraft_settings.json"])
check("changed settings are saved", saved["gameplay"]["share_death"] is False and saved["gameplay"]["flinch"] is False, saved)
check("debug switches are not saved", "show_debug" not in saved["gameplay"] and "show_debug" not in saved.get("native", {}), saved)

G.PRESS["Reset all settings to defaults"] = True
ui()
check("reset puts the values from the start back", gp.share_death is True and gp.flinch is True, (gp.share_death, gp.flinch))

# Support zip: report first, then the request; the Minecraft mod's answer is shown
L.execute("REPORTS = 0; MinecraftRE4Menu.save_report = function() REPORTS = REPORTS + 1 end")
G.PRESS["Make support zip"] = True
ui()
check("zip button saves the diagnostics report first", G.REPORTS == 1)
check("no request before the report had time", G.MinecraftRE4Menu.report_request is None)
G.frames(31)
req = G.MinecraftRE4Menu.report_request
check("then asks the Minecraft mod (a time)", isinstance(req, int) and req > 1600000000, req)
G.PRESS["Make support zip"] = True
ui()
G.frames(31)
check("a second press while busy does nothing", G.MinecraftRE4Menu.report_request == req and G.REPORTS == 1)
check("waiting text", any("waiting for Minecraft" in d or "making the zip" in d for d in ui()))
FILES["minecraft_bridge.json"] = json.dumps({"seq": 5, "in_world": True, "game_mode": "creative",
                                             "report": {"seq": req, "busy": False, "path": "C:\\Users\\x\\Desktop\\r.zip"}})
G.frames(31)
drawn = ui()
check("shows where the zip is", any("Saved: C:\\Users\\x\\Desktop\\r.zip" in d for d in drawn), [d for d in drawn if d.startswith("text:")])
check("connected line with Minecraft", any("in a world, creative" in d for d in drawn))
G.PRESS["Make support zip"] = True
ui()
G.frames(31)
check("next request is larger", G.MinecraftRE4Menu.report_request > req)

G.run("reset")
print("FAILS", fails)
sys.exit(1 if fails else 0)
