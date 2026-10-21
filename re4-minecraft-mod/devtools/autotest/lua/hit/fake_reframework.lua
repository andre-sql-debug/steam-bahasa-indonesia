-- Fake REFramework for running minecraft_gameplay.lua outside the game.
-- Everything the script touches is counted in FAKE.calls; set/clear look-at calls are logged in FAKE.events.

FAKE = {
    calls = 0,           -- every managed call/getter the script makes
    frame = 0,
    events = {},         -- look-at calls: { frame, kind, key, alive, in_list, destroyed, x, y, z, enemy_id }
    missing = {},        -- method name -> count (methods the script called that the fake does not have)
    files = {},          -- json.load_file name -> table
    ui_text = {},        -- imgui.text lines of the last on_draw_ui
    checkbox = {},       -- label -> forced value
    callbacks = { pre = {}, post = {}, draw = {}, reset = {}, frame = {} },
    keys_down = {},
    lookup_calls = 0,    -- get_method / get_parent_type calls
    set_fails = {},      -- enemy_id -> true: setForceLookAtTarget throws
    player_present = true,
}

local function count() FAKE.calls = FAKE.calls + 1 end

------------------------------------------------------------------ Vector3f
local V = {}
V.__index = V
local function vnew(x, y, z) return setmetatable({ x = x + 0.0, y = y + 0.0, z = z + 0.0 }, V) end
V.__add = function(a, b) return vnew(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vnew(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__unm = function(a) return vnew(-a.x, -a.y, -a.z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    if type(b) ~= "number" then error("Vector3f * non-number") end
    return vnew(a.x * b, a.y * b, a.z * b)
end
V.__tostring = function(a) return string.format("Vector3f(%g, %g, %g)", a.x, a.y, a.z) end
function V:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
Vector3f = { new = vnew }
FAKE.is_vec = function(v) return getmetatable(v) == V end

------------------------------------------------------------------ type definitions and methods
local TD = {}
TD.__index = TD
local Method = {}
Method.__index = Method

local function new_td(name, parent, methods)
    local td = setmetatable({ name = name, parent = parent, methods = {} }, TD)
    for _, m in ipairs(methods or {}) do
        local mname = m.sig:match("^([^(]+)")
        local params = {}
        local inside = m.sig:match("%((.*)%)") or ""
        for p in inside:gmatch("[^,]+") do params[#params + 1] = setmetatable({ name = p }, TD) end
        table.insert(td.methods, setmetatable({ sig = m.sig, name = mname, fn = m.fn, params = params }, Method))
    end
    return td
end
FAKE.new_td = new_td

-- Like REFramework's get_method: "name(params)" matches the signature, "name" the first with that name.
-- This fake does NOT look into parent types (the worst case for the script's own parent walk).
function TD:get_method(name)
    count(); FAKE.lookup_calls = FAKE.lookup_calls + 1
    local with_sig = name:find("(", 1, true) ~= nil
    for _, m in ipairs(self.methods) do
        if (with_sig and m.sig == name) or (not with_sig and m.name == name) then return m end
    end
    return nil
end
function TD:get_parent_type() count(); FAKE.lookup_calls = FAKE.lookup_calls + 1; return self.parent end
function TD:get_full_name() count(); return self.name end

function Method:call(obj, ...)
    count()
    return self.fn(obj, ...)
end
function Method:get_num_params() count(); return #self.params end
function Method:get_param_types() count(); return self.params end

------------------------------------------------------------------ managed objects
local Obj = {}
Obj.__index = Obj
local next_addr = 0x2A0F0000000
local function alloc() next_addr = next_addr + 0x100; return next_addr end
FAKE.alloc = alloc

local function new_obj(td, methods, addr)
    return setmetatable({ _td = td, _m = methods or {}, _addr = addr or alloc(), _fields = {} }, Obj)
end
FAKE.new_obj = new_obj

function Obj:call(name, ...)
    count()
    if self._destroyed_hard then error("access violation (destroyed object)") end
    local f = self._m[name]
    if f == nil then
        FAKE.missing[name] = (FAKE.missing[name] or 0) + 1
        error("no method " .. tostring(name))
    end
    return f(self, ...)
end
function Obj:get_address() count(); return self._addr end
function Obj:get_type_definition() count(); return self._td end
function Obj:get_field(n) count(); return self._fields[n] end
function Obj:set_field(n, v) count(); self._fields[n] = v end
function Obj:get_elements() count(); if self._elems == nil then error("not an array") end return self._elems end

------------------------------------------------------------------ globals
sdk = {}
function sdk.typeof(name) return { type_name = name } end
function sdk.game_namespace(n) return "chainsaw." .. n end
function sdk.get_managed_singleton(name) count(); return FAKE.singletons and FAKE.singletons[name] end
function sdk.get_primary_camera() count(); return nil end

re = {}
function re.on_pre_application_entry(name, fn) FAKE.callbacks.pre[name] = FAKE.callbacks.pre[name] or {}; table.insert(FAKE.callbacks.pre[name], fn) end
function re.on_application_entry(name, fn) FAKE.callbacks.post[name] = FAKE.callbacks.post[name] or {}; table.insert(FAKE.callbacks.post[name], fn) end
function re.on_pre_gui_draw_element(fn) end
function re.on_draw_ui(fn) table.insert(FAKE.callbacks.draw, fn) end
function re.on_script_reset(fn) table.insert(FAKE.callbacks.reset, fn) end
function re.on_frame(fn) table.insert(FAKE.callbacks.frame, fn) end

reframework = {}
function reframework:is_key_down(k) return FAKE.keys_down[k] == true end
function reframework:is_drawing_ui() return false end

imgui = {}
function imgui.tree_node(_) return true end
function imgui.tree_pop() end
function imgui.checkbox(label, v)
    local forced = FAKE.checkbox[label]
    if forced ~= nil then return forced ~= v, forced end
    return false, v
end
function imgui.slider_float(_, v) return false, v end
function imgui.slider_int(_, v) return false, v end
function imgui.text(t) table.insert(FAKE.ui_text, t) end
function imgui.button(label) if FAKE.buttons and FAKE.buttons[label] then FAKE.buttons[label] = nil; return true end return false end
function imgui.same_line() end
function imgui.is_mouse_down(_) return false end

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deep_copy(v) end
    return out
end
json = {}
function json.load_file(name)
    local t = FAKE.files[name]
    if t == nil then return nil end
    return deep_copy(t)
end
function json.dump_file(_, _) return true end

------------------------------------------------------------------ the RE4 world
local component_td = new_td("via.Component", new_td("via.clr.ManagedObject", new_td("System.Object", nil, {}), {}), {})
local body_common_td   -- built below with the look-at methods
local hp_td = new_td("chainsaw.HitPoint", nil, {
    { sig = "addDamage(System.Int32)", fn = function(hp, dmg)
        hp._st.hp = hp._st.hp - dmg
        FAKE.damage_log = FAKE.damage_log or {}
        table.insert(FAKE.damage_log, { frame = FAKE.frame, id = hp._st.id, dmg = dmg })
    end },
    { sig = "dead()", fn = function(hp) hp._st.live = false; hp._st.dead_called = (hp._st.dead_called or 0) + 1 end },
})

FAKE.enemies = {}        -- in list order
FAKE.enemy_by_id = {}

local function log_event(kind, st, v)
    table.insert(FAKE.events, {
        frame = FAKE.frame, kind = kind, id = st.id, key = tostring(st.addr),
        alive = st.live, in_list = st.in_list, destroyed = st.destroyed == true,
        x = v and v.x, y = v and v.y, z = v and v.z, is_vec = v ~= nil and FAKE.is_vec(v) or nil,
    })
end

body_common_td = new_td("chainsaw.Ch1c0BodyUpdaterCommon", component_td, {
    { sig = "setForceLookAtTarget(via.vec3)", fn = function(comp, v)
        local st = comp._st
        if FAKE.set_fails[st.id] then error("set failed") end
        st.looking_at = v
        log_event("set", st, v)
    end },
    { sig = "setForceLookAtTarget(System.UInt32)", fn = function(comp, n)
        log_event("set_uint", comp._st, nil)
    end },
    { sig = "clearForceLookAtTarget()", fn = function(comp)
        comp._st.looking_at = nil
        log_event("clear", comp._st, nil)
    end },
})
local body_td = new_td("chainsaw.Ch1c0z0BodyUpdater", body_common_td, {})

-- opts: { id, pos = {x,y,z}, hp = n, look = true/false, extra_comps = n, addr = n }
function FAKE.make_enemy(opts)
    local st = {
        id = opts.id, addr = opts.addr or alloc(), hp = opts.hp or 100, max = opts.hp or 100, live = true,
        pos = vnew(opts.pos[1], opts.pos[2], opts.pos[3]), in_list = true,
    }
    local hp = new_obj(hp_td, {
        get_IsLive = function() return st.live end,
        get_CurrentHitPoint = function() return st.hp end,
        get_DefaultHitPoint = function() return st.max end,
        set_CurrentHitPoint = function(_, v) st.hp = v end,
        get_Invincible = function() return false end,
        get_NoDamage = function() return false end,
        get_NoDeath = function() return false end,
        get_Immortal = function() return false end,
    })
    hp._st = st
    local comps = {}
    local n_extra = opts.extra_comps or 12
    for i = 1, n_extra do
        local depth_td = new_td("chainsaw.SomeComp" .. i, new_td("chainsaw.SomeBase" .. i, component_td, {}), {})
        local c = new_obj(depth_td, {})
        c._st = st
        comps[#comps + 1] = c
    end
    if opts.look ~= false then
        local updater = new_obj(body_td, {})
        updater._st = st
        -- the body updater sits after the transform/motion/etc. components
        table.insert(comps, math.min(#comps + 1, 8), updater)
        st.updater = updater
    end
    local comp_array = new_obj(new_td("via.Component[]", nil, {}), {})
    comp_array._elems = comps
    local body = new_obj(new_td("via.GameObject", nil, {}), {
        get_Components = function() return comp_array end,
    })
    local ctx = new_obj(new_td("chainsaw.Ch1c0z0Context", nil, {}), {
        get_BodyGameObject = function() return body end,
        get_HitPoint = function() return hp end,
        get_Position = function() return vnew(st.pos.x, st.pos.y, st.pos.z) end,
    }, st.addr)
    st.ctx, st.hp_obj, st.body = ctx, hp, body
    FAKE.enemy_by_id[opts.id] = st
    table.insert(FAKE.enemies, st)
    return st
end

function FAKE.remove_enemy(id, destroy)
    for i, st in ipairs(FAKE.enemies) do
        if st.id == id then
            table.remove(FAKE.enemies, i)
            st.in_list = false
            if destroy then st.destroyed = true end
            return st
        end
    end
end

local enemy_list = new_obj(new_td("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>", nil, {}), {
    get_Count = function() return #FAKE.enemies end,
    get_Item = function(_, i) local st = FAKE.enemies[i + 1]; if st == nil then error("index") end return st.ctx end,
})

------------------------------------------------------------------ Leon
FAKE.leon = { pos = vnew(0, 0, 0), hp = 1000, max = 1000 }
local L = FAKE.leon
local leon_transform = new_obj(new_td("via.Transform", nil, {}), {
    get_Position = function() return vnew(L.pos.x, L.pos.y, L.pos.z) end,
    set_Position = function(_, v) L.pos = vnew(v.x, v.y, v.z) end,
})
local adsorber = new_obj(new_td("chainsaw.GroundAdsorber", nil, {}), {
    set_EnabledGravity = function() end, set_EnabledCheckGround = function() end,
})
local controller = new_obj(new_td("via.physics.CharacterController", nil, {}), {
    get_DeltaTime = function() return 1 / 60 end, get_Ground = function() return true end, set_Enabled = function() end,
})
local leon_body = new_obj(new_td("via.GameObject", nil, {}), {
    get_Transform = function() return leon_transform end,
    ["getComponent(System.Type)"] = function(_, t)
        if t.type_name == "chainsaw.GroundAdsorber" then return adsorber end
        if t.type_name == "via.physics.CharacterController" then return controller end
        return nil
    end,
})
local leon_hp = new_obj(new_td("chainsaw.HitPoint", nil, {}), {
    get_DefaultHitPoint = function() return L.max end,
    get_CurrentHitPoint = function() return L.hp end,
    set_CurrentHitPoint = function(_, v) L.hp = v end,
})
local leon_ctx = new_obj(new_td("chainsaw.Ch0c0z0Context", nil, {}), {
    get_BodyGameObject = function() return leon_body end,
    get_HitPoint = function() return leon_hp end,
})
local cm = new_obj(new_td("chainsaw.CharacterManager", nil, {}), {
    getPlayerContextRef = function() if FAKE.player_present then return leon_ctx end return nil end,
    get_EnemyContextList = function() return enemy_list end,
})
FAKE.singletons = { ["chainsaw.CharacterManager"] = cm }

------------------------------------------------------------------ frame driver
FAKE.errors = {}
local function run(fns, where)
    if fns == nil then return end
    if type(fns) == "function" then fns = { fns } end
    for _, fn in ipairs(fns) do
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then table.insert(FAKE.errors, { frame = FAKE.frame, where = where, err = tostring(err) }) end
    end
end

function FAKE.step()
    FAKE.frame = FAKE.frame + 1
    FAKE.ui_text = {}
    if FAKE.before_frame then FAKE.before_frame() end
    local before = FAKE.calls
    local cb = FAKE.callbacks
    run(cb.pre["UpdateBehavior"], "pre UpdateBehavior")
    run(cb.pre["UpdatePhysicsCharacterController"], "pre UpdatePhysicsCharacterController")
    run(cb.post["UpdatePhysicsCharacterController"], "post UpdatePhysicsCharacterController")
    run(cb.post["LateUpdateBehavior"], "post LateUpdateBehavior")
    local game_calls = FAKE.calls - before
    for _, fn in ipairs(cb.draw) do run(fn, "on_draw_ui") end
    return game_calls
end

function FAKE.reset()
    for _, fn in ipairs(FAKE.callbacks.reset) do run(fn, "on_script_reset") end
end
