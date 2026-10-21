-- Extension of fake_reframework.lua for the HIT module (minecraft_gameplay.lua):
-- managed DamageInfo / AttackData with RE4's real setters (type-checked), HitControllers on enemies, Leon and a crate,
-- via.physics.Colliders with user data, sdk.find_type_definition / sdk.hook / sdk.to_managed_object / sdk.create_instance.
-- A hooked method runs its pre hooks (args = { nil, this_ptr, arg_ptr }) then the original, also when the script calls it.

local new_td, new_obj, alloc = FAKE.new_td, FAKE.new_obj, FAKE.alloc
local Obj = getmetatable(new_obj(new_td("probe", nil, {}), {}))
local is_vec = FAKE.is_vec

FAKE.by_addr = {}            -- address -> managed object (for sdk.to_managed_object)
FAKE.received = {}           -- every callbackDamageHit the HitControllers ran: { frame, hc, building, fields }
FAKE.created = {}            -- type name -> count of sdk.create_instance
FAKE.refs = {}               -- address -> add_ref count
FAKE.released = {}           -- address -> release count
FAKE.ctor_calls = {}         -- type name -> count
FAKE.clear_calls = 0
FAKE.set_errors = {}         -- setter type errors (wrong argument types)
FAKE.hook_errors = {}
FAKE.hc_throws = false       -- every callbackDamageHit throws
FAKE.ctor_throws = false     -- DamageInfo .ctor throws
FAKE.no_getters = false      -- DamageInfo has no get_Wince/get_Stopping/get_Break/get_AttackData
FAKE.no_clone = false        -- MemberwiseClone missing
FAKE.re4_damage = 0          -- HP RE4's own hit code takes inside callbackDamageHit (to see double damage)

local function remember(o) FAKE.by_addr[o._addr] = o; return o end

local orig_new_obj = new_obj
local function mk(td, methods, addr)
    return remember(orig_new_obj(td, methods, addr))
end
FAKE.mk = mk

function Obj:add_ref() FAKE.refs[self._addr] = (FAKE.refs[self._addr] or 0) + 1; return self end
function Obj:release() FAKE.released[self._addr] = (FAKE.released[self._addr] or 0) + 1 end

------------------------------------------------------------------ hooks
FAKE.hooks = {}   -- "Type::sig" -> { {pre, post}, ... }
local hc_sig = "callbackDamageHit(chainsaw.HitController.DamageInfo)"

local function run_hooked(key, this, arg, original)
    local hooks = FAKE.hooks[key] or {}
    local skip = false
    for _, h in ipairs(hooks) do
        local args = { nil, this and this._addr, arg and arg._addr }
        local ok, r = xpcall(h.pre, debug.traceback, args)
        if not ok then table.insert(FAKE.hook_errors, tostring(r)) end
        if ok and r == 1 then skip = true end   -- sdk.PreHookResult.SKIP_ORIGINAL
    end
    local ret = nil
    if not skip then ret = original() end
    for _, h in ipairs(hooks) do
        if h.post then
            local ok, r = xpcall(h.post, debug.traceback, ret)
            if not ok then table.insert(FAKE.hook_errors, tostring(r)) end
        end
    end
    return ret
end

local plain_call = Obj.call
function Obj:call(name, ...)
    if self._td and self._td.name == "chainsaw.HitController" and (name == hc_sig or name == "callbackDamageHit") then
        local args = { ... }
        return run_hooked("chainsaw.HitController::" .. hc_sig, self, args[1], function()
            return plain_call(self, name, table.unpack(args))
        end)
    end
    return plain_call(self, name, ...)
end

local hc_td = new_td("chainsaw.HitController", nil, { { sig = hc_sig, fn = function() end } })
FAKE.types = { ["chainsaw.HitController"] = hc_td }

function sdk.find_type_definition(name) return FAKE.types[name] end
function sdk.hook(method, pre, post)
    local td_name = nil
    for n, td in pairs(FAKE.types) do
        for _, m in ipairs(td.methods) do if m == method then td_name = n end end
    end
    local key = tostring(td_name) .. "::" .. method.sig
    FAKE.hooks[key] = FAKE.hooks[key] or {}
    table.insert(FAKE.hooks[key], { pre = pre, post = post })
end
function sdk.to_managed_object(p)
    if p == nil then return nil end
    return FAKE.by_addr[p]
end
sdk.PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = 1 }

-- A "real" RE4 hit: what the engine does (hooks with raw pointers, then the original)
function FAKE.real_hit(hc, info)
    return run_hooked("chainsaw.HitController::" .. hc_sig, hc, info, function()
        return plain_call(hc, hc_sig, info)
    end)
end

------------------------------------------------------------------ DamageInfo / AttackData
local attack_td = new_td("chainsaw.collision.AttackHitUserData.AttackData", nil, {})
local info_td = new_td("chainsaw.HitController.DamageInfo", nil, {})
local go_name = "via.GameObject"

local function check_arg(setter, kind, v)
    local ok
    if kind == "int" then ok = math.type(v) == "integer"
    elseif kind == "float" then ok = type(v) == "number"
    elseif kind == "bool" then ok = type(v) == "boolean"
    elseif kind == "vec3" then ok = is_vec(v)
    elseif kind == "go" then ok = type(v) == "table" and v._td ~= nil and v._td.name == go_name
    elseif kind == "attack" then ok = type(v) == "table" and v._td == attack_td
    elseif kind == "dud" then ok = type(v) == "table" and v._td ~= nil and v._td.name:find("DamageUserData", 1, true) ~= nil
    end
    if not ok then
        table.insert(FAKE.set_errors, setter .. " got " .. tostring(v))
        error(setter .. ": wrong argument type")
    end
end

local FIELDS = {
    Damage = "int", Wince = "float", Break = "float", Stopping = "float", DamageDir = "vec3",
    AttackOwnerObject = "go", IsActive = "bool", AttackData = "attack", DamageUserData = "dud",
    Position = "vec3", Normal = "vec3", DamageGameObject = "go", AttackGameObject = "go",
}
local DEFAULTS = { Damage = 0, Wince = 0.0, Break = 0.0, Stopping = 0.0, IsActive = false }

local new_info
local function info_methods()
    local m = {}
    for f, kind in pairs(FIELDS) do
        m["set_" .. f] = function(self, v) check_arg("set_" .. f, kind, v); self._f[f] = v end
        local getter = function(self) return self._f[f] end
        if f == "Wince" or f == "Stopping" or f == "Break" or f == "AttackData" then
            m["get_" .. f] = function(self)
                if FAKE.no_getters then error("no method get_" .. f) end
                return self._f[f]
            end
        else
            m["get_" .. f] = getter
        end
    end
    m[".ctor"] = function(self)
        FAKE.ctor_calls[info_td.name] = (FAKE.ctor_calls[info_td.name] or 0) + 1
        if FAKE.ctor_throws then error("ctor exploded") end
        self._f = {}
        for k, v in pairs(DEFAULTS) do self._f[k] = v end
    end
    m.clear = function(self)
        FAKE.clear_calls = FAKE.clear_calls + 1
        self._f = {}
        for k, v in pairs(DEFAULTS) do self._f[k] = v end
    end
    m.MemberwiseClone = function(self)
        if FAKE.no_clone then error("no method MemberwiseClone") end
        local c = new_info()
        for k, v in pairs(self._f) do c._f[k] = v end
        return c
    end
    return m
end
new_info = function()
    local o = mk(info_td, info_methods())
    o._f = {}
    return o
end
FAKE.new_info = new_info

local function new_attack(tag)
    local o = mk(attack_td, {
        [".ctor"] = function(self)
            FAKE.ctor_calls[attack_td.name] = (FAKE.ctor_calls[attack_td.name] or 0) + 1
            self._ctor = true
        end,
    })
    o._tag = tag
    return o
end
FAKE.new_attack = new_attack

function sdk.create_instance(name)
    FAKE.created[name] = (FAKE.created[name] or 0) + 1
    if name == info_td.name then return new_info() end
    if name == attack_td.name then return new_attack("fresh") end
    return nil
end

-- a filled DamageInfo the way RE4 would (for real hits)
function FAKE.re4_info(opts)
    local i = new_info()
    i._f = { Damage = opts.damage or 50, Wince = opts.wince or 37.5, Stopping = opts.stopping or 12.0,
        Break = opts.brk or 3.0, IsActive = true, AttackData = opts.attack or new_attack(opts.tag or "knife") }
    return i
end

------------------------------------------------------------------ HitControllers
local function snapshot(info)
    local s = {}
    if info == nil then return s end
    for k, v in pairs(info._f or {}) do s[k] = v end
    return s
end

function FAKE.new_hc(owner_go, on_hit)
    local hc
    hc = mk(hc_td, {
        get_GameObject = function() return owner_go end,
        [hc_sig] = function(self, info)
            if FAKE.hc_throws then error("native exception in callbackDamageHit") end
            local H = MinecraftRE4Hit
            table.insert(FAKE.received, { frame = FAKE.frame, hc = self, info = info, building = H and H.building,
                fields = snapshot(info), owner = owner_go })
            if info == nil then return end
            if on_hit then on_hit(info) end
        end,
    })
    return hc
end

------------------------------------------------------------------ enemies: transform, HitController, colliders, last attack
local colliders_td = new_td("via.physics.Colliders", nil, {})
local collider_td = new_td("via.physics.Collider", nil, {})
local press_ud_td = new_td("chainsaw.collision.PressUserData", nil, {})
local damage_ud_td = new_td("chainsaw.collision.DamageUserData", nil, {})
local transform_td = new_td("via.Transform", nil, {})

local orig_make_enemy = FAKE.make_enemy
-- extra opts: no_hc = true, colliders = false | list of "press"/"damage"/"nil", last_attack = true
function FAKE.make_enemy(opts)
    local st = orig_make_enemy(opts)
    remember(st.body); remember(st.ctx); remember(st.hp_obj)
    local tr = mk(transform_td, { get_Position = function() return Vector3f.new(st.pos.x, st.pos.y, st.pos.z) end })
    st.hc = (not opts.no_hc) and FAKE.new_hc(st.body, function(info)
        st.last_attack = info._f.AttackData
        if FAKE.re4_damage > 0 then st.hp = st.hp - FAKE.re4_damage end
        if FAKE.react_rule and FAKE.react_rule(info._f, st) then
            st.node = "Damage.Damage.ch1c0Damage.wince_front"
            st.motion_id = 777
            st.react_until = FAKE.frame + 25
        end
    end) or nil
    st.body._m.get_Transform = function() return tr end
    st.node = "Move.Move.ch1c0Move.general_0th_com_0000_idle_loop_verA"
    st.bank, st.motion_id = 100, 1
    local layer = mk(new_td("via.motion.TreeLayer", nil, {}), {
        get_MotionBankID = function() return st.bank end,
        get_MotionID = function() return st.motion_id end,
    })
    local motion = mk(new_td("via.motion.Motion", nil, {}), { getLayer = function(_, i) return layer end })
    local fsm = mk(new_td("via.motion.MotionFsm2", nil, {}), { getCurrentNodeName = function(_, i) return st.node end })
    st.body._m["getComponent(System.Type)"] = function(_, t)
        if t.type_name == "chainsaw.HitController" then return st.hc end
        if t.type_name == "via.motion.Motion" then return motion end
        if t.type_name == "via.motion.MotionFsm2" then return fsm end
        return nil
    end
    st.ctx._m.get_LastAttackData = function() return st.last_attack end
    if opts.last_attack then st.last_attack = new_attack("last" .. tostring(opts.id)) end
    st.uds = {}
    if opts.colliders ~= false then
        local kinds = opts.colliders or { "press", "nil", "damage", "damage" }
        local colls = {}
        for i, k in ipairs(kinds) do
            local ud = nil
            if k == "press" then ud = mk(press_ud_td, {}) elseif k == "damage" then ud = mk(damage_ud_td, {}) end
            ud = ud
            st.uds[i] = ud or false
            colls[i] = mk(collider_td, { get_UserData = function() return ud end })
        end
        local cc = mk(colliders_td, {
            get_NumColliders = function() return #colls end,
            getColliders = function(_, i) local c = colls[i + 1]; if c == nil then error("index") end return c end,
        })
        local elems = st.body._m.get_Components()._elems
        table.insert(elems, 3, cc)
    end
    return st
end

------------------------------------------------------------------ Leon and a crate get HitControllers too
local cm = FAKE.singletons["chainsaw.CharacterManager"]
local leon_ctx = cm._m.getPlayerContextRef()
local leon_body = leon_ctx._m.get_BodyGameObject()
remember(leon_body)
FAKE.leon_body = leon_body
FAKE.leon_hc = FAKE.new_hc(leon_body)
local leon_get = leon_body._m["getComponent(System.Type)"]
leon_body._m["getComponent(System.Type)"] = function(self, t)
    if t.type_name == "chainsaw.HitController" then return FAKE.leon_hc end
    return leon_get(self, t)
end
FAKE.crate_body = mk(new_td("via.GameObject", nil, {}), {})
FAKE.crate_hc = FAKE.new_hc(FAKE.crate_body)

------------------------------------------------------------------ json.dump_file stores
function json.dump_file(name, t) FAKE.files[name] = t; return true end

------------------------------------------------------------------ reactions wear off; things diagnostics needs
FAKE.before_frame = function()
    for _, st in ipairs(FAKE.enemies) do
        if st.react_until and FAKE.frame > st.react_until then
            st.react_until = nil
            st.node = "Move.Move.ch1c0Move.general_0th_com_0000_idle_loop_verA"
            st.motion_id = 1
        end
    end
end
function sdk.get_native_singleton(_) return nil end
local TDm = getmetatable(hc_td)
function TDm.get_methods(self) return self.methods end
local Mm = getmetatable(hc_td.methods[1])
function Mm.get_name(self) return self.name end
function Mm.get_return_type(self) return nil end
FAKE.buttons = {}
