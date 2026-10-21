# Fake REFramework harness for minecraft_blocks.lua: its flat stand-in cubes are drawn only when Minecraft can't
# draw the blocks in the overlay, and never over a block RE4 already shows as a real object (minecraft_native.lua)
#   python3 harness.py <minecraft_blocks.lua>
import json
import sys

import lupa

L = lupa.LuaRuntime(unpack_returned_tuples=True)
FILES = {}
L.globals().py_files = FILES


def py_json(s):
    def conv(v):
        if isinstance(v, dict):
            return L.table_from({k: conv(x) for k, x in v.items()})
        if isinstance(v, list):
            return L.table_from([conv(x) for x in v])
        return v
    return conv(json.loads(s))


L.globals().py_json = py_json
L.execute(r'''
CB = {}
local function add(n, f) CB[n] = CB[n] or {}; table.insert(CB[n], f) end
re = { on_frame = function(f) add("frame", f) end, on_draw_ui = function(f) add("ui", f) end }
function frames(n) for _ = 1, n do for _, f in ipairs(CB.frame or {}) do f() end end end
local V = {}; V.__index = V
V.__add = function(a, b) return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z) end
Vector3f = { new = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end }
local function obj(t) t.call = function(self, m, ...) local f = t[m]; if f == nil then error("no method " .. m) end return f(...) end; return t end
LEON = Vector3f.new(100, 5, 200)
local tr = obj({ get_Position = function() return LEON end })
local body = obj({ get_Transform = function() return tr end })
local ctx = obj({ get_BodyGameObject = function() return body end })
local cm = obj({ getPlayerContextRef = function() return ctx end })
local cam_tr = obj({ get_Position = function() return Vector3f.new(LEON.x, LEON.y + 1.6, LEON.z) end })
local cam_go = obj({ get_Transform = function() return cam_tr end })
local camera = obj({ get_GameObject = function() return cam_go end })
sdk = { get_managed_singleton = function() return cm end, game_namespace = function(n) return "chainsaw." .. n end,
        get_primary_camera = function() return camera end }
reframework = { is_key_down = function() return false end }
json = { load_file = function(f) local s = py_files[f]; if s == nil then return nil end return py_json(s) end,
         dump_file = function() return true end }
-- QUADS: the world x of the middle of each stand-in face drawn (its 4 corners are the last 4 points projected)
QUADS, PTS = {}, {}
draw = { world_to_screen = function(p) PTS[#PTS + 1] = p; return { x = p.x, y = p.z } end, line = function() end,
         filled_quad = function()
             local n = #PTS
             QUADS[#QUADS + 1] = (PTS[n].x + PTS[n - 1].x + PTS[n - 2].x + PTS[n - 3].x) / 4
         end }
imgui = { tree_node = function() return false end }
''')
L.execute(open(sys.argv[1]).read())
G = L.globals()
fails = 0


def check(name, cond, info=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (("  :: " + str(info)) if not cond else ""))
    if not cond:
        fails += 1


def block_id(x, y, z):
    """Re4Native.blockId (-1 - BlockPos.asLong, as Java packs it): the number minecraft_native.lua knows a block by."""
    packed = ((x & 0x3FFFFFF) << 38) | (y & 0xFFF) | ((z & 0x3FFFFFF) << 12)
    return -1 - (packed & 0x7FFFFFFFFFFFFFFF)


# Minecraft's player at (0.5, 250, 0.5) is Leon at (100, 5, 200), the camera 1.6 above him: block A sits at RE4 x
# 96.5..97.5, C right next to it (97.5..98.5: A's side facing the camera is hidden by C), B on its own at 103.5.
# Negative coordinates on purpose
A, C, B = (-3, 251, -5), (-2, 251, -5), (4, 251, -5)
FILES["minecraft_blocks.json"] = json.dumps({"blocks": {f"{x},{y},{z}": "minecraft:stone" for x, y, z in (A, B, C)},
                                             "colors": {"minecraft:stone": "7f7f7f,7f7f7f"}})
seq = [0]


def run(n=3, in_overlay=False):
    """A few frames with the bridge file saying whether Minecraft draws the blocks; the stand-in quads per block."""
    L.execute("QUADS, PTS = {}, {}")
    for _ in range(n):
        seq[0] += 1
        FILES["minecraft_bridge.json"] = json.dumps({"seq": seq[0], "in_world": True, "pos": {"x": 0.5, "y": 250.0, "z": 0.5},
                                                     "flat_y": 250.0, "blocks_version": 1, "blocks_in_overlay": in_overlay})
        FILES["minecraft_overlay_plugin.json"] = json.dumps({"beat": seq[0], "ready": True})
        L.execute("frames(1)")
    mids = list(G.QUADS.values())

    def count(test):
        return sum(1 for x in mids if test(x)) / n
    return {"A": count(lambda x: 96.5 <= x < 97.49), "between A and C": count(lambda x: abs(x - 97.5) < 0.01),
            "C": count(lambda x: 97.51 < x <= 98.5), "B": count(lambda x: 103.5 <= x <= 104.5), "all": len(mids) / n}


run(31, in_overlay=True)   # the plugin's heartbeat is read every 30 frames
q = run(in_overlay=True)
check("Minecraft draws the blocks in the overlay: no stand-in cubes", q["all"] == 0, q)
plain = run()
check("RE4's turn (no overlay): stand-in cubes for every block, none between A and C", plain["A"] > 0 and plain["B"] > 0
      and plain["C"] > 0 and plain["between A and C"] == 0, plain)
L.execute("MinecraftRE4Native = { blocks_shown = {} }")
check("nothing shown by RE4: the same cubes", run() == plain, run())
G.MinecraftRE4Native.blocks_shown[str(block_id(*A))] = True
q = run()
check("block A shown by RE4 as a real object: no cube over it, B and C keep theirs", q["A"] == 0 and q["B"] == plain["B"]
      and q["C"] == plain["C"], (q, plain))
L.execute("MinecraftRE4Native.blocks_shown = {}")
check("RE4 no longer shows it: its cube is back", run() == plain, run())
G.MinecraftRE4Native.blocks_shown[str(block_id(*C))] = True
q = run()
check("block C shown by RE4: no cube over it, and it still hides A's side next to it", q["C"] == 0 and q["A"] == plain["A"]
      and q["B"] == plain["B"] and q["between A and C"] == 0, (q, plain))
L.execute("MinecraftRE4Native.blocks_shown = {}")
G.MinecraftRE4Native.blocks_shown[str(block_id(*B))] = True
q = run()
check("block B (positive x) shown by RE4: no cube over it, A and C keep theirs", q["B"] == 0 and q["A"] == plain["A"]
      and q["C"] == plain["C"], (q, plain))
print("FAILS", fails)
