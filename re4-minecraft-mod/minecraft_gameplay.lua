-- Minecraft Gameplay for RE4 Remake (REFramework Lua script)
-- Minecraft movement, jumping, flying, no damage and melee combat for Leon.
-- Replaces minecraft_creative.lua (delete that one).
--
-- Controls (same as Minecraft):
--   WASD = walk   Ctrl = sprint   Shift = sneak   Space = jump
--   Double-tap Space (Creative) or F6 = fly; while flying Space = up, Shift/C = down
--   Left-click = attack the enemy in front of you (damage depends on your Minecraft item)
--   F7 = switch Minecraft movement on/off (e.g. for ladders and doors)
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Gameplay

local settings = {
    movement = true,
    jumping = true,
    combat = true,
    no_damage = true,
    fly_speed = 10.9,       -- m/s, Minecraft creative flying
    timing = 1,             -- index into TIMINGS
    show_debug = false,
}

-- Minecraft numbers, converted to meters (1 block = 1 m) and seconds
local MC = {
    walk = 4.317,
    sprint = 5.612,
    sneak = 1.295,
    jump_velocity = 9.2,    -- tuned so a jump is 1.25 blocks high, like Minecraft
    gravity = 32.0,         -- 0.08 blocks/tick^2
    accel = 14.0,           -- how quickly you reach full speed / stop
    reach = 3.0,
}

local KEY = {
    W = { 0x57 }, A = { 0x41 }, S = { 0x53 }, D = { 0x44 },
    SPACE = { 0x20 }, F6 = { 0x75 }, F7 = { 0x76 },
    SNEAK = { 0x10, 0xA0, 0xA1 },        -- Shift
    FLY_DOWN = { 0x10, 0xA0, 0xA1, 0x43 }, -- Shift, C
    SPRINT = { 0x11, 0xA2, 0xA3 },       -- Ctrl
}
local DOUBLE_TAP_SECONDS = 0.3

-- Points in the frame where we replace Leon's movement; the menu lets you try each
local TIMINGS = { "LateUpdateBehavior (before)", "UpdateMotion (after)", "LateUpdateBehavior (after)" }

-- Minecraft attack damage (in half hearts) and attack speed (attacks per second)
local WEAPONS = {
    { "wooden_sword", 4, 1.6 }, { "golden_sword", 4, 1.6 }, { "stone_sword", 5, 1.6 },
    { "iron_sword", 6, 1.6 }, { "diamond_sword", 7, 1.6 }, { "netherite_sword", 8, 1.6 },
    { "wooden_axe", 7, 0.8 }, { "golden_axe", 7, 1.0 }, { "stone_axe", 9, 0.8 },
    { "iron_axe", 9, 0.9 }, { "diamond_axe", 9, 1.0 }, { "netherite_axe", 10, 1.0 },
    { "trident", 9, 1.1 }, { "mace", 6, 0.6 },
}
local FIST = { 1, 4.0 }
local MOB_HEALTH = 20   -- a zombie: so a diamond sword needs 3 hits, like in Minecraft

local BRIDGE_FILE = "minecraft_bridge.json"

local debug = {
    player = "not checked yet",
    movement = "not checked yet",
    ground = "?",
    dt = "?",
    combat = "no attack yet",
    damage = "not checked yet",
}

local state = {
    velocity = Vector3f.new(0, 0, 0),
    vertical = 0,
    jumping = false,
    flying = false,
    fly_pos = nil,
    last_space_time = -10,
    last_attack_time = -10,
    time = 0,
}
local keys_was_down = {}
local mouse_was_down = false
local bridge = nil
local bridge_frame = 0

local adsorber_type = sdk.typeof("chainsaw.GroundAdsorber")
local controller_type = sdk.typeof("via.physics.CharacterController")

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function key_down(keys)
    for _, key in ipairs(keys) do
        local ok, down = pcall(function() return reframework:is_key_down(key) end)
        if ok and down then return true end
    end
    return false
end

local function pressed(keys)
    local down = key_down(keys)
    local was = keys_was_down[keys[1]]
    keys_was_down[keys[1]] = down
    return down and not was
end

local function mouse_clicked()
    local down = key_down({ 0x01 })
    if not down then
        local ok, imgui_down = pcall(imgui.is_mouse_down, 0)
        down = ok and imgui_down == true
    end
    local clicked = down and not mouse_was_down
    mouse_was_down = down
    return clicked
end

local function menu_open()
    local ok, open = pcall(function() return reframework:is_drawing_ui() end)
    return ok and open == true
end

local function length_xz(v)
    return math.sqrt(v.x * v.x + v.z * v.z)
end

-- Data from the Minecraft bridge mod (held item, game mode); nil when Minecraft isn't running
local function read_bridge()
    bridge_frame = bridge_frame + 1
    if bridge_frame % 10 ~= 0 then return end
    local ok, d = pcall(json.load_file, BRIDGE_FILE)
    bridge = (ok and type(d) == "table" and d.in_world) and d or nil
end

local function is_creative()
    if bridge == nil then return true end   -- without Minecraft, allow flying
    return bridge.game_mode == "creative" or bridge.game_mode == "spectator"
end

local function held_item_id()
    if bridge == nil or bridge.hotbar == nil or bridge.selected == nil then return nil end
    local item = bridge.hotbar["s" .. tostring(bridge.selected)]
    return item and item.id or nil
end

------------------------------------------------------------------------------
-- Player parts
------------------------------------------------------------------------------

local function get_character_manager()
    return sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
end

local function get_player()
    local cm = get_character_manager()
    if cm == nil then
        debug.player = "CharacterManager not found"
        return nil
    end
    local ctx = try_call(cm, "getPlayerContextRef")
    if ctx == nil then
        debug.player = "player not found (in a menu?)"
        return nil
    end
    local body = try_call(ctx, "get_BodyGameObject")
    if body == nil then
        debug.player = "Leon's body not found"
        return nil
    end
    debug.player = "ok"
    return {
        ctx = ctx,
        body = body,
        transform = try_call(body, "get_Transform"),
        adsorber = try_call(body, "getComponent(System.Type)", adsorber_type),
        controller = try_call(body, "getComponent(System.Type)", controller_type),
    }
end

local function get_delta_time(player)
    local dt = player.controller and try_call(player.controller, "get_DeltaTime")
    if type(dt) ~= "number" or dt <= 0 then dt = 1 / 60 end
    if dt > 0.5 then dt = dt / 60 end   -- some engines report frames instead of seconds
    dt = math.min(dt, 0.1)
    debug.dt = string.format("%.4f", dt)
    return dt
end

local function is_on_ground(player)
    local ground = player.controller and try_call(player.controller, "get_Ground")
    if type(ground) == "boolean" then
        debug.ground = ground and "on ground" or "in air"
        return ground
    end
    debug.ground = "unknown (" .. type(ground) .. ")"
    return not state.jumping
end

-- Horizontal camera directions, so W walks where you look
local function camera_vectors()
    local camera = sdk.get_primary_camera()
    local cam_obj = camera and try_call(camera, "get_GameObject")
    local cam_transform = cam_obj and try_call(cam_obj, "get_Transform")
    local rot = cam_transform and try_call(cam_transform, "get_Rotation")
    if rot == nil then return nil end
    local ok, f = pcall(function() return rot * Vector3f.new(0, 0, -1) end)
    if not ok or f == nil then return nil end
    local len = length_xz(f)
    if len < 0.001 then return nil end
    local forward = Vector3f.new(f.x / len, 0, f.z / len)
    return forward, Vector3f.new(-forward.z, 0, forward.x), f, cam_transform
end

------------------------------------------------------------------------------
-- Walking and jumping
------------------------------------------------------------------------------

local function wish_direction(forward, right)
    local dir = Vector3f.new(0, 0, 0)
    if key_down(KEY.W) then dir = dir + forward end
    if key_down(KEY.S) then dir = dir - forward end
    if key_down(KEY.D) then dir = dir + right end
    if key_down(KEY.A) then dir = dir - right end
    local len = length_xz(dir)
    if len > 0.001 then dir = dir * (1 / len) end
    return dir, len > 0.001
end

local function set_gravity(player, on)
    if player.adsorber == nil then return end
    try_call(player.adsorber, "set_EnabledGravity", on)
    try_call(player.adsorber, "set_EnabledCheckGround", on)
end

local function update_walking(player, dt)
    if player.adsorber == nil then
        debug.movement = "GroundAdsorber not found"
        return
    end

    local forward, right = camera_vectors()
    if forward == nil then
        debug.movement = "camera not found"
        return
    end

    local dir, moving = wish_direction(forward, right)
    local speed = MC.walk
    if key_down(KEY.SNEAK) then
        speed = MC.sneak
    elseif key_down(KEY.SPRINT) and key_down(KEY.W) then
        speed = MC.sprint
    end

    -- Ease toward the target speed, which gives Minecraft's quick start and stop
    local target = dir * speed
    local blend = math.min(1, MC.accel * dt)
    state.velocity = state.velocity + (target - state.velocity) * blend

    local on_ground = is_on_ground(player)
    if settings.jumping then
        if key_down(KEY.SPACE) and on_ground and not state.jumping then
            state.jumping = true
            state.vertical = MC.jump_velocity
            set_gravity(player, false)
        elseif state.jumping then
            state.vertical = state.vertical - MC.gravity * dt
            if state.vertical < 0 and on_ground then
                state.jumping = false
                state.vertical = 0
                set_gravity(player, true)
            end
        end
    end

    -- Leave Leon alone when we're not moving him, so ladders, doors and cutscenes still work
    if not moving and length_xz(state.velocity) < 0.05 and not state.jumping then
        state.velocity = Vector3f.new(0, 0, 0)
        debug.movement = "idle (game controls Leon)"
        return
    end

    local delta = Vector3f.new(state.velocity.x * dt, state.vertical * dt, state.velocity.z * dt)
    try_call(player.adsorber, "set_MotionDeltaPosition", delta)
    debug.movement = string.format("moving %.2f m/s%s", length_xz(state.velocity), state.jumping and " (jumping)" or "")
end

------------------------------------------------------------------------------
-- Flying (Creative)
------------------------------------------------------------------------------

local function set_flying(player, on)
    if on == state.flying then return end
    if on then
        state.fly_pos = player.transform and try_call(player.transform, "get_Position")
        if state.fly_pos == nil then return end
    end
    state.flying = on
    state.jumping = false
    state.vertical = 0
    if player.controller ~= nil then try_call(player.controller, "set_Enabled", not on) end
    set_gravity(player, not on)
end

local function update_flying(player, dt)
    local forward, right = camera_vectors()
    local move = Vector3f.new(0, 0, 0)
    if forward ~= nil then
        move = wish_direction(forward, right)
    end
    if key_down(KEY.SPACE) then move = move + Vector3f.new(0, 1, 0) end
    if key_down(KEY.FLY_DOWN) then move = move - Vector3f.new(0, 1, 0) end

    local speed = settings.fly_speed
    if key_down(KEY.SPRINT) then speed = speed * 2 end
    state.fly_pos = state.fly_pos + move * (speed * dt)
    try_call(player.transform, "set_Position", state.fly_pos)
    debug.movement = "flying"
end

------------------------------------------------------------------------------
-- No damage
------------------------------------------------------------------------------

local function keep_full_health(player)
    local hp = try_call(player.ctx, "get_HitPoint")
    local max = hp and try_call(hp, "get_DefaultHitPoint")
    local current = hp and try_call(hp, "get_CurrentHitPoint")
    if max == nil or current == nil then
        debug.damage = "HP not found"
        return
    end
    if current < max then
        try_call(hp, "set_CurrentHitPoint", max)
        if (try_call(hp, "get_CurrentHitPoint") or 0) < max then
            pcall(function() hp:set_field("<CurrentHitPoint>k__BackingField", max) end)
        end
    end
    debug.damage = "HP " .. tostring(try_call(hp, "get_CurrentHitPoint")) .. " / " .. tostring(max)
end

------------------------------------------------------------------------------
-- Melee combat
------------------------------------------------------------------------------

local function weapon_stats(id)
    if id ~= nil then
        local name = id:gsub("^minecraft:", "")
        for _, w in ipairs(WEAPONS) do
            if w[1] == name then return w[2], w[3] end
        end
    end
    return FIST[1], FIST[2]
end

-- The enemy closest to the crosshair within reach, plus its HitPoint
local function find_target(cam_pos, look)
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local best, best_hp, best_score = nil, nil, -1
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local pos = enemy and try_call(enemy, "get_Position")
        local hp = enemy and try_call(enemy, "get_HitPoint")
        local current = hp and try_call(hp, "get_CurrentHitPoint")
        if pos ~= nil and current ~= nil and current > 0 then
            local to = (pos + Vector3f.new(0, 1.0, 0)) - cam_pos
            local dist = math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
            if dist <= MC.reach + 0.6 and dist > 0.01 then
                local aim = (to.x * look.x + to.y * look.y + to.z * look.z) / dist
                if aim > 0.75 and aim > best_score then
                    best, best_hp, best_score = enemy, hp, aim
                end
            end
        end
    end
    return best, best_hp, count
end

local function attack()
    local _, _, look, cam_transform = camera_vectors()
    local cam_pos = cam_transform and try_call(cam_transform, "get_Position")
    if look == nil or cam_pos == nil then
        debug.combat = "camera not found"
        return
    end

    -- Minecraft's attack cooldown: hitting early does less damage
    local damage, speed = weapon_stats(held_item_id())
    local charge = math.min(1, (state.time - state.last_attack_time) * speed)
    state.last_attack_time = state.time
    local dealt = damage * (0.2 + charge * charge * 0.8)

    local enemy, hp, count = find_target(cam_pos, look)
    if enemy == nil then
        debug.combat = string.format("swing, no enemy in reach (%d enemies loaded)", count)
        return
    end

    local current = try_call(hp, "get_CurrentHitPoint")
    local max = try_call(hp, "get_DefaultHitPoint") or current
    local new_hp = math.max(0, math.floor(current - max * dealt / MOB_HEALTH))
    try_call(hp, "set_CurrentHitPoint", new_hp)
    if try_call(hp, "get_CurrentHitPoint") ~= new_hp then
        pcall(function() hp:set_field("<CurrentHitPoint>k__BackingField", new_hp) end)
    end
    debug.combat = string.format("hit for %.1f (charge %d%%): enemy HP %s -> %s",
        dealt, math.floor(charge * 100), tostring(current), tostring(try_call(hp, "get_CurrentHitPoint")))
end

------------------------------------------------------------------------------
-- Main update
------------------------------------------------------------------------------

local function update(timing)
    if TIMINGS[settings.timing] ~= timing then return end

    read_bridge()
    local player = get_player()
    if player == nil then return end
    local dt = get_delta_time(player)
    state.time = state.time + dt

    if settings.no_damage then keep_full_health(player) end

    if menu_open() then return end

    if pressed(KEY.F7) then settings.movement = not settings.movement end

    -- Flying: F6, or double-tap Space in Creative
    local toggle_fly = pressed(KEY.F6)
    if pressed(KEY.SPACE) then
        if is_creative() and state.time - state.last_space_time <= DOUBLE_TAP_SECONDS then
            toggle_fly = true
            state.last_space_time = -10
        else
            state.last_space_time = state.time
        end
    end
    if toggle_fly then set_flying(player, not state.flying) end

    if state.flying then
        update_flying(player, dt)
    elseif settings.movement then
        update_walking(player, dt)
    else
        debug.movement = "off (F7)"
    end

    if settings.combat and mouse_clicked() then attack() end
end

re.on_pre_application_entry("LateUpdateBehavior", function() update(TIMINGS[1]) end)
re.on_application_entry("UpdateMotion", function() update(TIMINGS[2]) end)
re.on_application_entry("LateUpdateBehavior", function() update(TIMINGS[3]) end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Gameplay") then
        local changed
        changed, settings.movement = imgui.checkbox("Minecraft movement (F7)", settings.movement)
        changed, settings.jumping = imgui.checkbox("Minecraft jumping", settings.jumping)
        changed, settings.combat = imgui.checkbox("Melee combat (left-click)", settings.combat)
        changed, settings.no_damage = imgui.checkbox("No damage", settings.no_damage)
        changed, settings.fly_speed = imgui.slider_float("Fly speed (m/s)", settings.fly_speed, 2.0, 40.0)
        changed, settings.timing = imgui.combo("Movement timing", settings.timing, TIMINGS)
        imgui.text(state.flying and "Flying (F6 to land)" or "Walking")
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Player: " .. debug.player)
            imgui.text("Movement: " .. debug.movement)
            imgui.text("Ground: " .. debug.ground .. "   Frame time: " .. debug.dt)
            imgui.text("Combat: " .. debug.combat)
            imgui.text("Held item: " .. tostring(held_item_id()) .. "   Creative: " .. tostring(is_creative()))
            imgui.text("Health: " .. debug.damage)
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    local player = get_player()
    if player == nil then return end
    if player.controller ~= nil then try_call(player.controller, "set_Enabled", true) end
    set_gravity(player, true)
end)
