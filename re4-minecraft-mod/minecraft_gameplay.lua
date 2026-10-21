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
-- double-tap Space to fly in Creative, left-click attack, bows and crossbows (hold right-click) shoot
-- what the crosshair is on. Ladders, doors, cutscenes, grabs and menus are handed to RE4 automatically
-- (minecraft_control.lua; F7 = everything to RE4). Without Minecraft, F6 toggles flying.
-- Enemy health: normal enemies take hits like a 20-health Minecraft zombie; tougher ones (bosses) get
-- more, compared to the usual enemy health seen so far (up to 300, like the Wither).
-- Install: copy this file to <RE4 folder>\reframework\autorun\ (replaces minecraft_creative.lua)
-- Settings: press Insert -> Script Generated UI -> Minecraft Gameplay

local settings = {
    movement = true,
    combat = true,
    enemies_look_at_mobs = true,
    flinch = true,          -- enemies react to Minecraft hits (once the Flinch test found a way that works)
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
-- Hands off Leon while the game places him: after he appears (loading a save) and after teleports
local SETTLE_FRAMES_AFTER_LOAD = 180      -- ~3 s
local SETTLE_FRAMES_AFTER_TELEPORT = 60   -- ~1 s
local TELEPORT_DISTANCE = 2.0             -- meters in one frame that only the game itself does
local JUMP_PREDICT_SECONDS = 0.15   -- how long we show a predicted jump before Minecraft confirms it
local MOB_HEALTH = 20          -- RE4 enemies take damage as if they were zombies (20 health)...
local MAX_MOB_HEALTH = 300     -- ...bosses up to the Wither's health
local ARROW_RANGE = 64.0       -- meters
local ARROW_WIDTH = 0.8        -- how far from the aim line an enemy still gets hit (meters)
local ARROW_BIG_ANGLE = 0.12   -- otherwise: within ~7 degrees of the aim (huge enemies like Del Lago)

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
    attention = "no fights",
}

local state = {
    velocity = Vector3f.new(0, 0, 0),
    vertical = 0,
    jumping = false,
    flying = false,
    fly_pos = nil,
    vy = nil,               -- vertical speed we control (jumping/flying), nil = RE4 controls height
    auth_pos = nil,         -- where Leon should be (after RE4's collision check) while we move him
    controlling = false,    -- did we move Leon this frame?
    last_space_time = -10,
    last_attack_time = -10,
    last_attack_seq = nil,
    predicted_jump_time = nil,
    floor_y = nil,          -- RE4's floor height under Leon while Minecraft's player is on its flat ground
    smooth_y = nil,
    probe = nil,            -- movement recorder
    frame = 0,
    settle_until = 0,       -- frame until which we leave Leon completely to the game
    player_present = false,
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
    return state.vy == nil
end

-- The look direction the HUD script last sent to Minecraft (the first-person mouse look), in
-- Minecraft angles: yaw 0 = +Z, pitch > 0 = looking down
local sent_look = { yaw = nil, pitch = nil, frame = -1 }
local look_frame = 0

local function read_sent_look()
    look_frame = look_frame + 1
    local ok, input = pcall(json.load_file, "minecraft_bridge_input.json")
    if ok and type(input) == "table" and type(input.yaw) == "number" and type(input.pitch) == "number" then
        sent_look.yaw, sent_look.pitch, sent_look.frame = input.yaw, input.pitch, look_frame
    end
end

local function leon_eye_position()
    local player = get_player()
    local feet = player and player.transform and try_call(player.transform, "get_Position")
    if feet == nil then return nil end
    return feet + Vector3f.new(0, 1.62, 0)
end

-- Horizontal directions (so W walks where you look), the full look direction and the eye position.
-- Uses the look direction sent to Minecraft; RE4's camera only as a fallback.
local function camera_vectors()
    if sent_look.yaw ~= nil and look_frame - sent_look.frame < 30 then
        local yaw, pitch = math.rad(sent_look.yaw), math.rad(sent_look.pitch)
        local forward = Vector3f.new(-math.sin(yaw), 0, math.cos(yaw))
        local right = Vector3f.new(-forward.z, 0, forward.x)
        if settings.swap_left_right then right = right * -1 end
        local look = Vector3f.new(-math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch))
        return forward, right, look, nil, leon_eye_position()
    end
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
    return forward, right, f, cam_transform, cam_transform and try_call(cam_transform, "get_Position")
end

-- gravity: RE4 pulls Leon down; check_ground: RE4 snaps Leon onto the ground
local function set_gravity(player, gravity, check_ground)
    if player.adsorber == nil then return end
    if check_ground == nil then check_ground = gravity end
    try_call(player.adsorber, "set_EnabledGravity", gravity)
    try_call(player.adsorber, "set_EnabledCheckGround", check_ground)
end

-- Moves Leon by (dx, dy, dz) from where he should be, right before RE4's collision check, so RE4's
-- walls, floors and ceilings still stop him. dy = nil keeps RE4's own height (ground, stairs).
-- RE4 also moves Leon later in the frame; the LateUpdateBehavior hook below undoes that.
local function move_leon(player, dx, dz, dy)
    local current = player.transform and try_call(player.transform, "get_Position")
    local base = state.auth_pos or state.frame_start_pos
    if base == nil or current == nil then
        debug.movement = "position not found"
        return false
    end
    local y = dy ~= nil and (base.y + dy) or current.y
    local desired = Vector3f.new(base.x + dx, y, base.z + dz)
    try_call(player.transform, "set_Position", desired)
    state.controlling = true
    if state.probe ~= nil then
        state.probe.sample.before_us = current
        state.probe.sample.desired = desired
    end
    return true
end

-- Vertical speed: nil hands height back to RE4 (its gravity and ground snapping).
-- While we control it, RE4's collision still stops Leon at floors and ceilings.
local function set_vertical(player, vy)
    if vy == nil then
        if state.vy ~= nil then set_gravity(player, true) end
    elseif state.vy == nil then
        set_gravity(player, false)
    end
    state.vy = vy
end

------------------------------------------------------------------------------
-- Movement from Minecraft
------------------------------------------------------------------------------

local function local_keys()
    -- Typing in a Minecraft screen (chat, creative search) is not walking
    local c = MinecraftRE4Control
    if type(c) == "table" and c.minecraft_screen then return {} end
    return {
        w = key_down(KEY.W), a = key_down(KEY.A), s = key_down(KEY.S), d = key_down(KEY.D),
        jump = key_down(KEY.SPACE), sneak = key_down(KEY.SNEAK), sprint = key_down(KEY.SPRINT),
    }
end

-- Has Minecraft already used the keys we're holding right now?
local function minecraft_caught_up(keys)
    local used = bridge.keys
    if type(used) ~= "table" then return true end
    for _, name in ipairs({ "w", "a", "s", "d", "sneak", "sprint" }) do
        if (used[name] == true) ~= keys[name] then return false end
    end
    return true
end

-- Built-in Minecraft movement for the few frames until Minecraft answers a key press
local function predicted_velocity(keys, forward, right, dt)
    local dir = Vector3f.new(0, 0, 0)
    if keys.w then dir = dir + forward end
    if keys.s then dir = dir - forward end
    if keys.d then dir = dir + right end
    if keys.a then dir = dir - right end
    local len = length_xz(dir)
    if len > 0.001 then dir = dir * (1 / len) end
    local speed = keys.sneak and MC.sneak or ((keys.sprint and keys.w) and MC.sprint or MC.walk)
    state.velocity = state.velocity + (dir * speed - state.velocity) * math.min(1, MC.accel * dt)
    return state.velocity
end

local function update_from_minecraft(player, dt)
    -- minecraft_terrain.lua is moving Leon with Minecraft's physics on RE4's terrain: hands off
    if bridge.authority == true then
        set_vertical(player, nil)
        state.velocity = Vector3f.new(0, 0, 0)
        debug.movement = "Minecraft physics on RE4 terrain (minecraft_terrain.lua)"
        return
    end
    local move = bridge.move
    local forward, right = camera_vectors()
    if forward == nil then
        debug.movement = "camera not found"
        return
    end

    -- Minecraft moved this far during one tick; turn it into a speed and apply it this frame.
    -- Until Minecraft has seen a new key press, predict with the same numbers so there's no delay.
    local keys = local_keys()
    local velocity
    local predicting = not minecraft_caught_up(keys)
    if predicting then
        velocity = predicted_velocity(keys, forward, right, dt)
    elseif move.dx ~= nil and move.dz ~= nil and not settings.swap_left_right then
        -- Minecraft looks where Leon looks, so its world movement is Leon's movement
        velocity = Vector3f.new(move.dx, 0, move.dz) * TICKS_PER_SECOND
        state.velocity = velocity
    else
        velocity = (forward * (move.forward or 0) + right * (move.right or 0)) * TICKS_PER_SECOND
        state.velocity = velocity
    end

    -- Vertical: only Minecraft's way UP (jumping, flying) moves Leon up or down; everything else
    -- (standing, walking, falling back down) is RE4's own ground and gravity. So Minecraft terrain
    -- can never push Leon into RE4's floor. A jump press starts a predicted jump right away;
    -- Minecraft's real jump takes over as soon as it arrives.
    local mc_airborne = move.flying == true or move.on_ground == false
    if keys.jump and state.vy == nil and state.predicted_jump_time == nil and not mc_airborne then
        state.predicted_jump_time = state.time
    end
    if state.predicted_jump_time ~= nil and (mc_airborne or state.time - state.predicted_jump_time > JUMP_PREDICT_SECONDS) then
        state.predicted_jump_time = nil
    end

    local vy = nil
    local mc_vy = (move.up or 0) * TICKS_PER_SECOND
    if state.predicted_jump_time ~= nil then
        local t = state.time - state.predicted_jump_time
        vy = MC.jump_velocity - MC.gravity * t
        if vy <= 0 then vy = nil end
    elseif move.flying == true then
        -- Flying down stops on RE4's ground
        vy = mc_vy
        if vy < 0 and is_on_ground(player) then vy = nil end
    elseif mc_airborne and mc_vy > 0 then
        vy = mc_vy
    end
    set_vertical(player, vy)

    local moving = length_xz(velocity) > 0.01
    if not moving and vy == nil then
        debug.movement = "idle (game controls Leon)"
        return
    end

    if move_leon(player, velocity.x * dt, velocity.z * dt, vy and vy * dt) then
        debug.movement = string.format("%s: %.2f m/s%s%s%s", predicting and "predicting" or "Minecraft", length_xz(velocity),
            move.sprinting and " sprinting" or "", move.flying and " flying" or "",
            vy and string.format(" vertical %.1f m/s", vy) or "")
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
    local vy = state.vy
    if key_down(KEY.SPACE) and on_ground and vy == nil then
        vy = MC.jump_velocity
    elseif vy ~= nil then
        vy = vy - MC.gravity * dt
        if vy < 0 and on_ground then vy = nil end
    end
    set_vertical(player, vy)

    if not moving and length_xz(state.velocity) < 0.05 and vy == nil then
        state.velocity = Vector3f.new(0, 0, 0)
        debug.movement = "idle (game controls Leon)"
        return
    end

    if move_leon(player, state.velocity.x * dt, state.velocity.z * dt, vy and vy * dt) then
        debug.movement = string.format("built-in: %.2f m/s%s", length_xz(state.velocity), vy and " (jumping)" or "")
    end
end

local function set_flying(player, on)
    if on == state.flying then return end
    if on then
        state.fly_pos = player.transform and try_call(player.transform, "get_Position")
        if state.fly_pos == nil then return end
    end
    state.flying = on
    state.vy = nil
    state.auth_pos = nil
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

-- Damage to an RE4 enemy, the way the game counts it: its own subtraction when this game version has one,
-- else the hit point number; and on a killing hit the engine's own death call, chainsaw.HitPoint.dead()
-- (writing 0 alone leaves the enemy walking around at 0 HP). Enemies the game marks as unkillable right
-- now (scripted moments, boss phases) stop at 1 HP.
local hp_api_cache = {}   -- HitPoint type name -> { add_damage = method|false, dead = method|false }

local function hp_api(hp)
    local ok, td = pcall(function() return hp:get_type_definition() end)
    if not ok or td == nil then return {} end
    local name = td:get_full_name()
    local api = hp_api_cache[name]
    if api == nil then
        local function find(...)
            for _, n in ipairs({ ... }) do
                local okm, m = pcall(function() return td:get_method(n) end)
                if okm and m ~= nil then return m end
            end
            return false
        end
        api = {
            add_damage = find("addDamage(System.Int32)"),
            dead = find("dead()", "dead"),
        }
        -- only use addDamage when it takes exactly one int (other overloads would get garbage)
        if api.add_damage then
            local okp, ok_int = pcall(function()
                local types = api.add_damage:get_param_types()
                return api.add_damage:get_num_params() == 1 and types[1]:get_full_name() == "System.Int32"
            end)
            if not okp or not ok_int then api.add_damage = false end
        end
        hp_api_cache[name] = api
    end
    return api
end

local function hp_flag(hp, getter) return try_call(hp, getter) == true end

-- Alive by the game's own flags; HP > 0 only as a last resort
local function enemy_alive(hp)
    if hp == nil then return false end
    local live = try_call(hp, "get_IsLive")
    if live ~= nil then return live == true end
    local dead = try_call(hp, "get_IsDead")
    if dead ~= nil then return dead ~= true end
    return (try_call(hp, "get_CurrentHitPoint") or 0) > 0
end

local function write_hp(hp, value)
    try_call(hp, "set_CurrentHitPoint", value)
    if try_call(hp, "get_CurrentHitPoint") ~= value then
        pcall(function() hp:set_field("<CurrentHitPoint>k__BackingField", value) end)
    end
end

local death_requested = {}   -- HitPoint address -> frame dead() was called (call it once)

-- amount: RE4 hit points to remove. Returns a short status for the debug line.
local function apply_re4_damage(hp, amount)
    if hp == nil then return "no HitPoint" end
    if not enemy_alive(hp) then return "already dead" end
    -- scripted moments (cutscenes, boss phases, Verdugo before freezing...): leave them alone
    if hp_flag(hp, "get_Invincible") or hp_flag(hp, "get_NoDamage") then return "invincible right now" end

    local before = try_call(hp, "get_CurrentHitPoint") or 0
    local dmg = math.max(1, math.floor(amount + 0.5))
    local cannot_die = hp_flag(hp, "get_NoDeath") or hp_flag(hp, "get_Immortal")
    local api = hp_api(hp)

    -- 1. the game's own subtraction, when this build has it
    local used = "set"
    if api.add_damage then
        if pcall(function() api.add_damage:call(hp, dmg) end) then
            local after = try_call(hp, "get_CurrentHitPoint")
            if after ~= nil and after < before then used = "addDamage" end
        end
    end

    -- 2. otherwise write the number (never below 1 for enemies the game says cannot die now)
    if used == "set" then
        local target = before - dmg
        if cannot_die and target < 1 then target = 1 end
        write_hp(hp, math.max(0, target))
    end

    -- 3. lethal: the engine's death call, once per enemy (retry after 2 s if it did not take)
    local now = try_call(hp, "get_CurrentHitPoint") or 0
    if now <= 0 and not cannot_die and enemy_alive(hp) and api.dead then
        local okk, key = pcall(function() return tostring(hp:get_address()) end)
        key = okk and key or tostring(hp)
        local last = death_requested[key]
        if last == nil or state.frame - last > 120 then
            death_requested[key] = state.frame
            write_hp(hp, 0)
            local okd, err = pcall(function() api.dead:call(hp) end)
            if not okd then return "dead() failed: " .. tostring(err) end
        end
    end

    return string.format("%s %d -> %s%s", used, before, tostring(try_call(hp, "get_CurrentHitPoint")),
        enemy_alive(hp) and "" or " (dead)")
end

-- How tough enemies usually are: the middle max health among the enemies seen (each enemy counted once)
local max_hp_counts = {}
local max_hp_seen = {}   -- enemy address -> true
local function note_max_hp(max, enemy)
    if max == nil or max <= 0 then return end
    local ok, address = pcall(function() return enemy:get_address() end)
    if not ok or address == nil or max_hp_seen[address] then return end
    max_hp_seen[address] = true
    local key = math.floor(max + 0.5)
    max_hp_counts[key] = (max_hp_counts[key] or 0) + 1
end

local function typical_max_hp()
    local list, total = {}, 0
    for value, count in pairs(max_hp_counts) do
        table.insert(list, { value, count })
        total = total + count
    end
    if total == 0 then return nil end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local half, seen = total / 2, 0
    for _, entry in ipairs(list) do
        seen = seen + entry[2]
        if seen >= half then return entry[1] end
    end
    return list[#list][1]
end

-- Minecraft health of an enemy: 20 for usual enemies, more for tougher ones (bosses)
local function mob_health(max)
    local typical = typical_max_hp()
    if typical == nil or max == nil or typical <= 0 then return MOB_HEALTH end
    return math.max(MOB_HEALTH, math.min(MAX_MOB_HEALTH, MOB_HEALTH * max / typical))
end

-- The HitPoint of the enemy closest to the crosshair within reach, and how many enemies are loaded
local function find_target()
    local _, _, look, _, cam_pos = camera_vectors()
    if look == nil or cam_pos == nil then return nil, 0 end

    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local best_hp, best_score = nil, -1
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local pos = enemy and try_call(enemy, "get_Position")
        local hp = enemy and try_call(enemy, "get_HitPoint")
        if pos ~= nil and enemy_alive(hp) then
            note_max_hp(try_call(hp, "get_DefaultHitPoint"), enemy)
            -- Aim at the body (legs, chest, head), not one spot; right up close anything in front counts,
            -- also when the camera is inside the enemy
            local best_aim, nearest = -1, math.huge
            for _, height in ipairs({ 0.3, 0.9, 1.5 }) do
                local to = (pos + Vector3f.new(0, height, 0)) - cam_pos
                local dist = math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
                local aim = dist > 0.01 and (to.x * look.x + to.y * look.y + to.z * look.z) / dist or 1
                if dist <= MC.reach + 0.4 then
                    best_aim = math.max(best_aim, aim)
                    nearest = math.min(nearest, dist)
                end
            end
            local fx, fz = pos.x - cam_pos.x, pos.z - cam_pos.z
            local flat = math.sqrt(fx * fx + fz * fz)
            local in_front = flat < 0.05 or (fx * look.x + fz * look.z) / flat > -0.2
            local same_level = pos.y - 0.5 <= cam_pos.y and cam_pos.y <= pos.y + 2.2
            local ok = best_aim > 0.75 or (nearest <= 1.5 and best_aim > 0.6) or (flat < 1.0 and in_front and same_level)
            local score = best_aim - nearest * 0.05
            if ok and score > best_score then
                best_hp, best_score = hp, score
            end
        end
    end
    return best_hp, count
end

-- The enemy the crosshair is on, up to ARROW_RANGE away (for arrows)
local function find_ranged_target()
    local _, _, look, _, cam_pos = camera_vectors()
    if look == nil or cam_pos == nil then return nil, 0 end
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local best_hp, best_along = nil, math.huge
    local best_angle_hp, best_angle = nil, math.huge
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local pos = enemy and try_call(enemy, "get_Position")
        local hp = enemy and try_call(enemy, "get_HitPoint")
        if pos ~= nil and enemy_alive(hp) then
            local to = (pos + Vector3f.new(0, 1.0, 0)) - cam_pos
            local along = to.x * look.x + to.y * look.y + to.z * look.z
            if along > 0.5 and along <= ARROW_RANGE then
                local off = to - look * along
                local miss = math.sqrt(off.x * off.x + off.y * off.y + off.z * off.z)
                -- tall enemies: allow more up and down than sideways
                if miss <= ARROW_WIDTH + math.abs(off.y) * 0.5 and along < best_along then
                    best_hp, best_along = hp, along
                end
                -- Big enemies (Del Lago, El Gigante) reach far from their center point: aim within a few degrees
                local angle = miss / along
                if angle < best_angle then
                    best_angle_hp, best_angle = hp, angle
                end
            end
        end
    end
    if best_hp == nil and best_angle <= ARROW_BIG_ANGLE then return best_angle_hp, count end
    return best_hp, count
end

------------------------------------------------------------------------------
-- Minecraft hits as RE4 hits: the enemy reacts (flinches, staggers) through RE4's own hit code.
-- A chainsaw.HitController.DamageInfo is filled like RE4 fills one for Leon's knife and handed to the enemy's
-- HitController.callbackDamageHit. Which way of filling it works is found by the Flinch test in
-- minecraft_diagnostics.lua (it calls this same code) and saved in reframework\data\minecraft_flinch.json:
--   "template"    numbers and attack data copied from RE4's last real hit on an enemy (knife/kick/shot)
--   "last_attack" the attack data of the last real attack that hit this enemy
--   "fresh"       a new, default attack data
------------------------------------------------------------------------------

local FLINCH_FILE = "minecraft_flinch.json"
local FLINCH_COOLDOWN_FRAMES = 30     -- one reaction per enemy at most every half second
local FLINCH_WINCE, FLINCH_STOPPING = 100.0, 100.0   -- used when no real hit was seen to copy from

local HIT = {
    method = nil,            -- the way that works on this PC (from the Flinch test), or nil (not tested)
    template = nil,          -- copy of RE4's last real hit on an enemy
    building = false,        -- our own callbackDamageHit is running (not a real hit)
    failures = 0,
    last_flinch = {},        -- enemy body address -> frame
    pool = {}, pool_next = 1,
    status = "not tested yet (Minecraft Diagnostics -> Flinch test)",
}
MinecraftRE4Hit = HIT        -- shared with minecraft_diagnostics.lua

do
    local ok, saved = pcall(json.load_file, FLINCH_FILE)
    if ok and type(saved) == "table" and saved.works == true and type(saved.method) == "string" then
        HIT.method = saved.method
        HIT.status = "on (" .. saved.method .. ", tested " .. tostring(saved.time or "?") .. ")"
    end
end

local hit_controller_type = sdk.typeof("chainsaw.HitController")
local colliders_type_name = "via.physics.Colliders"

local function address_of(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

local function enemy_bodies()
    local out = {}
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local body = enemy and try_call(enemy, "get_BodyGameObject")
        local a = body and address_of(body)
        if a ~= nil then out[a] = enemy end
    end
    return out
end

-- RE4's own hits on enemies: keep a copy of the last one (its numbers and attack data are the model for ours)
pcall(function()
    local td = sdk.find_type_definition("chainsaw.HitController")
    local m = td and td:get_method("callbackDamageHit(chainsaw.HitController.DamageInfo)")
    if m == nil then return end
    sdk.hook(m, function(args)
        if HIT.building then return end
        pcall(function()
            local hc = sdk.to_managed_object(args[2])
            local info = sdk.to_managed_object(args[3])
            local go = hc and try_call(hc, "get_GameObject")
            local a = go and address_of(go)
            if a == nil or info == nil or enemy_bodies()[a] == nil then return end
            local copy = info:call("MemberwiseClone")
            if copy ~= nil then
                pcall(function() copy:add_ref() end)
                HIT.template = copy
            end
        end)
    end, function(retval) return retval end)
end)

-- A DamageInfo of our own, reused round-robin (RE4 may hold on to one for a moment)
local function new_damage_info()
    local slot = HIT.pool_next
    HIT.pool_next = slot % 4 + 1
    local info = HIT.pool[slot]
    if info == nil then
        info = sdk.create_instance("chainsaw.HitController.DamageInfo")
        if info == nil then return nil end
        pcall(function() info:add_ref() end)
        info:call(".ctor")
        HIT.pool[slot] = info
    else
        try_call(info, "clear")
    end
    return info
end

-- The enemy's damage colliders' data (which body part was hit): the first one found
local function damage_user_data(body)
    local comps = try_call(body, "get_Components")
    local ok, elems = pcall(function() return comps:get_elements() end)
    if not ok or elems == nil then return nil end
    for _, comp in ipairs(elems) do
        local okt, tn = pcall(function() return comp:get_type_definition():get_full_name() end)
        if okt and tn == colliders_type_name then
            local n = try_call(comp, "get_NumColliders") or 0
            for i = 0, n - 1 do
                local collider = try_call(comp, "getColliders", i)
                local ud = collider and try_call(collider, "get_UserData")
                local okn, un = pcall(function() return ud:get_type_definition():get_full_name() end)
                if okn and un ~= nil and un:find("DamageUserData", 1, true) then return ud end
            end
        end
    end
    return nil
end

local function set(obj, method, value)
    return pcall(function() obj:call(method, value) end)
end

-- Make this enemy react to a hit coming from from_pos, the way `method` fills the hit. Returns ok, message.
function HIT.flinch(enemy, method, from_pos)
    method = method or HIT.method
    if method == nil then return false, "no working method known" end
    local body = try_call(enemy, "get_BodyGameObject")
    local hc = body and try_call(body, "getComponent(System.Type)", hit_controller_type)
    local tr = body and try_call(body, "get_Transform")
    local epos = tr and try_call(tr, "get_Position")
    if hc == nil or epos == nil then return false, "enemy has no HitController" end
    local leon = get_player()
    local leon_body = leon and try_call(leon.ctx, "get_BodyGameObject")
    from_pos = from_pos or (leon and leon.transform and try_call(leon.transform, "get_Position")) or epos
    local hit_pos = Vector3f.new(epos.x, epos.y + 1.2, epos.z)
    local dir = hit_pos - Vector3f.new(from_pos.x, from_pos.y + 1.2, from_pos.z)
    local len = dir:length()
    dir = len > 0.01 and Vector3f.new(dir.x / len, dir.y / len, dir.z / len) or Vector3f.new(0, 0, 1)

    local attack, wince, stopping, brk = nil, FLINCH_WINCE, FLINCH_STOPPING, 0.0
    if method == "template" then
        local t = HIT.template
        if t == nil then return false, "no real hit seen yet to copy" end
        attack = try_call(t, "get_AttackData")
        wince = try_call(t, "get_Wince") or wince
        stopping = try_call(t, "get_Stopping") or stopping
        brk = try_call(t, "get_Break") or brk
    elseif method == "last_attack" then
        attack = try_call(enemy, "get_LastAttackData")
        if attack == nil then return false, "this enemy has no last attack data" end
    else
        attack = sdk.create_instance("chainsaw.collision.AttackHitUserData.AttackData")
        if attack ~= nil then
            pcall(function() attack:add_ref() end)
            try_call(attack, ".ctor")
        end
    end

    local info = new_damage_info()
    if info == nil then return false, "could not create a DamageInfo" end
    set(info, "set_Damage", 1)
    set(info, "set_Wince", wince)
    set(info, "set_Stopping", stopping)
    set(info, "set_Break", brk)
    set(info, "set_DamageDir", dir)
    set(info, "set_IsActive", true)
    set(info, "set_Position", hit_pos)
    set(info, "set_Normal", Vector3f.new(-dir.x, -dir.y, -dir.z))
    set(info, "set_DamageGameObject", body)
    if leon_body ~= nil then
        set(info, "set_AttackOwnerObject", leon_body)
        set(info, "set_AttackGameObject", leon_body)
    end
    if attack ~= nil then set(info, "set_AttackData", attack) end
    local ud = damage_user_data(body)
    if ud ~= nil then set(info, "set_DamageUserData", ud) end

    HIT.building = true
    local ok, err = pcall(function() hc:call("callbackDamageHit(chainsaw.HitController.DamageInfo)", info) end)
    HIT.building = false
    if not ok then return false, "callbackDamageHit failed: " .. tostring(err) end
    return true, "ok"
end

-- After a Minecraft hit landed on this enemy (HitPoint hp): its reaction, if a working way is known
local function flinch_after_hit(hp, from_pos)
    if not settings.flinch or HIT.method == nil or hp == nil or not enemy_alive(hp) then return end
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local hp_address = address_of(hp)
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local ehp = enemy and try_call(enemy, "get_HitPoint")
        if ehp ~= nil and address_of(ehp) == hp_address then
            local body = try_call(enemy, "get_BodyGameObject")
            local key = body and address_of(body)
            if key ~= nil and state.frame - (HIT.last_flinch[key] or -1000) >= FLINCH_COOLDOWN_FRAMES then
                HIT.last_flinch[key] = state.frame
                local ok, msg = HIT.flinch(enemy, HIT.method, from_pos)
                if ok then
                    HIT.failures = 0
                else
                    HIT.failures = HIT.failures + 1
                    if HIT.failures >= 3 then
                        HIT.method = nil
                        HIT.status = "off: it stopped working (" .. tostring(msg) .. ")"
                    end
                end
            end
            return
        end
    end
end

-- damage is in Minecraft half-hearts; RE4 enemies lose damage/(their Minecraft health) of their max health
local function damage_enemy(hp, damage, note, from_pos)
    local current = try_call(hp, "get_CurrentHitPoint") or 0
    local max = try_call(hp, "get_DefaultHitPoint") or current
    local health = mob_health(max)
    local result = apply_re4_damage(hp, max * damage / health)
    debug.combat = string.format("hit for %.1f%s: %s (as a %d-health mob)", damage, note, result, math.floor(health))
    local ok, err = pcall(flinch_after_hit, hp, from_pos)
    if not ok then HIT.status = "error: " .. tostring(err) end
end

local function hit_enemy(damage, note)
    local hp, count = find_target()
    if hp == nil then
        debug.combat = string.format("swing, no enemy in reach (%d enemies loaded)", count or 0)
        return
    end
    damage_enemy(hp, damage, note)
end

-- The enemy with this key (its address, see minecraft_terrain.lua)
local function enemy_hp_by_key(key)
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local ok, address = pcall(function() return enemy:get_address() end)
        if ok and tostring(address) == key then return try_call(enemy, "get_HitPoint") end
    end
    return nil
end

-- Minecraft mobs (iron golems, wolves...) and your sword hit RE4 enemies through their Minecraft
-- stand-ins; Minecraft sends the total damage per enemy, apply what is new
local enemy_damage_seen = nil   -- key -> total already applied; the first read is from before we started
local function update_enemy_damage()
    local totals = bridge.enemy_damage
    if type(totals) ~= "table" then return end
    local first = enemy_damage_seen == nil
    enemy_damage_seen = enemy_damage_seen or {}
    -- where each fighting mob is (its hit comes from there)
    local mobs = {}
    if type(bridge.engaged) == "string" then
        for key, x, y, z in bridge.engaged:gmatch("([^,;]+),([^,;]+),([^,;]+),([^,;]+);") do
            local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
            if px ~= nil and py ~= nil and pz ~= nil then mobs[key] = Vector3f.new(px, py - 1.2, pz) end
        end
    end
    for key, total in pairs(totals) do
        local before = enemy_damage_seen[key] or (first and total or 0)
        enemy_damage_seen[key] = total
        if type(total) == "number" and total > before then
            local hp = enemy_hp_by_key(key)
            if enemy_alive(hp) then damage_enemy(hp, total - before, " (in Minecraft)", mobs[key]) end
        end
    end
end

-- RE4 enemies that a Minecraft mob is fighting look at that mob, with the enemy's own look-at (the one RE4
-- uses to make an enemy watch something): Minecraft sends "key,x,y,z;" per fight, with the mob's eyes in RE4
-- coordinates. The look is let go when the fight ends, the enemy dies, or RE4 takes over (cutscenes, menus).
local attention = {}   -- enemy key -> { look = { comp, set, clear } or false, looked_up = frame }
local LOOK_REFRESH_FRAMES = 2
local LOOK_RETRY_FRAMES = 300

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

-- The component of this enemy that has RE4's "look at this point" (enemies' body updaters), or false
local look_methods = {}   -- component type name -> { set, clear } or false (looked up once per type)

local function body_address(enemy)
    local body = try_call(enemy, "get_BodyGameObject")
    local ok, address = pcall(function() return body:get_address() end)
    return ok and address or nil
end

local function look_handle(enemy)
    local body = try_call(enemy, "get_BodyGameObject")
    local comps = body and try_call(body, "get_Components")
    local ok, elems = pcall(function() return comps:get_elements() end)
    if not ok or elems == nil then return false end
    for _, comp in ipairs(elems) do
        local okt, td = pcall(function() return comp:get_type_definition() end)
        local okn, name = pcall(function() return td:get_full_name() end)
        if okt and okn and name ~= nil then
            local m = look_methods[name]
            if m == nil then
                local set = find_method_in(td, "setForceLookAtTarget(via.vec3)")
                m = set ~= nil and { set = set, clear = find_method_in(td, "clearForceLookAtTarget") } or false
                look_methods[name] = m
            end
            if m then return { comp = comp, set = m.set, clear = m.clear } end
        end
    end
    return false
end

local function let_go(a)
    if a.look and a.look.clear then pcall(function() a.look.clear:call(a.look.comp) end) end
end

-- Body addresses of every enemy RE4 still has (living or dead): only those enemies' parts are touched
local function present_bodies()
    local out = {}
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local address = enemy and body_address(enemy)
        if address ~= nil then out[address] = true end
    end
    return out
end

-- Let every enemy look where RE4 wants again (cutscenes, menus, combat off). Enemies RE4 no longer has
-- are left alone: their parts may already be freed.
local function release_attention()
    if next(attention) == nil then return end
    local present = present_bodies()
    for key, a in pairs(attention) do
        if a.body ~= nil and present[a.body] then let_go(a) end
        attention[key] = nil
    end
    debug.attention = "no fights"
end

-- The living enemies right now: key -> enemy context
local function living_enemies()
    local out = {}
    local cm = get_character_manager()
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local ok, address = pcall(function() return enemy:get_address() end)
        if ok and address ~= nil and enemy_alive(try_call(enemy, "get_HitPoint")) then out[tostring(address)] = enemy end
    end
    return out
end

local function update_enemy_attention()
    local wanted, count = {}, 0
    if settings.enemies_look_at_mobs and type(bridge.engaged) == "string" then
        for key, x, y, z in bridge.engaged:gmatch("([^,;]+),([^,;]+),([^,;]+),([^,;]+);") do
            local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
            if px ~= nil and py ~= nil and pz ~= nil then
                wanted[key] = Vector3f.new(px, py, pz)
                count = count + 1
            end
        end
    end
    -- Fights that ended
    local ended = false
    for key in pairs(attention) do
        if wanted[key] == nil then ended = true end
    end
    if ended then
        local present = present_bodies()
        for key, a in pairs(attention) do
            if wanted[key] == nil then
                if a.body ~= nil and present[a.body] then let_go(a) end
                attention[key] = nil
            end
        end
    end
    if count == 0 then
        debug.attention = "no fights"
        return
    end
    if state.frame % LOOK_REFRESH_FRAMES ~= 0 then return end

    local living = living_enemies()
    local present = nil
    local looking = 0
    for key, target in pairs(wanted) do
        local enemy = living[key]
        local a = attention[key]
        if enemy == nil then
            -- dead: let go once; gone: leave its parts alone
            if a ~= nil then
                present = present or present_bodies()
                if a.body ~= nil and present[a.body] then let_go(a) end
            end
            attention[key] = nil
        else
            local body = body_address(enemy)
            if a ~= nil and a.body ~= body then
                attention[key] = nil   -- a different enemy now has this address: its old handle is not touched
                a = nil
            end
            if a == nil or (a.look == false and state.frame - a.looked_up > LOOK_RETRY_FRAMES) then
                a = { look = look_handle(enemy), looked_up = state.frame, body = body }
                attention[key] = a
            end
            if a.look then
                if pcall(function() a.look.set:call(a.look.comp, target) end) then
                    looking = looking + 1
                else
                    let_go(a)          -- undo an earlier look before giving up on this handle
                    a.look = false
                end
            end
        end
    end
    debug.attention = string.format("%d enemies fighting Minecraft mobs, %d looking at them", count, looking)
end

local function shoot_enemy(damage, note)
    local hp, count = find_ranged_target()
    if hp == nil then
        debug.combat = string.format("arrow missed (%d enemies loaded)", count or 0)
        return
    end
    damage_enemy(hp, damage, note)
end

-- Minecraft calculated an attack (cooldown, weapon, crits); apply it when a new one shows up
local function update_minecraft_combat()
    update_enemy_damage()
    local control = MinecraftRE4Control
    if type(control) == "table" and control.mode == "re4" then
        release_attention()   -- cutscenes, grabs, menus: RE4's own scenes decide where enemies look
    else
        update_enemy_attention()
    end

    -- Melee: a new attack calculated by Minecraft (the first one seen is from before we started)
    local attack = bridge.attack
    if type(attack) == "table" and attack.seq ~= nil then
        if state.last_attack_seq == nil then
            state.last_attack_seq = attack.seq
        elseif attack.seq ~= state.last_attack_seq then
            state.last_attack_seq = attack.seq
            local note = string.format(" (Minecraft, charge %d%%%s)", math.floor((attack.strength or 0) * 100),
                attack.crit and ", critical!" or "")
            hit_enemy(attack.damage or 0, note)
        end
    end

    -- Arrows from bows and crossbows, with Minecraft's arrow damage
    local shot = bridge.shot
    if type(shot) == "table" and shot.seq ~= nil then
        if state.last_shot_seq == nil then
            state.last_shot_seq = shot.seq
        elseif shot.seq ~= state.last_shot_seq then
            state.last_shot_seq = shot.seq
            shoot_enemy(shot.damage or 0, shot.crit and " (arrow, critical!)" or " (arrow)")
        end
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
------------------------------------------------------------------------------
-- Movement recorder: saves ~2 seconds of Leon's position at each step of the frame,
-- to reframework\data\minecraft_movement_probe.json
------------------------------------------------------------------------------

local PROBE_FILE = "minecraft_movement_probe.json"
local PROBE_FRAMES = 120
local probe_status = "not recorded yet"

local function vec(v)
    if v == nil then return nil end
    return { x = math.floor(v.x * 1000) / 1000, y = math.floor(v.y * 1000) / 1000, z = math.floor(v.z * 1000) / 1000 }
end

local function probe_set(name, value)
    if state.probe ~= nil then state.probe.sample[name] = value end
end

local function start_probe()
    state.probe = { samples = {}, sample = {} }
    probe_status = "recording... keep walking"
end

local function finish_probe_frame()
    if state.probe == nil then return end
    local sample = state.probe.sample
    for k, v in pairs(sample) do
        if type(v) == "userdata" then sample[k] = vec(v) end
    end
    sample.mode = debug.mode
    sample.movement = debug.movement
    sample.ground = debug.ground
    if bridge ~= nil then sample.mc_move = bridge.move; sample.mc_keys = bridge.keys end
    table.insert(state.probe.samples, sample)
    state.probe.sample = {}
    if #state.probe.samples >= PROBE_FRAMES then
        local ok, written = pcall(json.dump_file, PROBE_FILE, state.probe.samples)
        probe_status = (ok and written ~= false) and ("saved to reframework\\data\\" .. PROBE_FILE) or "could not save"
        state.probe = nil
    end
end

------------------------------------------------------------------------------
-- Main update
------------------------------------------------------------------------------

-- Where Leon is before RE4 moves him this frame
re.on_pre_application_entry("UpdateBehavior", function()
    state.frame = state.frame + 1
    local player = get_player()
    state.frame_start_pos = player and player.transform and try_call(player.transform, "get_Position")
    state.controlling = false
    probe_set("start", state.frame_start_pos)

    -- Leon just appeared (save loaded): let the game finish placing him and loading the area
    if state.frame_start_pos == nil then
        state.player_present = false
        return
    end
    if not state.player_present then
        state.player_present = true
        state.settle_until = state.frame + SETTLE_FRAMES_AFTER_LOAD
        state.auth_pos = nil
    end

    -- The game moved Leon far in one frame (loading, cutscene, door): drop our hold on him
    local held = state.auth_pos
    if held ~= nil then
        local dx, dy, dz = held.x - state.frame_start_pos.x, held.y - state.frame_start_pos.y, held.z - state.frame_start_pos.z
        if dx * dx + dy * dy + dz * dz > TELEPORT_DISTANCE * TELEPORT_DISTANCE then
            state.auth_pos = nil
            state.settle_until = state.frame + SETTLE_FRAMES_AFTER_TELEPORT
        end
    end
end)

-- Right after RE4's collision check: this is where Leon should stay for the rest of the frame
re.on_application_entry("UpdatePhysicsCharacterController", function()
    if not state.controlling then
        state.auth_pos = nil
        return
    end
    local player = get_player()
    state.auth_pos = player and player.transform and try_call(player.transform, "get_Position")
    probe_set("after_collision", state.auth_pos)
end)

-- RE4 moves Leon again late in the frame (its own walking); put him back where we had him
re.on_application_entry("LateUpdateBehavior", function()
    local player = get_player()
    local current = player and player.transform and try_call(player.transform, "get_Position")
    probe_set("late_by_re4", current)
    if state.controlling and state.auth_pos ~= nil and current ~= nil then
        local y = state.vy ~= nil and state.auth_pos.y or current.y
        local fixed = Vector3f.new(state.auth_pos.x, y, state.auth_pos.z)
        try_call(player.transform, "set_Position", fixed)
        state.auth_pos = fixed
        probe_set("final", fixed)
    end
    finish_probe_frame()
end)

-- Right before RE4's collision check
re.on_pre_application_entry("UpdatePhysicsCharacterController", function()
    read_bridge()
    read_sent_look()
    local player = get_player()
    if player == nil then
        release_attention()   -- loading, game over, menus without Leon: let go while the enemies still exist
        return
    end
    local dt = get_delta_time(player)
    state.time = state.time + dt

    if settings.no_damage then keep_full_health(player) end
    local control = MinecraftRE4Control
    local re4_has_leon = type(control) == "table" and control.mode ~= "minecraft"

    if state.frame < state.settle_until then
        -- Give everything back to the game while it loads or teleports Leon (cutscenes often start here)
        release_attention()
        set_vertical(player, nil)
        if state.flying then set_flying(player, false) end
        state.velocity = Vector3f.new(0, 0, 0)
        state.predicted_jump_time = nil
        state.smooth_y = nil
        state.floor_y = nil
        debug.movement = "waiting for the game to place Leon (loading/teleport)"
        return
    end

    if minecraft_in_control() then
        debug.mode = "Minecraft (movement and attacks come from Minecraft)"
        if state.flying then set_flying(player, false) end
        if re4_has_leon then
            set_vertical(player, nil)
            debug.movement = "RE4 has Leon (" .. tostring(control.reason) .. ")"
        elseif settings.movement then
            update_from_minecraft(player, dt)
        else
            set_vertical(player, nil)
            debug.movement = "off"
        end
        if settings.combat then update_minecraft_combat() else release_attention() end
        return
    end
    release_attention()

    debug.mode = "built-in (Minecraft not connected)"
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

    if re4_has_leon then
        if state.flying then set_flying(player, false) end
        debug.movement = "RE4 has Leon (" .. tostring(control.reason) .. ")"
    elseif state.flying then
        update_builtin_flying(player, dt)
    elseif settings.movement then
        update_builtin_walking(player, dt)
    else
        debug.movement = "off"
    end

    if settings.combat and mouse_clicked() then builtin_attack() end
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Gameplay") then
        local changed
        changed, settings.movement = imgui.checkbox("Minecraft movement", settings.movement)
        changed, settings.combat = imgui.checkbox("Melee combat (left-click)", settings.combat)
        changed, settings.enemies_look_at_mobs = imgui.checkbox("Enemies look at the Minecraft mobs fighting them", settings.enemies_look_at_mobs)
        changed, settings.flinch = imgui.checkbox("Enemies flinch at Minecraft hits", settings.flinch)
        imgui.text("  Flinch: " .. HIT.status)
        changed, settings.no_damage = imgui.checkbox("No damage", settings.no_damage)
        changed, settings.swap_left_right = imgui.checkbox("Swap left/right (if A and D are backwards)", settings.swap_left_right)
        changed, settings.fly_speed = imgui.slider_float("Fly speed without Minecraft (m/s)", settings.fly_speed, 2.0, 40.0)
        imgui.text("Mode: " .. debug.mode)
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            if imgui.button("Record movement (2 s)") then start_probe() end
            imgui.same_line()
            imgui.text(probe_status)
            imgui.text("Player: " .. debug.player)
            imgui.text("Movement: " .. debug.movement)
            imgui.text("Ground: " .. debug.ground)
            imgui.text("Combat: " .. debug.combat)
            imgui.text("Mob fights: " .. debug.attention)
            imgui.text("Held item: " .. tostring(held_item_id()))
            imgui.text("Health: " .. debug.damage)
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    release_attention()   -- let go of every enemy's look
    local player = get_player()
    if player == nil then return end
    if player.controller ~= nil then try_call(player.controller, "set_Enabled", true) end
    set_gravity(player, true)
end)
