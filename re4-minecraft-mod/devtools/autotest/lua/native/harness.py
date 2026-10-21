# Fake REFramework harness for minecraft_native.lua
import lupa, json, sys
L = lupa.LuaRuntime(unpack_returned_tuples=True)
FILES = {}
L.globals().py_files = FILES
L.execute(r'''
LOG = {}
local function log(s) LOG[#LOG+1] = s end
CB = {}
local function add(n, f) CB[n] = CB[n] or {}; table.insert(CB[n], f) end
re = { on_pre_application_entry = function(n, f) add("pre:" .. n, f) end, on_application_entry = function(n, f) add(n, f) end,
       on_draw_ui = function(f) add("ui", f) end, on_script_reset = function(f) add("reset", f) end }
function run(n) for _, f in ipairs(CB[n] or {}) do f() end end
local V = {}; V.__index = V
Vector3f = { new = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end }
Quaternion = { new = function(w, x, y, z) return { w = w, x = x, y = y, z = z } end }   -- glm order
local function obj(t) t.call = function(self, m, ...) local f = t[m]; if f == nil then error("no method " .. m) end return f(...) end
    t.add_ref = function(self) return self end; return t end
LEON = true
local ctx = obj({})
local cm = obj({ getPlayerContextRef = function() if LEON then return ctx end return nil end })
RESOURCES_OK = { ["minecraft/m_a.mesh"] = true, ["minecraft/t_a.mdf2"] = true, ["minecraft/m_b.mesh"] = true }
CREATED, DESTROYED = 0, 0
SETS = 0   -- calls that move an object (set_Position / set_Rotation / set_LocalScale)
OBJECTS = {}
local function make_go(name)
    local go
    local tr = { pos = nil, rot = nil, scale = nil }
    tr = obj({ set_Position = function(p) SETS = SETS + 1; tr.pos = p end, set_Rotation = function(q) SETS = SETS + 1; tr.rot = q end,
               set_LocalScale = function(s) SETS = SETS + 1; tr.scale = s end })
    go = obj({ name = name, draw = true, [".ctor"] = function() end, get_Transform = function() return tr end,
        set_DrawSelf = function(b) go.draw = b end,
        ["createComponent(System.Type)"] = function(t)
            local mesh = {}
            mesh = obj({ [".ctor"] = function() end, setMesh = function(h) mesh.m = h end, set_Material = function(h) mesh.mat = h end,
                set_ForceDynamicMesh = function() end, set_StaticMesh = function() end, set_DrawShadowCast = function() end })
            go.mesh = mesh
            return mesh
        end,
        ["destroy(via.GameObject)"] = function(g) DESTROYED = DESTROYED + 1; g.destroyed = true end })
    go.tr = tr
    CREATED = CREATED + 1
    OBJECTS[#OBJECTS + 1] = go
    return go
end
local create = { call = function(self, _, name) return make_go(name) end }
sdk = { get_managed_singleton = function() return cm end, game_namespace = function(n) return "chainsaw." .. n end,
    find_type_definition = function(n) if n == "via.GameObject" then return { get_method = function() return create end } end end,
    typeof = function(n) return n end,
    create_resource = function(t, path)
        if not RESOURCES_OK[path] then return nil end
        return obj({ create_holder = function(self, ht) return obj({ path = path, ht = ht }) end })
    end }
-- the resource's create_holder is called with ':' (self) so define it accordingly
json = { load_file = function(f) local s = py_files[f]; if s == nil then return nil end return py_json(s) end,
         dump_file = function(f, t) py_files[f] = py_dump(t); return true end }
imgui = { tree_node = function() return true end, tree_pop = function() end, text = function() end,
          checkbox = function(l, v) return false, v end }
''')
def py_json(s):
    def conv(v):
        if isinstance(v, dict): return L.table_from({k: conv(x) for k, x in v.items()})
        if isinstance(v, list): return L.table_from([conv(x) for x in v])
        return v
    return conv(json.loads(s))
def py_dump(t):
    def conv(v):
        if lupa.lua_type(v) == 'table':
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys): return [conv(v[k]) for k in sorted(keys)]
            return {str(k): conv(v[k]) for k in keys}
        return v
    return json.dumps(conv(t))
L.globals().py_json = py_json
L.globals().py_dump = py_dump
FILES["minecraft_native_settings.json"] = json.dumps({"enabled": True})
L.execute(open(sys.argv[1]).read())
G = L.globals()
fails = 0
def check(name, cond, info=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (("  :: " + str(info)) if not cond else ""))
    if not cond: fails += 1
def frames(n):
    for _ in range(n): L.execute('run("LateUpdateBehavior")')
FILES["minecraft_native_assets.json"] = json.dumps({"exports": {"1": {"mesh": "minecraft/m_a.mesh", "material": "minecraft/t_a.mdf2"},
                                                               "2": {"mesh": "minecraft/m_b.mesh", "material": "minecraft/t_missing.mdf2"}}, "session": 42})
frames(30)
st = json.loads(FILES.get("minecraft_native_status.json", "{}"))
check("status written, enabled", st.get("enabled") is True, st)
check("nothing acked before poses", st.get("acked") in ([], {}, None), st)   # an empty Lua table may come out as {}
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 1, "session": 42, "parts": "7,1,1.0,2.0,3.0,0,0,0,1,1,1,1;7,1,1.5,2.5,3.5,0,0.7071,0,0.7071,1,1,1;8,2,0,0,0,0,0,0,1,1,1,1;"})
frames(10)
st = json.loads(FILES["minecraft_native_status.json"])
check("export 1 acked after its objects were made", st.get("acked") == [1], st)
check("two objects created (two parts of export 1)", G.CREATED == 2, G.CREATED)
o1 = G.OBJECTS[1]
check("position set", o1.tr.pos is not None and abs(o1.tr.pos.x - 1.0) < 1e-6 and abs(o1.tr.pos.z - 3.0) < 1e-6)
o2 = G.OBJECTS[2]
check("rotation passed in w,x,y,z order to Quaternion.new", abs(o2.tr.rot.w - 0.7071) < 1e-6 and abs(o2.tr.rot.y - 0.7071) < 1e-6, (o2.tr.rot.w, o2.tr.rot.x, o2.tr.rot.y, o2.tr.rot.z))
check("mesh and material set", o1.mesh.m is not None and o1.mesh.mat is not None)
# the same poses again: nothing is moved (no calls into RE4); a changed pose moves only that object
G.SETS = 0
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 101, "session": 42, "parts": "7,1,1.0,2.0,3.0,0,0,0,1,1,1,1;7,1,1.5,2.5,3.5,0,0.7071,0,0.7071,1,1,1;8,2,0,0,0,0,0,0,1,1,1,1;"})
frames(3)
check("unchanged poses: no setter calls", G.SETS == 0, G.SETS)
check("unchanged poses: objects still shown", o1.draw is True and o2.draw is True)
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 102, "session": 42, "parts": "7,1,1.25,2.0,3.0,0,0,0,1,1,1,1;7,1,1.5,2.5,3.5,0,0.7071,0,0.7071,1,1,1;8,2,0,0,0,0,0,0,1,1,1,1;"})
frames(3)
check("changed pose: one object moved (3 setter calls)", G.SETS == 3, G.SETS)
check("changed pose applied", abs(o1.tr.pos.x - 1.25) < 1e-6, o1.tr.pos.x)
G.SETS = 0
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 103, "session": 42, "parts": "7,1,1.0,2.0,3.0,0,0,0,1,1,1,1;7,1,1.5,2.5,3.5,0,0.7071,0,0.7071,1,1,1;8,2,0,0,0,0,0,0,1,1,1,1;"})
frames(3)
check("moved back: setter calls again", G.SETS == 3 and abs(o1.tr.pos.x - 1.0) < 1e-6, (G.SETS, o1.tr.pos.x))
check("still two objects", G.CREATED == 2, G.CREATED)
# parts stop coming
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 2, "session": 42, "parts": ""})
frames(5)
check("hidden after Minecraft stops sending", o1.draw is False)
frames(130)
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 3, "session": 42, "parts": "9,1,0,0,0,0,0,0,1,1,1,1;"})
frames(2)
check("pooled object reused (no new object)", G.CREATED == 2, G.CREATED)
check("reused object shown again", any(o.draw for o in [o1, o2]))
check("reused object moved to its new pose", any(o.draw and abs(o.tr.pos.x) < 1e-6 and abs(o.tr.pos.z) < 1e-6 for o in [o1, o2]),
      [(o.draw, o.tr.pos.x, o.tr.pos.z) for o in [o1, o2]])
# Leon goes away (loading): forget without touching
G.LEON = False
frames(5)
check("no destroy calls while loading", G.DESTROYED == 0, G.DESTROYED)
st = json.loads(FILES["minecraft_native_status.json"])
check("nothing acked while loading", st.get("acked") in ([], {}, None), st)
G.LEON = True
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 4, "session": 42, "parts": "9,1,0,0,0,0,0,0,1,1,1,1;"})
frames(3)
check("new object after load", G.CREATED == 3, G.CREATED)
# script reset destroys
L.execute('run("reset")')
check("script reset destroys our objects", G.DESTROYED >= 1, G.DESTROYED)
st = json.loads(FILES["minecraft_native_status.json"])
check("status says off after reset", st.get("enabled") is False, st)
# Minecraft restarts: new session, id 1 now means another part
FILES["minecraft_native_assets.json"] = json.dumps({"exports": {"1": {"mesh": "minecraft/m_b.mesh", "material": "minecraft/t_a.mdf2"}}, "session": 43})
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 9, "session": 42, "parts": "9,1,0,0,0,0,0,0,1,1,1,1;"})
L.execute('run("reset")')
L.execute('CB = {}')   # like REFramework's script reset: the old copy of the script stops running
L.execute(open(sys.argv[1]).read())
frames(35)
st = json.loads(FILES["minecraft_native_status.json"])
check("status carries the new session", st.get("session") == 43, st)
before = G.CREATED
frames(3)
check("old-session poses ignored", G.CREATED == before, (before, G.CREATED))
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 10, "session": 43, "parts": "9,1,0,0,0,0,0,0,1,1,1,1;"})
frames(3)
newest = G.OBJECTS[len(G.OBJECTS)]
check("new-session part uses the new mesh", newest.mesh.m is not None and newest.mesh.m.path == "minecraft/m_b.mesh", newest.mesh.m and newest.mesh.m.path)
# Built blocks: parts with negative numbers (never an entity's), many of them standing still
objects = G.MinecraftRE4Native.state.objects
blocks = "".join(f"{-1 - i * 4096},1,{i}.0,5.0,7.0,0,0,0,1,1,1,1;" for i in range(50))
blocks += "-9223372036854775808,1,60.0,5.0,7.0,0,0,0,1,1,1,1;-5,1,61.0,5.0,7.0,0,0,0,1,1,1,1;5,1,62.0,5.0,7.0,0,0,0,1,1,1,1;"
before = G.CREATED
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 20, "session": 43, "parts": blocks})
frames(3)
check("negative ids: one object per block", G.CREATED - before == 52, G.CREATED - before)   # 53 parts, part "9" gone: its object reused
b3 = objects["-12289:1:1"]
check("negative id parsed and placed", b3 is not None and abs(b3.tr.pos.x - 3.0) < 1e-6 and abs(b3.tr.pos.z - 7.0) < 1e-6,
      b3 and (b3.tr.pos.x, b3.tr.pos.z))
lowest = objects["-9223372036854775808:1:1"]
check("lowest 64-bit block number works", lowest is not None and abs(lowest.tr.pos.x - 60.0) < 1e-6)
neg, pos = objects["-5:1:1"], objects["5:1:1"]
check("-5 and 5 are different objects", neg is not None and pos is not None and neg.go != pos.go
      and abs(neg.tr.pos.x - 61.0) < 1e-6 and abs(pos.tr.pos.x - 62.0) < 1e-6)
G.SETS = 0
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 21, "session": 43, "parts": blocks})
frames(3)
check("53 standing blocks: no setter calls", G.SETS == 0, G.SETS)
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 22, "session": 43, "parts": blocks.replace("-12289,1,3.0,5.0,7.0", "-12289,1,3.0,6.0,7.0")})
frames(3)
check("one block changed: only it is moved", G.SETS == 3 and abs(b3.tr.pos.y - 6.0) < 1e-6, (G.SETS, b3.tr.pos.y))
check("all blocks shown", G.MinecraftRE4Native.debug.shown == 53, G.MinecraftRE4Native.debug.shown)
# a malformed part (a number missing) is skipped, the others still work
before = G.CREATED
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 23, "session": 43, "parts": "-77,1,1.0,2.0,3.0,0,0,0,1,1,1;" + blocks})
frames(3)
check("malformed part ignored", objects["-77:1:1"] is None and G.MinecraftRE4Native.debug.shown == 53, G.MinecraftRE4Native.debug.shown)
# a pose that isn't all numbers (NaN from Minecraft) counts as not sent: that object is hidden and kept, not moved
G.SETS = 0
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 24, "session": 43, "parts": blocks.replace("-12289,1,3.0,5.0,7.0", "-12289,1,3.0,NaN,7.0")})
frames(3)
errors = list(G.MinecraftRE4Native.debug.errors.values())
check("non-number pose: part hidden, nothing moved", b3.go.draw is False and G.SETS == 0 and abs(b3.tr.pos.y - 5.0) < 1e-6
      and G.MinecraftRE4Native.debug.shown == 52, (b3.go.draw, G.SETS, b3.tr.pos.y, G.MinecraftRE4Native.debug.shown))
check("non-number pose: no error", not any("could not move" in str(e) for e in errors), errors)
before = G.CREATED
FILES["minecraft_native_poses.json"] = json.dumps({"seq": 25, "session": 43, "parts": blocks})
frames(3)
check("back to numbers: shown again (kept object reused, no new one)", b3.go.draw is True and G.CREATED == before
      and G.MinecraftRE4Native.debug.shown == 53, (b3.go.draw, G.CREATED - before, G.MinecraftRE4Native.debug.shown))
print("FAILS", fails)
