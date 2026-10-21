"""A stand-in for RE4 + REFramework + the overlay plugin, driving the real Minecraft client.

The real RE4 scripts (minecraft_control.lua, minecraft_terrain.lua, ...) run in a Lua 5.4 state with a fake
REFramework API and a small synthetic level (flat ground at y=5 around (100, 5, 200), a step up to y=8
beyond z=204, one enemy at (102.5, 5, 200)). Each step() is one RE4 frame: the scripts run, RE4's camera is
written into the shared overlay file like the plugin does, and the input/mouse/status files RE4 would write are
written for Minecraft.
"""
import json
import math
import mmap
import os
import struct
import time

import lupa

LUA_ENV = r'''
local V={}; V.__index=V
V.__add=function(a,b) return Vector3f.new(a.x+b.x,a.y+b.y,a.z+b.z) end
V.__sub=function(a,b) return Vector3f.new(a.x-b.x,a.y-b.y,a.z-b.z) end
V.__mul=function(a,s) return Vector3f.new(a.x*s,a.y*s,a.z*s) end
function V:length() return math.sqrt(self.x^2+self.y^2+self.z^2) end
Vector3f={new=function(x,y,z) return setmetatable({x=x,y=y,z=z},V) end}
function ground(x,z) if z > 204 then return 8 end return 5 end
function cast(a,b)
  if math.abs(a.x-b.x)<1e-6 and math.abs(a.z-b.z)<1e-6 then
    local g=ground(a.x,a.z) if a.y>=g and g>=b.y then return Vector3f.new(a.x,g,a.z) end return nil end
  if (a.z-204)*(b.z-204) < 0 and a.y < 8 then local t=(204-a.z)/(b.z-a.z) return Vector3f.new(a.x+(b.x-a.x)*t,a.y,204) end
  return nil
end
local function obj(tbl) tbl.call=function(self,m,...) local f=tbl[m] if f then return f(...) end end tbl.add_ref=function(self) return self end return tbl end
local filter=obj({})
function make_query() local q; q=obj({["setRay(via.vec3, via.vec3)"]=function(a,b) q.a=a q.b=b end, get_FilterInfo=function() return filter end}) return q end
function make_result() local r; r=obj({get_NumContactPoints=function() return r.hit and 1 or 0 end, ["getContactPoint(System.UInt32)"]=function() return {get_field=function(self,f) return r.hit end} end}) return r end
local method={call=function(self,sys,q,r) r.hit=cast(q.a,q.b) end}
LEON=Vector3f.new(100,5,200)
local Q={}; Q.__index=Q
Q.__mul=function(q,v) if q.flip then return Vector3f.new(-v.x, v.y, -v.z) end return Vector3f.new(v.x, v.y, v.z) end
Quaternion={new=function(w,x,y,z) return setmetatable({w=w,x=x,y=y,z=z},Q) end}
local IDENT=setmetatable({},Q)
local cam_tr=obj({get_Position=function() return Vector3f.new(LEON.x, LEON.y+1.5, LEON.z+4) end, get_Rotation=function() return IDENT end, set_Position=function() end, set_Rotation=function() end})
local cam_go=obj({get_Transform=function() return cam_tr end})
CAMERA=obj({get_GameObject=function() return cam_go end, get_FOV=function() return 50 end, get_VerticalEnable=function() return true end})
local function joint(dx,dy,dz) return obj({get_Position=function() return Vector3f.new(LEON.x+dx, LEON.y+dy, LEON.z+dz) end}) end
JOINTS={R_UpperArm=joint(-0.2,1.4,0), R_Hand=joint(-0.2,1.4,0.6), L_UpperArm=joint(0.2,1.4,0), L_Hand=joint(0.2,0.8,0),
        R_Thigh=joint(-0.1,0.9,0), R_Foot=joint(-0.1,0.1,0), L_Thigh=joint(0.1,0.9,0), L_Foot=joint(0.1,0.1,0)}
local tr=obj({get_Position=function() return LEON end, set_Position=function(p) LEON=p end, get_Rotation=function() return setmetatable({},getmetatable(Quaternion.new(1,0,0,0))) end, set_Rotation=function() end, getJointByName=function(n) return JOINTS[n] end})
local comp=obj({set_Enabled=function() end, set_EnabledGravity=function() end, set_EnabledCheckGround=function() end})
local body=obj({get_Transform=function() return tr end, ["getComponent(System.Type)"]=function() return comp end})
FLAGS={}
local ctx=obj({get_BodyGameObject=function() return body end})
local ctx_call=ctx.call
ctx.call=function(self,m,...) if FLAGS[m]~=nil then return FLAGS[m] end return ctx_call(self,m,...) end
ENEMY_POS=Vector3f.new(102.5,5,200)
local enemy=obj({get_Position=function() return ENEMY_POS end, get_HitPoint=function() return obj({get_CurrentHitPoint=function() return 100 end}) end})
enemy.get_address=function(self) return 123456789 end
local enemies=obj({get_Count=function() return 1 end, get_Item=function(i) return enemy end})
local cm=obj({getPlayerContextRef=function() return ctx end, get_EnemyContextList=function() return enemies end})
local layer_field={is_static=function() return true end, get_data=function() return 3 end, get_name=function() return "Terrain" end}
-- Objects the scripts make (minecraft_lights.lua): a game object with a transform and one component that keeps
-- what its setters were given
MADE={}
local function make_go(name)
  local go
  local tr=obj({set_Position=function(p) go.pos=p end})
  local comp={values={}}
  comp.call=function(self,m,v) comp.values[m]=v end
  comp.add_ref=function(self) return self end
  go=obj({name=name, draw=true, [".ctor"]=function() end, get_Transform=function() return tr end, set_DrawSelf=function(b) go.draw=b end,
          ["createComponent(System.Type)"]=function(t) go.comp=comp go.type=t return comp end,
          ["destroy(via.GameObject)"]=function() go.destroyed=true end})
  MADE[#MADE+1]=go
  return go
end
local go_create={call=function(self,_,name) return make_go(name) end}
sdk={find_type_definition=function(n) if n=="via.physics.System" then return {get_method=function() return method end} end
       if n=="via.GameObject" then return {get_method=function() return go_create end} end
       return {get_fields=function() return {layer_field} end} end,
     get_native_singleton=function() return {} end, create_instance=function(n) if n:find("Query") then return make_query() end return make_result() end,
     get_managed_singleton=function() return cm end, get_primary_camera=function() return CAMERA end, game_namespace=function(n) return "chainsaw."..n end, typeof=function(n) return n end}
json={load_file=function(f) return py_load(f) end, dump_file=function(f,t) return py_dump(f,t) end}
reframework={is_key_down=function() return false end}
draw={filled_rect=function() end, world_to_screen=function() return nil end}
imgui={get_display_size=function() return {x=1920,y=1080} end}
hooks={}
local function add(n,f) hooks[n]=hooks[n] or {} table.insert(hooks[n],f) end
re={on_pre_application_entry=function(n,f) add("pre:"..n,f) end, on_application_entry=function(n,f) add(n,f) end, on_frame=function(f) add("frame",f) end, on_draw_ui=function() end, on_script_reset=function() end}
function run(n) for _,f in ipairs(hooks[n] or {}) do f() end end
'''

# Windows virtual key codes used through the mod's key replay (RE4's keys -> Minecraft)
VK_TAB, VK_ENTER, VK_ESC, VK_T = 9, 13, 27, 84


class FakeRE4:
    def __init__(self, data_dir, scripts, width=960, height=540, fps=60):
        self.D = data_dir
        self.width, self.height, self.fps = width, height, fps
        self.L = lupa.LuaRuntime()
        g = self.L.globals()
        g.py_load = self._load
        g.py_dump = self._dump
        self.L.execute(LUA_ENV)
        for path in scripts:
            code = open(path).read()
            if path.endswith("minecraft_terrain.lua"):
                code += "\nTSTATE = state; TDEBUG = debug\n"
            self.L.execute(code)
        self._frame = self.L.eval('function() run("pre:UpdateBehavior"); run("LateUpdateBehavior"); run("pre:LockScene"); run("frame") end')
        self.fno = 0
        self.start = time.time()
        self.mouse = {"frame": 0, "x": 0, "y": 0, "left_presses": 0, "right_presses": 0, "left_releases": 0, "right_releases": 0,
                      "middle_presses": 0, "middle_releases": 0, "wheel": 0, "left": False, "right": False,
                      "minecraft_has_mouse": True, "kseq": 0, "kev": []}
        self.input = {"seq": 0, "swings": 0, "uses": 0, "perspective": 0, "yaw": 0.0, "pitch": 0.0, "selected": 0, "re4_turn": False,
                      "keys": {"w": False, "a": False, "s": False, "d": False, "jump": False, "sneak": False, "sprint": False,
                               "attack": False, "use": False}}
        self.native_status = None   # dict to write as minecraft_native_status.json, or None
        self.send_input = True
        self.shm = None
        self.cam_seq = 0
        self.yaw = 0.0
        self.pitch = 0.0
        self.fov = 60.0
        self.matched = 0
        self.tested = 0
        self.key_queue = []          # (time, kind, code)

    # ---- files ----
    def _load(self, name):
        try:
            with open(os.path.join(self.D, name)) as f:
                return self.L.table_from(json.load(f), recursive=True)
        except Exception:
            return None

    def _dump(self, name, t):
        def conv(v):
            if lupa.lua_type(v) == 'table':
                return {k: conv(v[k]) for k in list(v.keys())}
            return v
        self.write_json(name, conv(t))
        return True

    def write_json(self, name, obj):
        p = os.path.join(self.D, name)
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, p)

    def read_json(self, name):
        try:
            with open(os.path.join(self.D, name)) as f:
                return json.load(f)
        except Exception:
            return None

    def bridge(self):
        return self.read_json("minecraft_bridge.json") or {}

    def leon(self):
        p = self.L.eval("LEON")
        return (p.x, p.y, p.z)

    # ---- keys through the mod's key replay ----
    def _key(self, kind, code):
        self.mouse["kseq"] += 1
        self.mouse["kev"] = (self.mouse["kev"] + [[self.mouse["kseq"], kind, code]])[-128:]

    def tap(self, vk, char=None, at=None):
        t = at if at is not None else time.time()
        self.key_queue.append((t, 1, vk))
        if char:
            self.key_queue.append((t, 2, ord(char)))
        self.key_queue.append((t, 0, vk))

    def command(self, cmd):
        """Types a chat command (Esc, T, the text, Enter), spread over time so Minecraft sees each step."""
        t = max([time.time()] + [k[0] for k in self.key_queue]) + 0.1
        self.tap(VK_ESC, at=t)
        self.tap(VK_T, at=t + 0.6)
        for i, ch in enumerate(cmd):
            self.key_queue.append((t + 1.4, 2, ord(ch)))
        self.tap(VK_ENTER, at=t + 1.8)
        return t + 2.4   # done by then

    def respawn(self):
        t = max([time.time()] + [k[0] for k in self.key_queue]) + 0.1
        self.tap(VK_TAB, at=t)
        self.tap(VK_ENTER, at=t + 0.3)
        return t + 1.0

    # ---- the plugin's shared overlay file ----
    def _open_shm(self):
        try:
            f = open(os.path.join(self.D, "minecraft_overlay.bin"), "r+b")
            m = mmap.mmap(f.fileno(), 0)
            if struct.unpack_from("<2I", m, 0) == (0x434D3452, 2):
                self.shm = m
        except Exception:
            pass

    def _write_camera(self):
        lx, ly, lz = self.leon()
        y, p = math.radians(self.yaw), math.radians(self.pitch)
        fwd = (-math.sin(y) * math.cos(p), -math.sin(p), math.cos(y) * math.cos(p))
        struct.pack_into("<3d", self.shm, 56, lx, ly + 1.62, lz)
        struct.pack_into("<3f", self.shm, 80, *fwd)
        struct.pack_into("<f", self.shm, 44, self.fov)
        struct.pack_into("<I", self.shm, 40, 1)
        self.cam_seq += 1
        struct.pack_into("<Q", self.shm, 48, self.cam_seq)

    def _wait_match(self, max_ms=12.0):
        t0 = time.perf_counter()
        while True:
            slot = struct.unpack_from("<I", self.shm, 16)[0] & 1
            if struct.unpack_from("<Q", self.shm, 96 + slot * 8)[0] >= self.cam_seq:
                return True
            if (time.perf_counter() - t0) * 1000.0 > max_ms:
                return False
            time.sleep(0.0002)

    def overlay_picture(self):
        """The latest Minecraft picture (RGBA bytes, width, height), top row first."""
        if self.shm is None:
            return None
        w, h, slot = struct.unpack_from("<3I", self.shm, 8)
        off = 256 + (slot & 1) * 1920 * 1080 * 4
        rows = [bytes(self.shm[off + r * w * 4: off + (r + 1) * w * 4]) for r in range(h)]
        return b"".join(reversed(rows)), w, h

    # ---- one RE4 frame ----
    def step(self):
        self.fno += 1
        now = time.time()
        due = [k for k in self.key_queue if k[0] <= now]
        self.key_queue = [k for k in self.key_queue if k[0] > now]
        for _, kind, code in due:
            self._key(kind, code)
        if self.fno % 60 == 1:
            self.write_json("minecraft_overlay_plugin.json", {"beat": self.fno // 60, "ready": True,
                                                             "width": self.width, "height": self.height})
        self.mouse["frame"] = self.fno
        self.write_json("minecraft_mouse.json", self.mouse)
        if self.send_input:
            self.input["seq"] += 1
            self.input["yaw"], self.input["pitch"] = self.yaw, self.pitch
            self.write_json("minecraft_bridge_input.json", self.input)
        if self.native_status is not None and self.fno % 30 == 0:
            # like REFramework's json.dump_file, keys whose value is nil (None) are simply absent
            status = {k: v for k, v in self.native_status.items() if v is not None}
            self.write_json("minecraft_native_status.json", dict(status, frame=self.fno))
        self._frame()
        if self.shm is None:
            self._open_shm()
        if self.shm is not None:
            self._write_camera()
            ok = self._wait_match()
            self.tested += 1
            self.matched += 1 if ok else 0
        time.sleep(max(0.0, self.fno / self.fps - (time.time() - self.start)))

    def run_for(self, seconds, every=None):
        end = time.time() + seconds
        while time.time() < end:
            self.step()
            if every is not None:
                every(self)
