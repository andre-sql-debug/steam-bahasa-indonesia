-- Minecraft Diagnostics for RE4 Remake (REFramework Lua script)
-- Collects what the other Minecraft scripts need to know about this RE4 version and your setup, into
-- reframework\data\minecraft_diagnostics.json, so problems can be fixed without guessing:
--  * which RE4 methods the mod relies on exist (enemy death, Leon's state flags, camera, clock...),
--  * Leon's joint names (for your Minecraft character's arms and legs in cutscenes),
--  * enemies near Leon and their health state,
--  * who had Leon how often (minecraft_control.lua), frame rate, the latest data files,
--  * which RE4 functions run when RE4 itself hits an enemy ("Record real hits"), to make enemies flinch.
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
-- Record real hits: which RE4 functions run when RE4 itself damages an enemy
------------------------------------------------------------------------------

local recording = false
local hook_counts = {}
local hook_args = {}
local hooked = {}

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

local function hook_all()
    for _, type_name in ipairs({ "chainsaw.HitPoint", "chainsaw.HitController", "chainsaw.EnemyManager" }) do
        local td = sdk.find_type_definition(type_name)
        for _, m in ipairs(td and td:get_methods() or {}) do
            local ok, n = pcall(function() return m:get_name() end)
            local key = type_name .. "." .. tostring(n)
            -- only damage/death related, and never plain getters (they run all the time)
            if ok and n and interesting(n) and not n:find("^get_") and not hooked[key] then
                hooked[key] = true
                pcall(function()
                    sdk.hook(m, function(args)
                        if recording then
                            hook_counts[key] = (hook_counts[key] or 0) + 1
                            if hook_args[key] == nil then hook_args[key] = arg_types(args) end
                        end
                    end, function(retval) return retval end)
                end)
            end
        end
    end
end

------------------------------------------------------------------------------
-- Damage tests on the nearest enemy (they change the game: only when you press them)
------------------------------------------------------------------------------

local test_results = {}
local pending_test = nil

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

re.on_pre_application_entry("UpdateBehavior", function()
    if pending_test ~= nil then
        local k = pending_test
        pending_test = nil
        local ok, e = pcall(run_test, k)
        if not ok then log("test error: " .. tostring(e)) end
    end
end)

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
    local enemies = nearest_enemies(8)
    local report = {
        time = os.date and os.date("%Y-%m-%d %H:%M:%S") or "?",
        frames = frames,
        fps = { now = fps.value, lowest = fps.min },
        control = type(c) == "table" and { mode = c.mode, reason = c.reason, menu = c.menu, manual = c.manual,
            puppet = c.puppet, minecraft_screen = c.minecraft_screen } or "minecraft_control.lua not running",
        who_had_leon = mode_counts,
        methods = check_methods(),
        damage_members = damage_members(),
        leon = leon_info(),
        enemies = enemies,
        camera = camera_info(),
        damage_tests = test_results,
        real_hits = { calls = hook_counts, first_call_arguments = hook_args },
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
    imgui.text("  1. Start   2. F7 (RE4 plays)   3. knife and shoot an enemy   4. F7 again   5. Stop")
    if not recording then
        if imgui.button("Start recording") then
            hook_all()
            hook_counts, hook_args = {}, {}
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

    imgui.text("Tests on the nearest enemy (they change the game):")
    if imgui.button("Take a quarter of its health") then pending_test = "quarter" end
    imgui.same_line()
    if imgui.button("Kill it (HP 0 + RE4's death call)") then pending_test = "kill" end

    for _, l in ipairs(log_lines) do imgui.text(l) end
    imgui.tree_pop()
end)
