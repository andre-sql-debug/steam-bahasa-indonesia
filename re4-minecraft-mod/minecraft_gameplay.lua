-- Minecraft Gameplay for RE4 Remake (REFramework Lua script)
-- Moves Leon and fights enemies the Minecraft way.
--
-- With Minecraft running (RE4 Bridge mod): your keys go to Minecraft (see minecraft_bridge_hud.lua),
-- Minecraft's own code moves its player and calculates attacks, and this script copies that movement
-- to Leon and applies that damage to RE4 enemies. RE4 only adds its walls, floors and enemies.
-- Use a Superflat world in Minecraft so its player isn't blocked by Minecraft blocks.
--
-- Without Minecraft: a built-in copy of Minecraft's movement numbers is used instead.
--
-- Controls (same as Minecraft): WASD walk, Ctrl sprint, Shift sneak, Space jump,
-- double-tap Space to fly in Creative, left-click attack. F7 = Minecraft movement off/on
-- (for ladders and doors). Without Minecraft, F6 also toggles flying.
-- Install: copy this file to <RE4 folder>\reframework\autorun\ (replaces minecraft_creative.lua)
-- Settings: press Insert -> Script Generated UI -> Minecraft Gameplay

local settings = {
    movement = true,
    combat = true,
    no_damage = true,
    swap_left_right = false,
    fly_speed = 10.9,       -- m/s, only without Minecraft
    show_debug = false,
}

-- Built-in Minecraft numbers for when Minecraft isn't running (1 block = 1 m)
local MC = {
    walk = 4.317,
    sprint = 5.612,
    sneak = 1.295,
    jump_velocity = 9.2,    -- tuned so a jump is 1.25 blocks high
    gravity = 32.0,
    accel = 14.0,
    reach = 3.0,
}

local KEY = {
    W = { 0x57 }, A = { 0x41 }, S = { 0x53 }, D = { 0x44 },
    SPACE = { 0x20 }, F6 = { 0x75 }, F7 = { 0x76 },
    SNEAK = { 0x10, 0xA0, 0xA1 },
    FLY_DOWN = { 0x10, 0xA0, 0xA1, 0x43 },
    SPRINT = { 0x11, 0xA2, 0xA3 },
}
local DOUBLE_TAP_SECONDS = 0.3
local TICKS_PER_SECOND = 20
local MOB_HEALTH = 20          -- RE4 enemies take damage as if they were zombies (20 health)

-- Fallback weapon stats without Minecraft: damage, attacks per second
local WEAPONS = {
    { "wooden_sword", 4, 1.6 }, { "golden_sword", 4, 1.6 }, { "stone_sword", 5, 1.6 },
    { "iron_sword", 6, 1.6 }, { "diamond_sword", 7, 1.6 }, { "netherite_sword", 8, 1.6 },
    { "wooden_axe", 7, 0.8 }, { "golden_axe", 7, 1.0 }, { "stone_axe", 9, 0.8 },
    { "iron_axe", 9, 0.9 }, { "diamond_axe", 9, 1.0 }, { "netherite_axe", 10, 1.0 },
}
local FIST = { 1, 4.0 }

local BRIDGE_FILE = "minecraft_bridge.json"
local BRIDGE_TIMEOUT_FRAMES = 60

local debug = {
    mode = "?",
    player = "not checked yet",
    movement = "not checked yet",
    ground = "?",
    combat = "no attack yet",
    damage = "not checked yet",
}

local state = {
    velocity = Vector3f.new(0, 0, 0),
    vertical = 0,
    jumping = false,
    flying = false,
    fly_pos = nil,
    airborne = false,       -- Minecraft player is jumping or flying
    base_y = 0,
    smooth_y = nil,
    last_space_time = -10,
    last_attack_time = -10,
    last_attack_seq = nil,
    time = 0,
    frame_start_pos = nil,
}
local keys_was_down = {}
local mouse_was_down = false

local bridge = nil
local bridge_seq = nil
local bridge_age = math.huge

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

------------------------------------------------------------------------------
-- Minecraft bridge data
------------------------------------------------------------------------------

local function read_bridge()
    bridge_age = bridge_age + 1
    local ok, d = pcall(json.load_file, BRIDGE_FILE)
    if ok and type(d) == "table" and d.seq ~= nil then
        if d.seq ~= bridge_seq then
            bridge_seq = d.seq
            bridge_age = 0
        end
        bridge = d
    end
end

-- Minecraft is running, in a world, and listening to RE4's keys
local function minecraft_in_control()
    return bridge ~= nil and bridge_age < BRIDGE_TIMEOUT_FRAMES and bridge.in_world
        and bridge.re4_control == true and type(bridge.move) == "table"
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
        transform = try_call(body, "get_Transform"),
        adsorber = try_call(body, "getComponent(System.Type)", adsorber_type),
        controller = try_call(body, "getComponent(System.Type)", controller_type),
    }
end

local function get_delta_time(player)
    local dt = player.controller and try_call(player.controller, "get_DeltaTime")
    if type(dt) ~= "number" or dt <= 0 then dt = 1 / 60 end
    if dt > 0.5 then dt = dt / 60 end   -- some engines report frames instead of seconds
    return math.min(dt, 0.1)
end

local function is_on_ground(player)
    local ground = player.controller and try_call(player.controller, "get_Ground")
    if type(ground) == "boolean" then
        debug.ground = ground and "on ground" or "in air"
        return ground
    end
    debug.ground = "unknown"
    return not state.jumping
end

-- Horizontal camera directions (so W walks where you look), the full look direction and the camera
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
    local right = Vector3f.new(-forward.z, 0, forward.x)
    if settings.swap_left_right then right = right * -1 end
    return forward, right, f, cam_transform
end

local function set_gravity(player, on)
    if player.adsorber == nil then return end
    try_call(player.adsorber, "set_EnabledGravity", on)
    try_call(player.adsorber, "set_EnabledCheckGround", on)
end

-- Puts Leon at (start of this frame + delta) right before RE4's collision check,
-- so RE4's walls and floors still block him. y = nil keeps RE4's own height (ground, stairs).
local function move_leon(player, delta_x, delta_z, y)
    local start = state.frame_start_pos
    local current = player.transform and try_call(player.transform, "get_Position")
    if start == nil or current == nil then
        debug.movement = "position not found"
        return false
    end
    try_call(player.transform, "set_Position", Vector3f.new(start.x + delta_x, y or current.y, start.z + delta_z))
    return true
end

------------------------------------------------------------------------------
-- Movement from Minecraft
------------------------------------------------------------------------------

local function update_from_minecraft(player, dt)
    local move = bridge.move
    local forward, right = camera_vectors()
    if forward == nil then
        debug.movement = "camera not found"
        return
    end

    -- Minecraft moved this far during one tick; turn it into a speed and apply it this frame
    local velocity = (forward * (move.forward or 0) + right * (move.right or 0)) * TICKS_PER_SECOND

    -- Jumping and flying: Leon's height follows the Minecraft player's height above its ground
    local airborne = move.flying == true or (move.height or 0) > 0.01
    local start = state.frame_start_pos
    if airborne and not state.airborne and start ~= nil then
        state.airborne = true
        state.base_y = start.y
        state.smooth_y = start.y
        set_gravity(player, false)
    elseif not airborne and state.airborne then
        state.airborne = false
        state.smooth_y = nil
        set_gravity(player, true)
    end

    local moving = length_xz(velocity) > 0.01
    if not moving and not state.airborne then
        debug.movement = "idle (game controls Leon)"
        return
    end

    local y = nil
    if state.airborne then
        -- Minecraft updates 20 times per second; ease toward its height so the jump looks smooth
        local target = state.base_y + (move.height or 0)
        state.smooth_y = state.smooth_y + (target - state.smooth_y) * math.min(1, 20 * dt)
        y = state.smooth_y
    end

    if move_leon(player, velocity.x * dt, velocity.z * dt, y) then
        debug.movement = string.format("Minecraft: %.2f m/s%s%s%s", length_xz(velocity),
            move.sprinting and " sprinting" or "", move.flying and " flying" or "",
            state.airborne and string.format(" height %.2f", move.height or 0) or "")
    end
end

------------------------------------------------------------------------------
-- Built-in movement (without Minecraft)
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

local function update_builtin_walking(player, dt)
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
    state.velocity = state.velocity + (dir * speed - state.velocity) * math.min(1, MC.accel * dt)

    local on_ground = is_on_ground(player)
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

    if not moving and length_xz(state.velocity) < 0.05 and not state.jumping then
        state.velocity = Vector3f.new(0, 0, 0)
        debug.movement = "idle (game controls Leon)"
        return
    end

    local y = nil
    if state.jumping and state.frame_start_pos ~= nil then
        y = state.frame_start_pos.y + state.vertical * dt
    end
    if move_leon(player, state.velocity.x * dt, state.velocity.z * dt, y) then
        debug.movement = string.format("built-in: %.2f m/s%s", length_xz(state.velocity), state.jumping and " (jumping)" or "")
    end
end

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

local function update_builtin_flying(player, dt)
    local forward, right = camera_vectors()
    local move = Vector3f.new(0, 0, 0)
    if forward ~= nil then move = wish_direction(forward, right) end
    if key_down(KEY.SPACE) then move = move + Vector3f.new(0, 1, 0) end
    if key_down(KEY.FLY_DOWN) then move = move - Vector3f.new(0, 1, 0) end
    local speed = settings.fly_speed * (key_down(KEY.SPRINT) and 2 or 1)
    state.fly_pos = state.fly_pos + move * (speed * dt)
    try_call(player.transform, "set_Position", state.fly_pos)
    debug.movement = "built-in flying"
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
-- Combat
------------------------------------------------------------------------------

-- The HitPoint of the enemy closest to the crosshair within reach, and how many enemies are loaded
local function find_target()
    local _, _, look, cam_transform = camera_vectors()
    local cam_pos = cam_transform and try_call(cam_transform, "get_Position")
    if look == nil or cam_pos == nil then return nil, 0 end

    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local best_hp, best_score = nil, -1
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
                    best_hp, best_score = hp, aim
                end
            end
        end
    end
    return best_hp, count
end

-- damage is in Minecraft half-hearts; RE4 enemies lose damage/20 of their max health
local function hit_enemy(damage, note)
    local hp, count = find_target()
    if hp == nil then
        debug.combat = string.format("swing, no enemy in reach (%d enemies loaded)", count or 0)
        return
    end
    local current = try_call(hp, "get_CurrentHitPoint")
    local max = try_call(hp, "get_DefaultHitPoint") or current
    local new_hp = math.max(0, math.floor(current - max * damage / MOB_HEALTH))
    try_call(hp, "set_CurrentHitPoint", new_hp)
    if try_call(hp, "get_CurrentHitPoint") ~= new_hp then
        pcall(function() hp:set_field("<CurrentHitPoint>k__BackingField", new_hp) end)
    end
    debug.combat = string.format("hit for %.1f%s: enemy HP %s -> %s", damage, note,
        tostring(current), tostring(try_call(hp, "get_CurrentHitPoint")))
end

-- Minecraft calculated an attack (cooldown, weapon, crits); apply it when a new one shows up
local function update_minecraft_combat()
    local attack = bridge.attack
    if type(attack) ~= "table" or attack.seq == nil then return end
    if state.last_attack_seq == nil then
        state.last_attack_seq = attack.seq
        return
    end
    if attack.seq ~= state.last_attack_seq then
        state.last_attack_seq = attack.seq
        local note = string.format(" (Minecraft, charge %d%%%s)", math.floor((attack.strength or 0) * 100),
            attack.crit and ", critical!" or "")
        hit_enemy(attack.damage or 0, note)
    end
end

local function weapon_stats(id)
    if id ~= nil then
        local name = id:gsub("^minecraft:", "")
        for _, w in ipairs(WEAPONS) do
            if w[1] == name then return w[2], w[3] end
        end
    end
    return FIST[1], FIST[2]
end

local function builtin_attack()
    local damage, speed = weapon_stats(held_item_id())
    local charge = math.min(1, (state.time - state.last_attack_time) * speed)
    state.last_attack_time = state.time
    hit_enemy(damage * (0.2 + charge * charge * 0.8), string.format(" (built-in, charge %d%%)", math.floor(charge * 100)))
end

------------------------------------------------------------------------------
-- Main update
------------------------------------------------------------------------------

-- Where Leon is before RE4 moves him this frame
re.on_pre_application_entry("UpdateBehavior", function()
    local player = get_player()
    state.frame_start_pos = player and player.transform and try_call(player.transform, "get_Position")
end)

-- Right before RE4's collision check
re.on_pre_application_entry("UpdatePhysicsCharacterController", function()
    read_bridge()
    local player = get_player()
    if player == nil then return end
    local dt = get_delta_time(player)
    state.time = state.time + dt

    if settings.no_damage then keep_full_health(player) end
    if pressed(KEY.F7) and not menu_open() then settings.movement = not settings.movement end

    if minecraft_in_control() then
        debug.mode = "Minecraft (movement and attacks come from Minecraft)"
        if state.flying then set_flying(player, false) end
        if settings.movement then
            update_from_minecraft(player, dt)
        else
            debug.movement = "off (F7)"
        end
        if settings.combat then update_minecraft_combat() end
        return
    end

    debug.mode = "built-in (Minecraft not connected)"
    if state.airborne then
        state.airborne = false
        set_gravity(player, true)
    end
    if menu_open() then return end

    local toggle_fly = pressed(KEY.F6)
    if pressed(KEY.SPACE) then
        if state.time - state.last_space_time <= DOUBLE_TAP_SECONDS then
            toggle_fly = true
            state.last_space_time = -10
        else
            state.last_space_time = state.time
        end
    end
    if toggle_fly then set_flying(player, not state.flying) end

    if state.flying then
        update_builtin_flying(player, dt)
    elseif settings.movement then
        update_builtin_walking(player, dt)
    else
        debug.movement = "off (F7)"
    end

    if settings.combat and mouse_clicked() then builtin_attack() end
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Gameplay") then
        local changed
        changed, settings.movement = imgui.checkbox("Minecraft movement (F7)", settings.movement)
        changed, settings.combat = imgui.checkbox("Melee combat (left-click)", settings.combat)
        changed, settings.no_damage = imgui.checkbox("No damage", settings.no_damage)
        changed, settings.swap_left_right = imgui.checkbox("Swap left/right (if A and D are backwards)", settings.swap_left_right)
        changed, settings.fly_speed = imgui.slider_float("Fly speed without Minecraft (m/s)", settings.fly_speed, 2.0, 40.0)
        imgui.text("Mode: " .. debug.mode)
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Player: " .. debug.player)
            imgui.text("Movement: " .. debug.movement)
            imgui.text("Ground: " .. debug.ground)
            imgui.text("Combat: " .. debug.combat)
            imgui.text("Held item: " .. tostring(held_item_id()))
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
