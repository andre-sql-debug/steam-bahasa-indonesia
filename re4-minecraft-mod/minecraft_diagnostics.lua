-- Minecraft Diagnostics for RE4 Remake (REFramework Lua script)
-- Collects what the other Minecraft scripts need to know about this RE4 version and your setup, into
-- reframework\data\minecraft_diagnostics.json, so problems can be fixed without guessing:
--  * which RE4 methods the mod relies on exist (enemy death, Leon's state flags, camera, clock...),
--  * Leon's joint names (for your Minecraft character's arms and legs in cutscenes),
--  * enemies near Leon and their health state,
--  * who had Leon how often (minecraft_control.lua), frame rate, the latest data files,
--  * which RE4 functions run when RE4 itself hits an enemy ("Record real hits"), everything the hit carries
--    and the enemy's animations in reaction, to make enemies flinch at Minecraft hits,
--  * live tests: can RE4's own functions make an enemy look at a point, walk to it, or flinch again,
--  * how RE4's enemies pick and attack a target, and what RE4 offers for adding objects to its world
--    (so Minecraft mobs can become targets of RE4's enemies).
-- It writes a report on its own after about a minute of play; "Save report now" writes one at any time.
-- It only reads and logs; the test buttons are the only things that change the game.
-- Settings: press Insert -> Script Generated UI -> Minecraft Diagnostics

local REPORT_FILE = "minecraft_diagnostics.json"
local AUTO_REPORT_AFTER_FRAMES = 60 * 60

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, r = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return r end
    return nil
end

local function vec(v)
    if v == nil then return nil end
    local ok, t = pcall(function() return { x = v.x, y = v.y, z = v.z } end)
    return ok and t or tostring(v)
end

local log_lines = {}
local function log(s)
    table.insert(log_lines, 1, s)
    if #log_lines > 30 then table.remove(log_lines) end
end

------------------------------------------------------------------------------
-- What the mod relies on
------------------------------------------------------------------------------

local NEEDED = {
    ["chainsaw.HitPoint"] = { "dead", "addDamage", "get_CurrentHitPoint", "set_CurrentHitPoint", "get_DefaultHitPoint",
        "get_IsLive", "get_IsDead", "get_NoDeath", "get_Immortal", "get_Invincible", "get_NoDamage" },
    ["chainsaw.PlayerBaseContext"] = { "get_IsEventLocked", "get_IsLadder", "get_IsTerrainAction", "get_IsTerrainAction_Jump",
        "get_IsTerrainAction_Window", "get_IsDoorPass", "get_IsBoat", "get_IsMoveGimmickRide", "get_IsTalkActing",
        "get_IsWirelessCall", "get_IsDamaging", "get_IsInGrappleDamage", "get_IsJacked", "get_IsInsideElevator",
        "get_IsLiftActing", "get_IsHookShot", "get_BodyGameObject", "get_HitPoint" },
    ["chainsaw.CharacterContext"] = { "isGrappled", "get_HitPoint", "get_Position" },
    ["chainsaw.CharacterManager"] = { "getPlayerContextRef", "get_EnemyContextList" },
    ["via.Camera"] = { "get_FOV", "set_FOV", "get_VerticalEnable", "set_VerticalEnable" },
    ["via.Application"] = { "get_UpTimeSecond" },
    ["chainsaw.GroundAdsorber"] = { "set_EnabledGravity", "set_EnabledCheckGround" },
    ["via.physics.CharacterController"] = { "set_Enabled" },
    ["via.physics.System"] = { "castRay" },
    ["via.Transform"] = { "getJointByName", "get_Joints" },
}

local function find_method(td, name)
    -- by plain name or with a signature, also in parent types
    local depth = 0
    while td ~= nil and depth < 10 do
        for _, m in ipairs(td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            if ok and n == name then return m end
        end
        td = td:get_parent_type()
        depth = depth + 1
    end
    return nil
end

local function signature(m)
    local ok, s = pcall(function()
        local params = {}
        for _, t in ipairs(m:get_param_types() or {}) do params[#params + 1] = t and t:get_full_name() or "?" end
        local ret = m:get_return_type()
        return string.format("%s %s(%s)", ret and ret:get_full_name() or "void", m:get_name(), table.concat(params, ", "))
    end)
    return ok and s or "?"
end

local function check_methods()
    local out = {}
    for type_name, methods in pairs(NEEDED) do
        local td = sdk.find_type_definition(type_name)
        local entry = { found = td ~= nil, methods = {} }
        if td ~= nil then
            for _, name in ipairs(methods) do
                local m = find_method(td, name)
                entry.methods[name] = m and signature(m) or "MISSING"
            end
        end
        out[type_name] = entry
    end
    return out
end

-- Damage and death related members of RE4's hit system, for making enemies react to Minecraft hits
local KEYWORDS = { "damage", "dead", "death", "kill", "wince", "reaction", "direct", "attack", "stagger", "hitstop" }
local DAMAGE_TYPES = { "chainsaw.HitPoint", "chainsaw.HitController", "chainsaw.EnemyManager", "chainsaw.EnemyBaseContext",
    "chainsaw.BehaviorTreeAction_DirectDamage", "chainsaw.CharacterDamageInfo", "chainsaw.HitManager" }

local function interesting(name)
    local l = name:lower()
    for _, k in ipairs(KEYWORDS) do
        if l:find(k, 1, true) then return true end
    end
    return false
end

local function damage_members()
    local out = {}
    for _, type_name in ipairs(DAMAGE_TYPES) do
        local td = sdk.find_type_definition(type_name)
        local list = {}
        if td ~= nil then
            for _, m in ipairs(td:get_methods() or {}) do
                local ok, n = pcall(function() return m:get_name() end)
                if ok and n and interesting(n) then list[#list + 1] = signature(m) end
            end
        end
        out[type_name] = td and list or "not found"
    end
    return out
end

------------------------------------------------------------------------------
-- How enemies choose and attack targets; what RE4 offers for adding objects to its world
------------------------------------------------------------------------------

local AI_KEYWORDS = { "target", "aim", "attack", "think", "notice", "sensor", "sight", "find", "lockon", "lock_on",
    "hate", "threat", "buddy", "player", "wince", "reaction", "flinch", "stagger", "knock" }

local function ai_interesting(name)
    local l = name:lower()
    for _, k in ipairs(AI_KEYWORDS) do
        if l:find(k, 1, true) then return true end
    end
    return false
end

-- AI related members of a type and its parents (at most `limit`)
local function ai_members(td, limit)
    local out = {}
    local depth = 0
    while td ~= nil and depth < 8 and #out < limit do
        local tname = td:get_full_name()
        if tname:find("^System%.") or tname:find("^via%.clr") then break end
        for _, m in ipairs(td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            if ok and n and ai_interesting(n) and #out < limit then out[#out + 1] = tname .. " :: " .. signature(m) end
        end
        for _, f in ipairs(td:get_fields() or {}) do
            local ok, n = pcall(function() return f:get_name() end)
            if ok and n and ai_interesting(n) and #out < limit then
                local ft = f:get_type()
                out[#out + 1] = tname .. " :: field " .. (ft and ft:get_full_name() or "?") .. " " .. n
            end
        end
        td = td:get_parent_type()
        depth = depth + 1
    end
    return out
end

local SPAWN_API = {
    ["via.GameObject"] = { "create", "createComponent", "destroy", "set_DrawSelf" },
    ["via.render.Mesh"] = { "setMesh", "set_Material", "setMaterial", "getMesh", "get_Mesh" },
    ["via.Prefab"] = { "instantiate", "set_Path", "get_Path" },
    ["via.Folder"] = { "get_Path" },
    ["via.Scene"] = { "findFolder", "get_FirstTransform" },
}
local SPAWN_MANAGERS = { "chainsaw.CharacterManager", "chainsaw.SpawnManager", "chainsaw.EnemySpawnManager",
    "chainsaw.CharacterSpawnController", "chainsaw.EnemySpawnController", "chainsaw.CharacterSpawner",
    "chainsaw.SpawnController", "chainsaw.EnemyManager", "chainsaw.NpcManager", "chainsaw.BuddyManager" }

local function ai_and_spawn(enemy)
    local out = { enemy = "no enemy near Leon", spawn_api = {}, spawn_managers = {},
        create_resource = type(sdk.create_resource) == "function", create_instance = type(sdk.create_instance) == "function" }
    for type_name, methods in pairs(SPAWN_API) do
        local td = sdk.find_type_definition(type_name)
        local found = {}
        if td ~= nil then
            for _, m in ipairs(td:get_methods() or {}) do
                local ok, n = pcall(function() return m:get_name() end)
                if ok and n then
                    for _, want in ipairs(methods) do
                        if n == want then found[#found + 1] = signature(m) end
                    end
                end
            end
        end
        out.spawn_api[type_name] = td and found or "not found"
    end
    for _, name in ipairs(SPAWN_MANAGERS) do
        local td = sdk.find_type_definition(name)
        out.spawn_managers[name] = td and ai_members(td, 40) or "not found"
        if td ~= nil then
            local spawn = {}
            for _, m in ipairs(td:get_methods() or {}) do
                local ok, n = pcall(function() return m:get_name() end)
                if ok and n and (n:lower():find("spawn", 1, true) or n:lower():find("create", 1, true)) then
                    spawn[#spawn + 1] = signature(m)
                end
            end
            out.spawn_managers[name .. " (spawn)"] = spawn
        end
    end
    if enemy == nil then return out end
    local e = { context = ai_members(enemy:get_type_definition(), 120), components = {} }
    local body = try_call(enemy, "get_BodyGameObject")
    local comps = body and try_call(body, "get_Components")
    local ok, elems = pcall(function() return comps:get_elements() end)
    if ok and elems then
        for _, c in ipairs(elems) do
            local okt, td = pcall(function() return c:get_type_definition() end)
            if okt and td then
                local entry = { type = td:get_full_name(), members = ai_members(td, 40) }
                -- The enemy's model file, to know how RE4 names its meshes
                if entry.type == "via.render.Mesh" then
                    local holder = try_call(c, "getMesh") or try_call(c, "get_Mesh")
                    entry.mesh = holder and (try_call(holder, "get_ResourcePath") or try_call(holder, "ToString")) or nil
                end
                e.components[#e.components + 1] = entry
            end
        end
    end
    out.enemy = e
    return out
end

------------------------------------------------------------------------------
-- Leon, enemies, camera
------------------------------------------------------------------------------

local function player_context()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    return cm and try_call(cm, "getPlayerContextRef")
end

local function leon_info()
    local ctx = player_context()
    if ctx == nil then return "Leon not found (menu or loading)" end
    local body = try_call(ctx, "get_BodyGameObject")
    local transform = body and try_call(body, "get_Transform")
    local info = { position = vec(transform and try_call(transform, "get_Position")), joints = {} }
    local joints = transform and try_call(transform, "get_Joints")
    local ok, list = pcall(function() return joints:get_elements() end)
    if ok and list then
        for _, j in ipairs(list) do
            local okn, n = pcall(function() return j:call("get_Name") end)
            if okn and n then info.joints[#info.joints + 1] = n end
        end
    end
    info.joint_count = #info.joints
    return info
end

local function hp_state(hp)
    if hp == nil then return "no HitPoint" end
    return {
        current = try_call(hp, "get_CurrentHitPoint"), max = try_call(hp, "get_DefaultHitPoint"),
        live = try_call(hp, "get_IsLive"), dead = try_call(hp, "get_IsDead"),
        invincible = try_call(hp, "get_Invincible"), no_damage = try_call(hp, "get_NoDamage"),
        no_death = try_call(hp, "get_NoDeath"), immortal = try_call(hp, "get_Immortal"),
    }
end

local function nearest_enemies(limit)
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local ctx = player_context()
    local body = ctx and try_call(ctx, "get_BodyGameObject")
    local me = body and try_call(try_call(body, "get_Transform"), "get_Position")
    local all = {}
    for i = 0, count - 1 do
        local e = try_call(list, "get_Item", i)
        local pos = e and try_call(e, "get_Position")
        local d = (pos ~= nil and me ~= nil) and (pos - me):length() or math.huge
        all[#all + 1] = { e = e, d = d, pos = pos }
    end
    table.sort(all, function(a, b) return a.d < b.d end)
    local out = { count = count, nearest = {} }
    for i = 1, math.min(limit, #all) do
        local a = all[i]
        local ok, tn = pcall(function() return a.e:get_type_definition():get_full_name() end)
        out.nearest[#out.nearest + 1] = { type = ok and tn or "?", distance = a.d, position = vec(a.pos),
            hit_point = hp_state(try_call(a.e, "get_HitPoint")) }
    end
    return out, all[1] and all[1].e or nil
end

local function camera_info()
    local camera = sdk.get_primary_camera()
    if camera == nil then return "no camera" end
    return { fov = try_call(camera, "get_FOV"), vertical = try_call(camera, "get_VerticalEnable") }
end

------------------------------------------------------------------------------
-- Who had Leon, frame rate, RE4 UI elements (collected while playing)
------------------------------------------------------------------------------

local frames, leon_frames = 0, 0
local mode_counts = {}
local fps = { last_time = nil, frames = 0, value = nil, min = nil }
local gui_names = {}
local uptime_method = nil
pcall(function() uptime_method = sdk.find_type_definition("via.Application"):get_method("get_UpTimeSecond") end)
local function now_seconds()
    local app = sdk.get_native_singleton("via.Application")
    if uptime_method ~= nil and app ~= nil then
        local ok, t = pcall(function() return uptime_method:call(app) end)
        if ok and type(t) == "number" then return t end
    end
    return os.clock()
end

local reported = false
local report_now = false
local write_report   -- defined below

re.on_pre_application_entry("UpdateBehavior", function()
    frames = frames + 1
    local c = MinecraftRE4Control
    if type(c) == "table" and c.mode ~= nil then
        local key = tostring(c.mode) .. " (" .. tostring(c.reason) .. ")"
        mode_counts[key] = (mode_counts[key] or 0) + 1
    end
    if player_context() ~= nil then leon_frames = leon_frames + 1 end

    local t = now_seconds()
    fps.frames = fps.frames + 1
    if fps.last_time == nil then fps.last_time = t end
    if t - fps.last_time >= 1.0 then
        fps.value = fps.frames / (t - fps.last_time)
        if fps.min == nil or fps.value < fps.min then fps.min = fps.value end
        fps.frames, fps.last_time = 0, t
    end

    if (not reported and leon_frames >= AUTO_REPORT_AFTER_FRAMES) or report_now then
        reported = true
        report_now = false
        local ok, err = pcall(write_report)
        log(ok and ("report written: reframework\\data\\" .. REPORT_FILE) or ("report failed: " .. tostring(err)))
    end
end)

re.on_pre_gui_draw_element(function(element, context)
    local ok, name = pcall(function() return element:call("get_GameObject"):call("get_Name") end)
    if ok and name then gui_names[name] = (gui_names[name] or 0) + 1 end
    return true
end)

------------------------------------------------------------------------------
-- Record real hits: which RE4 functions run when RE4 itself damages an enemy, everything the hit carries
-- (chainsaw.HitController.DamageInfo), and which animations the enemy plays in reaction
------------------------------------------------------------------------------

-- The hit functions worth logging. Plain getters and setters are left out on purpose: many of them share
-- one piece of machine code, so hooking one would log all of them (and they run all the time).
local HIT_HOOKS = {
    ["chainsaw.HitController"] = { "callbackDamageHit", "callbackAttackHit", "callbackCheckDamageHit",
        "callbackCalculateDamage", "callbackCalculateDamageByAttacker", "setDamageCalcInfo", "poolDamage",
        "checkKill", "playDamageEffect", "playDamageSe", "requestAttack" },
    ["chainsaw.HitPoint"] = { "addDamage", "checkDead", "dead" },
    ["chainsaw.EnemyManager"] = { "notifyHitDamage", "notifyDead" },
    ["chainsaw.HitManager"] = { "registerDamage", "calcDamageDir" },
}

local recording = false
local hook_counts = {}
local hook_args = {}
local hooked = {}
local captures = {}        -- the first hits while recording: who was hit and every field of the DamageInfo
local motion_log = {}      -- the nearest enemy's animation/state changes while recording, with the hits
local replay = nil         -- the last hit on an enemy: { hc, info (a copy), body_address, frame }
local replaying = false    -- the flinch test is calling callbackDamageHit itself (not a real hit)
local MAX_CAPTURES = 4
local MAX_MOTION_LOG = 300
local last_motion_key = nil

local motion_type = sdk.typeof("via.motion.Motion")
local fsm_type = sdk.typeof("via.motion.MotionFsm2")
local hit_controller_type = sdk.typeof("chainsaw.HitController")

local function arg_types(args)
    local out = {}
    for i = 2, 6 do
        local ok, s = pcall(function()
            local o = sdk.to_managed_object(args[i])
            return o and o:get_type_definition():get_full_name() or "-"
        end)
        out[#out + 1] = ok and s or "?"
    end
    return table.concat(out, ", ")
end

local function address_of(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

-- Every field of a managed object (and of the game's objects it holds, one level deep), as text and numbers
local dump_fields
local function value_of(v, depth)
    local t = type(v)
    if v == nil then return "nil" end
    if t == "number" or t == "boolean" or t == "string" then return v end
    local okv, vs = pcall(function() return string.format("(%.3f, %.3f, %.3f)", v.x, v.y, v.z) end)
    if okv then return vs end
    local okt, tn = pcall(function() return v:get_type_definition():get_full_name() end)
    if okt and tn ~= nil then
        if depth < 1 and tn:find("^chainsaw%.") then return { type = tn, fields = dump_fields(v, depth + 1) } end
        return tn
    end
    return tostring(v)
end

dump_fields = function(obj, depth)
    local out = {}
    local okt, td = pcall(function() return obj:get_type_definition() end)
    local level = 0
    while okt and td ~= nil and level < 10 do
        local tname = td:get_full_name()
        if tname == "System.Object" or tname == "System.ValueType" then break end
        for _, f in ipairs(td:get_fields() or {}) do
            local okf, name, static = pcall(function() return f:get_name(), f:is_static() end)
            if okf and not static then
                local okv, v = pcall(function() return f:get_data(obj) end)
                local okft, ft = pcall(function() return f:get_type():get_full_name() end)
                local value = "?"
                if okv then value = value_of(v, depth) end   -- (okv and value_of(...) or "?") turns false into "?"
                out[#out + 1] = { name = name, type = okft and ft or "?", value = value }
            end
        end
        local okp, parent = pcall(function() return td:get_parent_type() end)
        td = okp and parent or nil
        level = level + 1
    end
    return out
end

-- The animation an enemy is playing (bank/motion numbers) and its behavior state, as one line
local function motion_state(enemy)
    local body = try_call(enemy, "get_BodyGameObject")
    if body == nil then return "no body" end
    local parts = {}
    local motion = motion_type and try_call(body, "getComponent(System.Type)", motion_type)
    local layer = motion and try_call(motion, "getLayer", 0)
    if layer ~= nil then
        parts[#parts + 1] = string.format("motion %s/%s", tostring(try_call(layer, "get_MotionBankID")),
            tostring(try_call(layer, "get_MotionID")))
    end
    local fsm = fsm_type and try_call(body, "getComponent(System.Type)", fsm_type)
    if fsm ~= nil then
        local node = try_call(fsm, "getCurrentNodeName", 0)
        if node ~= nil then parts[#parts + 1] = "state " .. tostring(node) end
    end
    return #parts > 0 and table.concat(parts, ", ") or "no motion info"
end

local function note_motion(text)
    if #motion_log < MAX_MOTION_LOG then motion_log[#motion_log + 1] = string.format("[%d] %s", frames, text) end
end

-- A hit landed on someone (callbackDamageHit runs on the HitController of whoever was hit)
local function on_damage_hit(args)
    local hc = sdk.to_managed_object(args[2])
    local info = sdk.to_managed_object(args[3])
    if hc == nil or info == nil then return end
    local go = try_call(hc, "get_GameObject")
    local name = go and try_call(go, "get_Name") or "?"
    local ctx = player_context()
    local leon_body = ctx and try_call(ctx, "get_BodyGameObject")
    local on_leon = leon_body ~= nil and go ~= nil and address_of(leon_body) == address_of(go)
    note_motion("HIT on " .. tostring(name) .. (on_leon and " (Leon)" or ""))
    if #captures < MAX_CAPTURES then
        captures[#captures + 1] = { frame = frames, hit = tostring(name), on_leon = on_leon, fields = dump_fields(info, 0) }
    end
    -- Only hits on enemies arm the flinch test (not Leon, crates or other objects)
    local on_enemy = false
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local hit_address = address_of(go)
    for i = 0, count - 1 do
        local e = try_call(list, "get_Item", i)
        local b = e and try_call(e, "get_BodyGameObject")
        if b ~= nil and hit_address ~= nil and address_of(b) == hit_address then on_enemy = true end
    end
    if on_enemy then
        -- Keep a copy for the flinch test (RE4 may reuse the original for its next hit)
        local okc, copy = pcall(function() return info:call("MemberwiseClone") end)
        if okc and copy ~= nil then
            pcall(function() copy:add_ref() end)
            pcall(function() hc:add_ref() end)
            replay = { hc = hc, info = copy, body_address = address_of(go), name = tostring(name), frame = frames }
        end
    end
end

local function hook_all()
    for type_name, names in pairs(HIT_HOOKS) do
        local td = sdk.find_type_definition(type_name)
        for _, m in ipairs(td and td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            local wanted = false
            for _, w in ipairs(names) do
                if n == w then wanted = true end
            end
            local okp, params = pcall(function() return m:get_num_params() end)
            local key = type_name .. "." .. tostring(n) .. "/" .. tostring(okp and params or "?")
            if ok and wanted and not hooked[key] then
                hooked[key] = true
                local is_damage_hit = type_name == "chainsaw.HitController" and n == "callbackDamageHit"
                pcall(function()
                    sdk.hook(m, function(args)
                        if not recording or replaying then return end
                        hook_counts[key] = (hook_counts[key] or 0) + 1
                        if hook_args[key] == nil then hook_args[key] = arg_types(args) end
                        if is_damage_hit then pcall(on_damage_hit, args) end
                    end, function(retval) return retval end)
                end)
            end
        end
    end
end

------------------------------------------------------------------------------
-- Tests on the nearest enemy (they change the game: only when you press them)
------------------------------------------------------------------------------

local test_results = {}
local pending_test = nil

local function nearest_live_enemy()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local ctx = player_context()
    local body = ctx and try_call(ctx, "get_BodyGameObject")
    local me = body and try_call(try_call(body, "get_Transform"), "get_Position")
    local best, best_d = nil, math.huge
    for i = 0, count - 1 do
        local e = try_call(list, "get_Item", i)
        local hp = e and try_call(e, "get_HitPoint")
        local pos = e and try_call(e, "get_Position")
        if pos ~= nil and me ~= nil and hp ~= nil and try_call(hp, "get_IsLive") == true then
            local d = (pos - me):length()
            if d < best_d then best, best_d = e, d end
        end
    end
    return best, me
end

local function run_test(kind)
    local _, enemy = nearest_enemies(1)
    local hp = enemy and try_call(enemy, "get_HitPoint")
    if hp == nil then
        log("test: no enemy near")
        return
    end
    local before = hp_state(hp)
    local max = try_call(hp, "get_DefaultHitPoint") or 0
    local cur = try_call(hp, "get_CurrentHitPoint") or 0
    local err = nil
    if kind == "quarter" then
        try_call(hp, "set_CurrentHitPoint", math.max(1, cur - math.max(1, math.floor(max / 4))))
    elseif kind == "kill" then
        try_call(hp, "set_CurrentHitPoint", 0)
        local ok, e = pcall(function() hp:call("dead") end)
        if not ok then err = tostring(e) end
    end
    local result = { test = kind, before = before, after = hp_state(hp), error = err }
    test_results[#test_results + 1] = result
    log(string.format("test %s: HP %s -> %s, alive %s -> %s%s", kind, tostring(before.current),
        tostring(result.after.current), tostring(before.live), tostring(result.after.live), err and (" error " .. err) or ""))
end

------------------------------------------------------------------------------
-- Live tests: can RE4's own functions make an enemy look at, walk to, or flinch from something else?
-- Each runs for a few seconds on the nearest living enemy and measures what happened by itself.
------------------------------------------------------------------------------

local live = nil           -- the running test
local live_results = {}
local LOOK_BASE_FRAMES, LOOK_FRAMES = 45, 90
local WALK_BASE_FRAMES, WALK_FRAMES = 60, 180
local FLINCH_BASE_FRAMES, FLINCH_FRAMES = 45, 90

-- A look test must never leave the enemy staring at its point
local function release_look()
    if live ~= nil and live.kind == "look" then
        for _, h in ipairs(live.handles or {}) do
            if h.second then pcall(function() h.second:call(h.comp) end) end
        end
    end
end

local function find_method_in(td, name)
    local depth = 0
    while td ~= nil and depth < 12 do
        local ok, m = pcall(function() return td:get_method(name) end)
        if ok and m ~= nil then return m end
        local okp, parent = pcall(function() return td:get_parent_type() end)
        td = okp and parent or nil
        depth = depth + 1
    end
    return nil
end

-- Components of the enemy's body that have this method: { { comp, method, type } ... }
local function components_with(enemy, signature, second)
    local out = {}
    local body = try_call(enemy, "get_BodyGameObject")
    local comps = body and try_call(body, "get_Components")
    local ok, elems = pcall(function() return comps:get_elements() end)
    if not ok or elems == nil then return out end
    for _, comp in ipairs(elems) do
        local okt, td = pcall(function() return comp:get_type_definition() end)
        if okt and td ~= nil then
            local m = find_method_in(td, signature)
            if m ~= nil then
                out[#out + 1] = { comp = comp, method = m, second = second and find_method_in(td, second) or nil,
                    type = td:get_full_name() }
            end
        end
    end
    return out
end

local function q_rotate(q, v)
    -- v rotated by the unit quaternion q
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    local tx = 2 * (qy * v.z - qz * v.y)
    local ty = 2 * (qz * v.x - qx * v.z)
    local tz = 2 * (qx * v.y - qy * v.x)
    return { x = v.x + qw * tx + (qy * tz - qz * ty), y = v.y + qw * ty + (qz * tx - qx * tz),
        z = v.z + qw * tz + (qx * ty - qy * tx) }
end

local AXES = { { x = 1, y = 0, z = 0 }, { x = -1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = -1, z = 0 },
    { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = -1 } }

local function cos_to(dir, from, to)
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 0.01 then return 0 end
    return (dir.x * dx + dir.y * dy + dir.z * dz) / len
end

local function enemy_head(enemy)
    local body = try_call(enemy, "get_BodyGameObject")
    local tr = body and try_call(body, "get_Transform")
    for _, name in ipairs({ "Head", "head", "Neck_1", "Neck_0" }) do
        local j = tr and try_call(tr, "getJointByName", name)
        if j ~= nil then return j, name end
    end
    return nil
end

-- A point beside the enemy (perpendicular to the line to Leon), at head height
local function side_point(epos, me, distance, height)
    local dx, dz = me.x - epos.x, me.z - epos.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then dx, dz, len = 1, 0, 1 end
    return Vector3f.new(epos.x - dz / len * distance, epos.y + height, epos.z + dx / len * distance)
end

local function start_live(kind)
    if live ~= nil then log("a test is already running") return end
    local enemy, me = nearest_live_enemy()
    if enemy == nil or me == nil then log("live test: no living enemy near Leon") return end
    local epos = try_call(enemy, "get_Position")
    local okt, etype = pcall(function() return enemy:get_type_definition():get_full_name() end)
    live = { kind = kind, enemy = enemy, frame = 0, result = { test = kind, enemy = okt and etype or "?" } }
    local r = live.result
    if kind == "look" then
        live.handles = components_with(enemy, "setForceLookAtTarget(via.vec3)", "clearForceLookAtTarget")
        live.head, r.head_joint = enemy_head(enemy)
        live.target = side_point(epos, me, 3.0, 1.6)
        live.samples = {}
        r.components = {}
        for _, h in ipairs(live.handles) do r.components[#r.components + 1] = h.type end
        if #live.handles == 0 then r.result = "no component with setForceLookAtTarget(via.vec3)" end
        if live.head == nil then r.result = (r.result and (r.result .. "; ") or "") .. "no head joint" end
    elseif kind == "walk" then
        live.handles = components_with(enemy, "set_TargetPos(via.vec3)")
        live.target = side_point(epos, me, 4.0, 0.0)
        live.start = epos
        live.leon_start = me
        live.path = {}
        r.components = {}
        for _, h in ipairs(live.handles) do r.components[#r.components + 1] = h.type end
        if #live.handles == 0 then r.result = "no component with set_TargetPos(via.vec3)" end
    elseif kind == "flinch" then
        local body = try_call(enemy, "get_BodyGameObject")
        if replay == nil then
            r.result = "no recorded hit: Start recording, hit an enemy once with the knife, then press this"
        elseif address_of(body) ~= replay.body_address then
            -- replay on the enemy that was really hit (its own colliders and joints), if it is still alive
            local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
            local list = cm and try_call(cm, "get_EnemyContextList")
            local count = list and try_call(list, "get_Count") or 0
            local found = nil
            for i = 0, count - 1 do
                local e = try_call(list, "get_Item", i)
                local b = e and try_call(e, "get_BodyGameObject")
                local hp = e and try_call(e, "get_HitPoint")
                if b ~= nil and address_of(b) == replay.body_address and hp ~= nil and try_call(hp, "get_IsLive") == true then found = e end
            end
            if found == nil then
                r.result = "the enemy you hit while recording is dead or gone: record a hit on a living one"
            else
                live.enemy = found
                okt, etype = pcall(function() return found:get_type_definition():get_full_name() end)
                r.enemy = okt and etype or "?"
            end
        end
        r.replayed_hit = replay and replay.name or nil
        live.changes = {}
    end
    if r.result ~= nil then
        live_results[#live_results + 1] = r
        log("live test " .. kind .. ": " .. r.result)
        live = nil
        report_now = true
        return
    end
    log("live test " .. kind .. " running on " .. r.enemy .. "...")
end

local function finish_live()
    local r = live.result
    live_results[#live_results + 1] = r
    log("live test " .. live.kind .. ": " .. tostring(r.result))
    live = nil
    report_now = true
end

-- One frame of the running test (before RE4's behavior update)
local function step_live()
    local t = live
    t.frame = t.frame + 1
    local enemy = t.enemy
    local hp = try_call(enemy, "get_HitPoint")
    if hp == nil or try_call(hp, "get_IsLive") ~= true then
        t.result.result = string.format("stopped: the enemy died or went away at frame %d", t.frame)
        if t.kind == "look" then
            for _, h in ipairs(t.handles) do if h.second then pcall(function() h.second:call(h.comp) end) end end
        end
        finish_live()
        return
    end
    local epos = try_call(enemy, "get_Position")
    local ctx = player_context()
    local lbody = ctx and try_call(ctx, "get_BodyGameObject")
    local me = lbody and try_call(try_call(lbody, "get_Transform"), "get_Position")

    if t.kind == "look" then
        -- First a while without forcing (does the head follow Leon?), then forced toward a point beside the enemy
        local forcing = t.frame > LOOK_BASE_FRAMES
        if forcing then
            for _, h in ipairs(t.handles) do
                local ok, err = pcall(function() h.method:call(h.comp, t.target) end)
                if not ok and t.result.error == nil then t.result.error = tostring(err) end
            end
        end
        local q = try_call(t.head, "get_Rotation")
        local hpos = try_call(t.head, "get_Position")
        if q ~= nil and hpos ~= nil and me ~= nil then
            t.samples[#t.samples + 1] = { forcing = forcing, q = { x = q.x, y = q.y, z = q.z, w = q.w },
                head = { x = hpos.x, y = hpos.y, z = hpos.z }, leon = { x = me.x, y = me.y + 1.6, z = me.z } }
        end
        if t.frame >= LOOK_BASE_FRAMES + LOOK_FRAMES then
            for _, h in ipairs(t.handles) do if h.second then pcall(function() h.second:call(h.comp) end) end end
            -- Which head axis points where the enemy looks: the one best aimed at Leon before forcing
            local best_axis, best_score = nil, -math.huge
            for ai, axis in ipairs(AXES) do
                local sum, n = 0, 0
                for _, s in ipairs(t.samples) do
                    if not s.forcing then sum = sum + cos_to(q_rotate(s.q, axis), s.head, s.leon); n = n + 1 end
                end
                if n > 0 and sum / n > best_score then best_axis, best_score = ai, sum / n end
            end
            local to_target, to_leon, n = 0, 0, 0
            local base_target, nb = 0, 0
            for _, s in ipairs(t.samples) do
                if best_axis ~= nil then
                    local dir = q_rotate(s.q, AXES[best_axis])
                    if s.forcing then
                        to_target = to_target + cos_to(dir, s.head, t.target)
                        to_leon = to_leon + cos_to(dir, s.head, s.leon)
                        n = n + 1
                    else
                        base_target = base_target + cos_to(dir, s.head, t.target)
                        nb = nb + 1
                    end
                end
            end
            t.result.head_axis = best_axis
            t.result.before_aim_at_leon = best_axis and best_score or nil
            t.result.before_aim_at_target = nb > 0 and base_target / nb or nil
            t.result.forced_aim_at_target = n > 0 and to_target / n or nil
            t.result.forced_aim_at_leon = n > 0 and to_leon / n or nil
            if best_axis == nil or best_score < 0.8 then
                t.result.result = "can't tell: the enemy was not looking at Leon before the test (let it see you, run it again)"
            elseif n > 0 and nb > 0 and to_target / n - base_target / nb > 0.3 then
                t.result.result = "the head turned to the point (look-at works)"
            else
                t.result.result = "the head did not clearly turn to the point"
            end
            finish_live()
        end
    elseif t.kind == "walk" then
        local forcing = t.frame > WALK_BASE_FRAMES
        if forcing then
            for _, h in ipairs(t.handles) do
                local ok, err = pcall(function() h.method:call(h.comp, t.target) end)
                if not ok and t.result.error == nil then t.result.error = tostring(err) end
            end
        end
        if epos ~= nil then t.path[#t.path + 1] = { forcing = forcing, x = epos.x, y = epos.y, z = epos.z } end
        if t.frame >= WALK_BASE_FRAMES + WALK_FRAMES then
            local function dist(p, q) return math.sqrt((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2) end
            local first_forced, last = nil, t.path[#t.path]
            for _, p in ipairs(t.path) do if p.forcing then first_forced = p break end end
            t.result.target_distance_start = first_forced and dist(first_forced, t.target) or nil
            t.result.target_distance_end = last and dist(last, t.target) or nil
            t.result.moved = (first_forced and last) and dist(first_forced, last) or nil
            t.result.leon_distance_end = (last and me) and dist(last, me) or nil
            local closer = (t.result.target_distance_start or 0) - (t.result.target_distance_end or 0)
            local b1, b2 = nil, nil
            for _, p in ipairs(t.path) do if not p.forcing then b1 = b1 or p; b2 = p end end
            local by_itself = (b1 and b2) and (dist(b1, t.target) - dist(b2, t.target)) * WALK_FRAMES / WALK_BASE_FRAMES or 0
            t.result.closer_by_itself = by_itself
            t.result.leon_moved = (t.leon_start and me) and dist(t.leon_start, me) or nil
            if (t.result.leon_moved or 0) > 1.0 then
                t.result.result = "can't tell: Leon moved during the test (stand still, run it again)"
            else
                t.result.result = (closer > 1.5 and closer - by_itself > 1.5)
                    and "the enemy walked toward the point (navigation target works)" or "the enemy did not walk to the point"
            end
            finish_live()
        end
    elseif t.kind == "flinch" then
        -- First a while without the hit (does its animation change by itself?), then the replayed hit
        local state = motion_state(enemy)
        local f = t.frame - FLINCH_BASE_FRAMES   -- frames since the replayed hit
        if t.frame == 1 then
            t.last_state, t.base_changes = state, 0
        elseif f < 1 and state ~= t.last_state then
            t.base_changes = t.base_changes + 1
            t.last_state = state
        end
        if f == 1 then
            t.result.hp_before = try_call(hp, "get_CurrentHitPoint")
            t.result.motion_before = state
            t.last_state = state
            -- full health for the replay so it can't kill the enemy (its own health comes back at the end)
            t.max = try_call(hp, "get_DefaultHitPoint")
            if t.max ~= nil then try_call(hp, "set_CurrentHitPoint", t.max) end
            replaying = true
            local ok, err = pcall(function() replay.hc:call("callbackDamageHit(chainsaw.HitController.DamageInfo)", replay.info) end)
            replaying = false
            t.result.call = ok and "called" or ("failed: " .. tostring(err))
            t.result.hp_after_call = try_call(hp, "get_CurrentHitPoint")
        elseif f > 1 and state ~= t.last_state then
            t.changes[#t.changes + 1] = string.format("[%d] %s", f, state)
            t.last_state = state
        end
        if f >= 1 and t.max ~= nil then
            -- RE4 may apply the damage a few frames later: keep the enemy alive until the end
            local now = try_call(hp, "get_CurrentHitPoint")
            if now ~= nil and now < t.max then
                t.result.damage_seen = math.max(t.result.damage_seen or 0, t.max - now)
                try_call(hp, "set_CurrentHitPoint", t.max)
            end
        end
        if f >= FLINCH_FRAMES then
            if t.result.hp_before ~= nil then try_call(hp, "set_CurrentHitPoint", t.result.hp_before) end
            t.result.motion_changes = t.changes
            t.result.changes_before_replay = t.base_changes
            local quick = false
            for _, c in ipairs(t.changes) do
                local n = tonumber(c:match("^%[(%d+)%]"))
                if n ~= nil and n <= 10 then quick = true end
            end
            if not quick then
                t.result.result = "no animation change right after the replayed hit"
            elseif t.base_changes == 0 then
                t.result.result = "the enemy's animation changed right after the replayed hit (it reacted)"
            else
                t.result.result = "the animation changed after the replayed hit, but it also changed by itself before (watch: did it flinch?)"
            end
            finish_live()
        end
    end
end

re.on_pre_application_entry("UpdateBehavior", function()
    -- No Leon (loading, title screen): the recorded hit's enemy and objects may be gone, never replay it,
    -- and a running test stops without touching its enemy again
    if (replay ~= nil or live ~= nil) and player_context() == nil then
        replay = nil
        if live ~= nil then
            live.result.result = "stopped: Leon went away (loading or menu)"
            live_results[#live_results + 1] = live.result
            live = nil
        end
    end
    if pending_test ~= nil then
        local k = pending_test
        pending_test = nil
        if k == "look" or k == "walk" or k == "flinch" then
            local ok, e = pcall(start_live, k)
            if not ok then log("live test error: " .. tostring(e)); live = nil end
        else
            local ok, e = pcall(run_test, k)
            if not ok then log("test error: " .. tostring(e)) end
        end
    end
    if live ~= nil then
        local ok, e = pcall(step_live)
        if not ok then
            log("live test error: " .. tostring(e))
            if live ~= nil then
                release_look()
                live.result.result = "error: " .. tostring(e)
                live_results[#live_results + 1] = live.result
                live = nil
            end
        end
    end
    -- While recording: the nearest enemy's animation/state changes, next to the hits
    if recording and frames % 2 == 0 then
        local enemy = nearest_live_enemy()
        if enemy ~= nil then
            local state = motion_state(enemy)
            local ok, address = pcall(function() return enemy:get_address() end)
            local key = (ok and tostring(address) or "?") .. " " .. state
            if key ~= last_motion_key then
                last_motion_key = key
                note_motion(state)
            end
        end
    end
end)

re.on_script_reset(release_look)

-- The walk test also sets the target late in the frame, after RE4's own behavior had its say
re.on_application_entry("LateUpdateBehavior", function()
    if live ~= nil and live.kind == "walk" and live.frame > WALK_BASE_FRAMES then
        for _, h in ipairs(live.handles) do pcall(function() h.method:call(h.comp, live.target) end) end
    end
end)

------------------------------------------------------------------------------
-- Every member of the types a hit and a reaction are made of (for building them for Minecraft hits)
------------------------------------------------------------------------------

local FULL_TYPES = { "chainsaw.HitController.DamageInfo", "chainsaw.HitController.DamageValue",
    "chainsaw.HitController.CalculateInfo", "chainsaw.collision.AttackHitUserData.AttackData",
    "chainsaw.collision.HitInfo", "chainsaw.LookAtRequest", "via.motion.TreeLayer" }
local KEYWORD_TYPES = {
    ["via.behaviortree.BehaviorTree"] = { "node", "layer", "tree" },
    ["via.motion.Motion"] = { "layer", "motion", "bank" },
    ["chainsaw.Ch1c0BodyUpdaterCommon"] = { "damage", "wince", "react", "flinch", "stagger", "knock", "down", "stun",
        "hit", "rotate", "turn", "attack", "target", "look" },
    ["chainsaw.EnemyBodyUpdater"] = { "damage", "wince", "react", "flinch", "stagger", "knock", "down", "stun", "hit",
        "rotate", "turn", "attack", "target", "look" },
    ["chainsaw.CharacterBodyUpdater"] = { "damage", "wince", "react", "hit", "attack", "target", "look" },
}

local function members(td, keywords, limit)
    local out = {}
    local depth = 0
    while td ~= nil and depth < 8 and #out < limit do
        local tname = td:get_full_name()
        if tname:find("^System%.") or tname:find("^via%.clr") then break end
        local function wanted(n)
            if keywords == nil then return true end
            local l = n:lower()
            for _, k in ipairs(keywords) do if l:find(k, 1, true) then return true end end
            return false
        end
        for _, m in ipairs(td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            if ok and n and wanted(n) and #out < limit then out[#out + 1] = tname .. " :: " .. signature(m) end
        end
        for _, f in ipairs(td:get_fields() or {}) do
            local ok, n = pcall(function() return f:get_name() end)
            if ok and n and wanted(n) and #out < limit then
                local ft = f:get_type()
                out[#out + 1] = tname .. " :: field " .. (ft and ft:get_full_name() or "?") .. " " .. n
            end
        end
        local okp, parent = pcall(function() return td:get_parent_type() end)
        td = okp and parent or nil
        depth = depth + 1
    end
    return out
end

local function type_dumps()
    local out = {}
    for _, name in ipairs(FULL_TYPES) do
        local td = sdk.find_type_definition(name)
        out[name] = td and members(td, nil, 300) or "not found"
    end
    for name, keywords in pairs(KEYWORD_TYPES) do
        local td = sdk.find_type_definition(name)
        out[name] = td and members(td, keywords, 250) or "not found"
    end
    return out
end

------------------------------------------------------------------------------
-- The report
------------------------------------------------------------------------------

local function read_json(name)
    local ok, t = pcall(json.load_file, name)
    return ok and t or nil
end

write_report = function()
    local bridge = read_json("minecraft_bridge.json")
    local terrain = read_json("minecraft_terrain.json")
    local mouse = read_json("minecraft_mouse.json")
    if type(mouse) == "table" then mouse.kev = nil end
    local c = MinecraftRE4Control
    local gui = {}
    for name, n in pairs(gui_names) do gui[#gui + 1] = { name = name, draws = n } end
    table.sort(gui, function(a, b) return a.draws > b.draws end)
    local enemies, nearest = nearest_enemies(8)
    local report = {
        time = os.date and os.date("%Y-%m-%d %H:%M:%S") or "?",
        frames = frames,
        fps = { now = fps.value, lowest = fps.min },
        control = type(c) == "table" and { mode = c.mode, reason = c.reason, menu = c.menu, manual = c.manual,
            puppet = c.puppet, minecraft_screen = c.minecraft_screen } or "minecraft_control.lua not running",
        who_had_leon = mode_counts,
        methods = check_methods(),
        damage_members = damage_members(),
        enemy_ai_and_spawning = ai_and_spawn(nearest),
        leon = leon_info(),
        enemies = enemies,
        camera = camera_info(),
        damage_tests = test_results,
        live_tests = live_results,
        real_hits = { calls = hook_counts, first_call_arguments = hook_args, captured_hits = captures,
            nearest_enemy_motion = motion_log, flinch_test_ready = replay ~= nil },
        hit_and_reaction_types = type_dumps(),
        gui_elements = gui,
        minecraft = type(bridge) == "table" and { in_world = bridge.in_world, re4_control = bridge.re4_control,
            overlay = bridge.overlay, authority = bridge.authority, terrain_boxes = bridge.terrain_boxes,
            sync_done = bridge.sync_done, screen_open = bridge.screen_open, game_mode = bridge.game_mode,
            camera = bridge.camera, anchor = bridge.anchor, enemy_damage = bridge.enemy_damage, pos = bridge.pos } or "no minecraft_bridge.json",
        terrain = type(terrain) == "table" and { seq = terrain.seq, epoch = terrain.epoch, request_epoch = terrain.request_epoch,
            radius = terrain.radius, cells = terrain.cells and select(2, terrain.cells:gsub(";", ";")) or 0,
            enemies = terrain.enemies } or "no minecraft_terrain.json",
        overlay_plugin = read_json("minecraft_overlay_plugin.json") or "no minecraft_overlay_plugin.json",
        mouse = mouse or "no minecraft_mouse.json",
        log = log_lines,
    }
    json.dump_file(REPORT_FILE, report)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Minecraft Diagnostics") then return end
    imgui.text("Writes reframework\\data\\" .. REPORT_FILE .. " (also by itself after a minute of play).")
    if imgui.button("Save report now") then report_now = true end
    imgui.text(string.format("Frame rate: %s (lowest %s)", fps.value and string.format("%.0f", fps.value) or "?",
        fps.min and string.format("%.0f", fps.min) or "?"))

    imgui.text("Record real hits (to make enemies flinch at Minecraft hits):")
    imgui.text("  1. Start   2. F7 (RE4 plays)   3. knife an enemy (and shoot one)   4. F7 again   5. Stop")
    if not recording then
        if imgui.button("Start recording") then
            hook_all()
            hook_counts, hook_args, captures, motion_log = {}, {}, {}, {}
            recording = true
            log("recording real hits...")
        end
    else
        if imgui.button("Stop and save") then
            recording = false
            local n = 0
            for _ in pairs(hook_counts) do n = n + 1 end
            log("recorded " .. n .. " different functions")
            report_now = true
        end
    end

    imgui.text("Live tests on the nearest enemy (a few seconds each; the report saves itself after each):")
    if live ~= nil then
        imgui.text("  running: " .. live.kind .. " (" .. live.frame .. " frames)")
    else
        if imgui.button("Look test") then pending_test = "look" end
        imgui.same_line()
        if imgui.button("Walk test") then pending_test = "walk" end
        imgui.same_line()
        if imgui.button("Flinch test") then pending_test = "flinch" end
        imgui.text(replay ~= nil and ("  flinch test replays your knife hit on " .. replay.name)
            or "  flinch test: first record a knife hit on an enemy (above)")
    end

    imgui.text("Tests on the nearest enemy (they change the game):")
    if imgui.button("Take a quarter of its health") then pending_test = "quarter" end
    imgui.same_line()
    if imgui.button("Kill it (HP 0 + RE4's death call)") then pending_test = "kill" end

    for _, l in ipairs(log_lines) do imgui.text(l) end
    imgui.tree_pop()
end)
