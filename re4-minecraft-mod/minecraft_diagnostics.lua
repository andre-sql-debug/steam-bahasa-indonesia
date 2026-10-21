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
local reaction_watch = {}  -- enemies RE4 itself just hit: body address -> { enemy, until_frame, last }
local reaction_log = {}    -- what those enemies did right after (behavior states, animations)
local states_seen = {}     -- every behavior state seen on enemies near Leon -> times seen
local states_seen_count = 0
local MAX_REACTION_LOG, MAX_STATES = 300, 400
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
    if recording then note_motion("HIT on " .. tostring(name) .. (on_leon and " (Leon)" or "")) end
    -- Which enemy (not Leon, crates or other objects)
    local hit_enemy = nil
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local hit_address = address_of(go)
    for i = 0, count - 1 do
        local e = try_call(list, "get_Item", i)
        local b = e and try_call(e, "get_BodyGameObject")
        if b ~= nil and hit_address ~= nil and address_of(b) == hit_address then hit_enemy = e end
    end
    if #captures < MAX_CAPTURES and (on_leon or hit_enemy ~= nil) then
        captures[#captures + 1] = { frame = frames, hit = tostring(name), on_leon = on_leon, fields = dump_fields(info, 0) }
    end
    if hit_enemy ~= nil then
        -- watch what the enemy does next (its damage reaction states), for 1.5 s
        reaction_watch[hit_address] = { enemy = hit_enemy, name = tostring(name), until_frame = frames + 90, last = nil }
        if #reaction_log < MAX_REACTION_LOG then
            reaction_log[#reaction_log + 1] = string.format("[%d] RE4 hit %s (wince %s, stopping %s, damage %s)", frames,
                tostring(name), tostring(try_call(info, "get_Wince")), tostring(try_call(info, "get_Stopping")),
                tostring(try_call(info, "get_Damage")))
        end
    end
end

-- Our own hits (minecraft_gameplay.lua building a hit for a Minecraft attack) are not RE4's
local function our_own_hit()
    local H = MinecraftRE4Hit
    return type(H) == "table" and (H.building == true or H.applying == true)
end

-- RE4's real hits are captured all the time (they are rare, so this costs nothing)
pcall(function()
    local td = sdk.find_type_definition("chainsaw.HitController")
    local m = td and td:get_method("callbackDamageHit(chainsaw.HitController.DamageInfo)")
    if m == nil then return end
    sdk.hook(m, function(args)
        if our_own_hit() then return end
        pcall(on_damage_hit, args)
    end, function(retval) return retval end)
end)

-- RE4's real damage to an enemy (its knife hits ran HitPoint.addDamage, not callbackDamageHit): watch what
-- the enemy does next too, so the report shows the names of RE4's damage reactions
local function on_real_damage(args)
    local hp = sdk.to_managed_object(args[2])
    local hp_address = hp and address_of(hp)
    if hp_address == nil then return end
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    for i = 0, count - 1 do
        local e = try_call(list, "get_Item", i)
        local ehp = e and try_call(e, "get_HitPoint")
        if ehp ~= nil and address_of(ehp) == hp_address then
            local body = try_call(e, "get_BodyGameObject")
            local a = body and address_of(body)
            if a ~= nil and reaction_watch[a] == nil then
                local name = tostring(try_call(body, "get_Name") or "?")
                reaction_watch[a] = { enemy = e, name = name, until_frame = frames + 90, last = nil }
                if #reaction_log < MAX_REACTION_LOG then
                    reaction_log[#reaction_log + 1] = string.format("[%d] RE4 damage on %s (addDamage)", frames, name)
                end
            end
            return
        end
    end
end

pcall(function()
    local td = sdk.find_type_definition("chainsaw.HitPoint")
    for _, m in ipairs(td and td:get_methods() or {}) do
        local ok, n = pcall(function() return m:get_name() end)
        if ok and n == "addDamage" then
            sdk.hook(m, function(args)
                if our_own_hit() then return end
                pcall(on_real_damage, args)
            end, function(retval) return retval end)
        end
    end
end)

-- Also every other hit-sounding function of the types between a collision and an enemy's reaction (RE4's
-- real knife hits ran HitController.poolDamage and HitPoint.addDamage, but none of the callbacks above)
local HIT_HOOK_TYPES = { "chainsaw.HitController", "chainsaw.Ch1c0BodyHitDriverCommon", "chainsaw.CharacterBodyHitDriver",
    "chainsaw.Ch1c0BodyUpdaterCommon", "chainsaw.EnemyBodyUpdater", "chainsaw.CharacterBodyUpdater",
    "chainsaw.HitPoint", "chainsaw.EnemyBaseContext" }
local HIT_HOOK_WORDS = { "damage", "wince", "hit", "react", "stagger", "knock", "flinch", "pool", "blow", "stun" }
local MAX_PATTERN_HOOKS, MAX_SEQUENCE = 150, 300
local hook_sequence = {}   -- the order hit functions first ran in while recording (each one's first 3 calls)

local function hook_method(type_name, m)
    local ok, n = pcall(function() return m:get_name() end)
    local okp, params = pcall(function() return m:get_num_params() end)
    local key = type_name .. "." .. tostring(n) .. "/" .. tostring(okp and params or "?")
    if not ok or hooked[key] then return false end
    hooked[key] = true
    pcall(function()
        sdk.hook(m, function(args)
            if not recording or our_own_hit() then return end
            local count = (hook_counts[key] or 0) + 1
            hook_counts[key] = count
            if hook_args[key] == nil then hook_args[key] = arg_types(args) end
            if count <= 3 and #hook_sequence < MAX_SEQUENCE then
                hook_sequence[#hook_sequence + 1] = string.format("[%d] %s", frames, key)
            end
        end, function(retval) return retval end)
    end)
    return true
end

local function hook_all()
    for type_name, names in pairs(HIT_HOOKS) do
        local td = sdk.find_type_definition(type_name)
        for _, m in ipairs(td and td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            for _, w in ipairs(names) do
                if ok and n == w then hook_method(type_name, m) end
            end
        end
    end
    local added = 0
    for _, type_name in ipairs(HIT_HOOK_TYPES) do
        local td = sdk.find_type_definition(type_name)
        for _, m in ipairs(td and td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            local l = ok and type(n) == "string" and n:lower() or ""
            -- getters/setters share machine code with unrelated ones, and per-frame updates would flood the log
            local plain = l == "" or l:find("^get_") or l:find("^set_") or l:find("^%.") or l:find("^<")
                or l:find("^update") or l:find("^is")
            if not plain and added < MAX_PATTERN_HOOKS then
                for _, w in ipairs(HIT_HOOK_WORDS) do
                    if l:find(w, 1, true) then
                        if hook_method(type_name, m) then added = added + 1 end
                        break
                    end
                end
            end
        end
    end
    log("hooked " .. added .. " more hit functions")
end

------------------------------------------------------------------------------
-- Tests on the nearest enemy (they change the game: only when you press them)
------------------------------------------------------------------------------

local test_results = {}
local pending_test = nil
local spawn_test           -- the spawn tests (defined further down)

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
local FLINCH_SETTLE_FRAMES = 90    -- before each hit, wait at most this long for the last reaction to end
local FLINCH_REACT_FRAMES = 12     -- a reaction starts within this many frames of the hit

-- Does this animation/behavior state look like a damage reaction (by its name)?
local function flinch_damage_like(state)
    local l = tostring(state or ""):lower()
    for _, word in ipairs({ "dam", "dmg", "wince", "hit", "stagger", "flinch", "knock", "react", "stun" }) do
        if l:find(word, 1, true) then return true end
    end
    return false
end

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
        -- Minecraft's hit code (minecraft_gameplay.lua) tried every way it knows, one after the other
        local H = MinecraftRE4Hit
        if type(H) ~= "table" or type(H.flinch) ~= "function" then
            r.result = "minecraft_gameplay.lua (which has the hit code) is not running"
        else
            live.methods = {}
            if H.template ~= nil then live.methods[#live.methods + 1] = "template" end
            if try_call(enemy, "get_LastAttackData") ~= nil then live.methods[#live.methods + 1] = "last_attack" end
            live.methods[#live.methods + 1] = "fresh"
            live.per = {}
            r.methods = live.methods
            r.real_hit_seen = H.template ~= nil
        end
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
        -- First a while without any hit (does its animation change by itself?), then one Minecraft-style hit
        -- per way of building it, each once the enemy is out of any damage reaction, watched FLINCH_FRAMES.
        -- Only a change into a damage reaction counts; the enemy is kept at full health meanwhile, and how
        -- much health RE4's own hit code took for our hit is written down.
        local state = motion_state(enemy)
        if t.frame == 1 then
            t.last_state, t.base_changes = state, 0
            t.result.hp_before = try_call(hp, "get_CurrentHitPoint")
            t.max = try_call(hp, "get_DefaultHitPoint")
            t.index, t.fi, t.settle = 1, 0, 0
        end
        local cur = nil
        if t.frame <= FLINCH_BASE_FRAMES then
            if t.frame > 1 and state ~= t.last_state then
                t.base_changes = t.base_changes + 1
                t.last_state = state
            end
        elseif t.index > #t.methods then
            if t.result.hp_before ~= nil then try_call(hp, "set_CurrentHitPoint", t.result.hp_before) end
            t.result.changes_before_hits = t.base_changes
            t.result.per_method = t.per
            local works, maybe = {}, {}
            for _, m in ipairs(t.per) do
                if m.reacted then works[#works + 1] = m.method elseif m.maybe then maybe[#maybe + 1] = m.method end
            end
            if #works > 0 then
                t.result.result = "the enemy reacted to the '" .. table.concat(works, "', '")
                    .. "' hit: Minecraft hits now make enemies flinch"
                local H = MinecraftRE4Hit
                H.method, H.methods, H.failures = works[1], works, 0
                local when = os.date and os.date("%Y-%m-%d %H:%M") or "?"
                H.status = "on (" .. table.concat(works, ", ") .. "; tested " .. when .. ")"
                pcall(json.dump_file, "minecraft_flinch.json", { works = true, method = works[1], methods = works, time = when })
            elseif #maybe > 0 then
                t.result.result = "the enemy's animation changed after the '" .. table.concat(maybe, "', '")
                    .. "' hit, but not into a damage reaction: left off (send the report)"
            else
                t.result.result = "no clear reaction to any of the hits (send the report; try again on an enemy that is standing or walking)"
            end
            finish_live()
            return
        elseif t.per[t.index] == nil then
            -- Before the next hit: let the last reaction end, so its end isn't taken for this hit's reaction
            if flinch_damage_like(state) and t.settle < FLINCH_SETTLE_FRAMES then
                t.settle = t.settle + 1
            else
                cur = { method = t.methods[t.index], changes = {}, state_before = state, waited = t.settle }
                t.per[t.index] = cur
                t.fi, t.settle = 0, 0
                t.last_state = state
                if flinch_damage_like(state) then
                    cur.call = "skipped: the enemy was still reacting to the hit before (can't tell)"
                    t.index = t.index + 1
                else
                    if t.max ~= nil then try_call(hp, "set_CurrentHitPoint", t.max) end
                    local ok, done, msg = pcall(MinecraftRE4Hit.flinch, enemy, cur.method, me)
                    cur.call = (ok and done) and "called" or ("failed: " .. tostring(ok and msg or done))
                    cur.hp_after_call = try_call(hp, "get_CurrentHitPoint")
                end
            end
        else
            cur = t.per[t.index]
            t.fi = t.fi + 1
            if state ~= t.last_state then
                cur.changes[#cur.changes + 1] = string.format("[%d] %s", t.fi, state)
                t.last_state = state
                local damage_like = flinch_damage_like(state)
                if t.fi <= FLINCH_REACT_FRAMES and cur.call == "called" then
                    if damage_like and not flinch_damage_like(cur.state_before) then
                        cur.reacted = true
                    elseif t.base_changes == 0 then
                        cur.maybe = true   -- changed right after the hit, but not into a damage reaction
                    end
                end
                if damage_like then cur.damage_state = state end
            end
            if t.fi >= FLINCH_FRAMES then t.index = t.index + 1 end
        end
        -- RE4 may apply the hit's damage a few frames later: keep the enemy alive until the end, and note it
        local now = try_call(hp, "get_CurrentHitPoint")
        if t.max ~= nil and now ~= nil and now < t.max then
            local by = cur or t.per[t.index - 1]   -- (while waiting before a hit: the hit before)
            if by ~= nil then by.hp_taken = math.max(by.hp_taken or 0, t.max - now) end
            try_call(hp, "set_CurrentHitPoint", t.max)
        end
    end
end

re.on_pre_application_entry("UpdateBehavior", function()
    -- No Leon (loading, title screen): enemies may be gone, a running test stops without touching its enemy again
    if player_context() == nil then
        for k in pairs(reaction_watch) do reaction_watch[k] = nil end
        if live ~= nil then
            live.result.result = "stopped: Leon went away (loading or menu)"
            live_results[#live_results + 1] = live.result
            live = nil
        end
    end
    if pending_test ~= nil then
        local k = pending_test
        pending_test = nil
        if k == "spawn_cube" or k == "spawn_statue" or k == "remove_spawned" then
            local ok, e = pcall(spawn_test, k)
            if not ok then log("spawn test error: " .. tostring(e)) end
        elseif k == "look" or k == "walk" or k == "flinch" then
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
    -- Enemies RE4 just hit: what they do next (their damage reaction)
    for key, w in pairs(reaction_watch) do
        if frames > w.until_frame then
            reaction_watch[key] = nil
        else
            local okm, state = pcall(motion_state, w.enemy)
            if okm and state ~= w.last then
                w.last = state
                if #reaction_log < MAX_REACTION_LOG then
                    reaction_log[#reaction_log + 1] = string.format("[%d] %s: %s", frames, w.name, state)
                end
            end
        end
    end
    -- Every behavior state the nearest enemy goes through (names of RE4's enemy states)
    if frames % 15 == 0 and states_seen_count < MAX_STATES then
        local enemy = nearest_live_enemy()
        local body = enemy and try_call(enemy, "get_BodyGameObject")
        local fsm = body and fsm_type and try_call(body, "getComponent(System.Type)", fsm_type)
        local node = fsm and try_call(fsm, "getCurrentNodeName", 0)
        if type(node) == "string" then
            if states_seen[node] == nil then states_seen_count = states_seen_count + 1 end
            states_seen[node] = (states_seen[node] or 0) + 1
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
-- Spawn test: are objects we create real RE4 objects (lit, shadowed and hidden by walls like RE4's own)?
-- That decides whether Minecraft's mobs can be made of RE4 objects instead of drawn over the picture.
------------------------------------------------------------------------------

local spawned = {}
local spawn_results = {}

local function spawn_game_object(name)
    local td = sdk.find_type_definition("via.GameObject")
    local create = td and td:get_method("create(System.String)")
    if create == nil then return nil, "via.GameObject.create(System.String) not found" end
    local ok, go = pcall(function() return create:call(nil, name) end)
    if not ok or go == nil then return nil, "create failed: " .. tostring(go) end
    pcall(function() go:add_ref() end)
    pcall(function() go:call(".ctor") end)
    spawned[#spawned + 1] = go
    return go
end

local function add_component(go, type_name)
    local t = sdk.typeof(type_name)
    if t == nil then return nil, type_name .. " not found" end
    local ok, comp = pcall(function() return go:call("createComponent(System.Type)", t) end)
    if not ok or comp == nil then return nil, "createComponent failed: " .. tostring(comp) end
    pcall(function() comp:add_ref() end)
    pcall(function() comp:call(".ctor") end)
    return comp
end

local function place(go, pos, scale)
    local tr = try_call(go, "get_Transform")
    if tr == nil then return "no transform" end
    local ok1 = pcall(function() tr:call("set_Position", pos) end)
    local ok2 = scale == nil or pcall(function() tr:call("set_LocalScale", Vector3f.new(scale, scale, scale)) end)
    return (ok1 and ok2) and "placed" or "could not place"
end

-- Where Leon is and which way the camera looks (flat)
local function leon_and_forward()
    local ctx = player_context()
    local body = ctx and try_call(ctx, "get_BodyGameObject")
    local me = body and try_call(try_call(body, "get_Transform"), "get_Position")
    local fx, fz = 0, 1
    local cam = sdk.get_primary_camera()
    local cgo = cam and try_call(cam, "get_GameObject")
    local az = cgo and try_call(try_call(cgo, "get_Transform"), "get_AxisZ")
    if az ~= nil then
        local len = math.sqrt(az.x * az.x + az.z * az.z)
        if len > 0.01 then fx, fz = -az.x / len, -az.z / len end
    end
    return me, fx, fz
end

spawn_test = function(kind)
    local r = { test = kind }
    if kind == "remove_spawned" then
        for _, go in ipairs(spawned) do pcall(function() go:call("destroy(via.GameObject)", go) end) end
        r.result = string.format("removed %d test objects", #spawned)
        spawned = {}
        log(r.result)
        return
    end
    local me, fx, fz = leon_and_forward()
    if me == nil then
        r.result = "Leon not found"
    elseif kind == "spawn_cube" then
        local go, err = spawn_game_object("MinecraftTestCube")
        if go == nil then
            r.result = err
        else
            local prim, perr = add_component(go, "via.render.Primitive")
            r.primitive = prim and "created" or perr
            if prim ~= nil then
                r.shape = pcall(function() prim:call("set_ShapeType", 2) end) and "cube" or "set_ShapeType failed"
                r.shadow = pcall(function() prim:call("set_DrawShadowCast", true) end) and "on" or "set_DrawShadowCast failed"
            end
            r.place = place(go, Vector3f.new(me.x + fx * 2.5, me.y + 1.0, me.z + fz * 2.5), 0.6)
            r.result = prim and "a cube should float 2.5 m in front of Leon: is it lit, shadowed and hidden by walls like RE4's things?"
                or "could not add the cube"
        end
    elseif kind == "spawn_statue" then
        -- a copy of the nearest enemy's model, as a new object (tests giving our objects a model)
        local enemy = nearest_live_enemy()
        local ebody = enemy and try_call(enemy, "get_BodyGameObject")
        local mesh = ebody and try_call(ebody, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        local holder = mesh and (try_call(mesh, "getMesh") or try_call(mesh, "get_Mesh"))
        local material = mesh and try_call(mesh, "get_Material")
        if holder == nil then
            r.result = "no enemy model to copy (stand near an enemy)"
        else
            local go, err = spawn_game_object("MinecraftTestStatue")
            local comp, cerr = nil, nil
            if go ~= nil then comp, cerr = add_component(go, "via.render.Mesh") end
            if comp == nil then
                r.result = err or cerr
            else
                r.set_mesh = pcall(function() comp:call("setMesh", holder) end) and "ok" or "setMesh failed"
                r.set_material = material == nil and "no material found"
                    or (pcall(function() comp:call("set_Material", material) end) and "ok" or "set_Material failed")
                r.place = place(go, Vector3f.new(me.x + fx * 2.5 - fz * 1.5, me.y, me.z + fz * 2.5 + fx * 1.5), nil)
                r.result = "a copy of the enemy's model should stand ahead and to the side of Leon (possibly in a T pose)"
            end
        end
    end
    spawn_results[#spawn_results + 1] = r
    log(kind .. ": " .. tostring(r.result))
    report_now = true
end

re.on_script_reset(function()
    for _, go in ipairs(spawned) do pcall(function() go:call("destroy(via.GameObject)", go) end) end
    spawned = {}
end)

-- The main camera's components and their exposure/fog settings (to match Minecraft's brightness to RE4)
local function camera_components()
    local out = {}
    local cam = sdk.get_primary_camera()
    local go = cam and try_call(cam, "get_GameObject")
    local comps = go and try_call(go, "get_Components")
    local ok, elems = pcall(function() return comps:get_elements() end)
    if not ok or elems == nil then return "no camera" end
    for _, comp in ipairs(elems) do
        local okt, td = pcall(function() return comp:get_type_definition() end)
        if okt and td ~= nil then
            local entry = { type = td:get_full_name(), values = {} }
            for _, m in ipairs(td:get_methods() or {}) do
                local okn, n = pcall(function() return m:get_name() end)
                local l = okn and n and n:lower() or ""
                if n and n:find("^get_") and (l:find("expos") or l:find("ev") or l:find("lumin") or l:find("bright")
                        or l:find("tonemap") or l:find("fog") or l:find("gamma") or l:find("auto")) then
                    local okp, np = pcall(function() return m:get_num_params() end)
                    if okp and np == 0 then
                        local okv, v = pcall(function() return comp:call(n) end)
                        local value = "?"
                        if okv then value = value_of(v, 1) end   -- (okv and ... or "?") turns false into "?"
                        entry.values[n] = value
                    end
                end
            end
            out[#out + 1] = entry
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Every member of the types a hit and a reaction are made of (for building them for Minecraft hits)
------------------------------------------------------------------------------

local FULL_TYPES = { "via.render.Primitive", "chainsaw.HitController.DamageInfo", "chainsaw.HitController.DamageValue",
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
    ["chainsaw.Ch1c0BodyHitDriverCommon"] = { "damage", "wince", "react", "hit", "request", "stagger", "down", "knock", "flinch" },
    ["chainsaw.CharacterBodyHitDriver"] = { "damage", "wince", "react", "hit", "request", "stagger", "down", "knock", "flinch" },
    ["via.render.Mesh"] = { "draw", "shadow", "static", "dynamic", "mesh", "material", "enable", "raytrac", "cull" },
    ["chainsaw.HitController"] = { "damage", "hit", "pool", "callback", "wince", "react", "request", "attack" },
    ["chainsaw.EnemyBaseContext"] = { "damage", "wince", "react", "hit", "stagger", "knock", "down", "stun", "attack" },
    ["chainsaw.collision.AttackUserData"] = { "attack", "damage", "wince", "break", "stopping", "data" },
    ["via.physics.Colliders"] = { "collider", "userdata", "num" },
    ["via.physics.Collider"] = { "userdata", "shape", "enable" },
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
        real_hits = { calls = hook_counts, first_call_arguments = hook_args, order = hook_sequence, captured_hits = captures,
            nearest_enemy_motion = motion_log, reactions_after_real_hits = reaction_log,
            real_hit_seen = type(MinecraftRE4Hit) == "table" and MinecraftRE4Hit.template ~= nil },
        enemy_states_seen = states_seen,
        spawn_tests = spawn_results,
        camera_components = camera_components(),
        flinch = type(MinecraftRE4Hit) == "table" and { method = MinecraftRE4Hit.method, status = MinecraftRE4Hit.status }
            or "minecraft_gameplay.lua not running",
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
    imgui.text("  (if RE4 feels slower afterwards: ScriptRunner -> Reset scripts)")
    if not recording then
        if imgui.button("Start recording") then
            hook_all()
            hook_counts, hook_args, captures, motion_log, hook_sequence = {}, {}, {}, {}, {}
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
        local H = MinecraftRE4Hit
        imgui.text("  Flinch: " .. (type(H) == "table" and tostring(H.status) or "minecraft_gameplay.lua not running"))
        imgui.text((type(H) == "table" and H.template ~= nil) and "  (a real RE4 hit was seen: the test also copies it)"
            or "  (better: first press F7, knife an enemy once, F7 again; then run the Flinch test)")
    end

    imgui.text("Real RE4 objects (does RE4 light and shadow objects we create?):")
    if imgui.button("Spawn test cube") then pending_test = "spawn_cube" end
    imgui.same_line()
    if imgui.button("Spawn enemy-model copy") then pending_test = "spawn_statue" end
    imgui.same_line()
    if imgui.button("Remove test objects") then pending_test = "remove_spawned" end

    imgui.text("Tests on the nearest enemy (they change the game):")
    if imgui.button("Take a quarter of its health") then pending_test = "quarter" end
    imgui.same_line()
    if imgui.button("Kill it (HP 0 + RE4's death call)") then pending_test = "kill" end

    for _, l in ipairs(log_lines) do imgui.text(l) end
    imgui.tree_pop()
end)
