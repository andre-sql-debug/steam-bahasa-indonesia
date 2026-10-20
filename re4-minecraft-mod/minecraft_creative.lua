-- Minecraft Creative Mode for RE4 Remake (REFramework Lua script)
-- Flying (double-tap Space or F6) and no damage, like Minecraft Creative.
-- While flying: WASD = move, Space = up, Ctrl = down, Shift = fly faster.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Creative

local settings = {
    enabled = true,
    no_damage = true,
    fly_speed = 0.08,      -- meters per frame
    fast_multiplier = 3.0,
    show_debug = false,
}

local KEY = {
    SPACE = 0x20, LCTRL = 0xA2, LSHIFT = 0xA0, F6 = 0x75,
    W = 0x57, A = 0x41, S = 0x53, D = 0x44,
}
local DOUBLE_TAP_FRAMES = 18   -- ~0.3 s at 60 fps

local PLAYER_OBJECT_METHODS = { "get_BodyGameObject", "get_GameObject", "get_PlayerGameObject" }

local debug = {
    player = "not checked yet",
    controller = "not checked yet",
    damage = "not checked yet",
    position = "",
}

local flying = false
local fly_pos = nil
local controller = nil
local controller_owner = nil
local frame = 0
local last_space_frame = -100
local keys_was_down = {}

local controller_type = sdk.typeof("via.physics.CharacterController")

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result, true end
    return nil, false
end

local function is_down(key)
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    return ok and down
end

-- True only on the frame the key goes down
local function pressed(key)
    local down = is_down(key)
    local was = keys_was_down[key]
    keys_was_down[key] = down
    return down and not was
end

local function get_player_context()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if cm == nil then
        debug.player = "CharacterManager not found"
        return nil
    end
    local ctx = try_call(cm, "getPlayerContextRef")
    if ctx == nil then
        debug.player = "player context not found (in a menu?)"
    end
    return ctx
end

local function get_player_object(ctx)
    for _, method in ipairs(PLAYER_OBJECT_METHODS) do
        local obj = try_call(ctx, method)
        if obj ~= nil then
            debug.player = "found via " .. method
            return obj
        end
    end
    debug.player = "player object not found"
    return nil
end

-- Gravity and floor collision come from the character controller, so it's off while flying
local function set_controller_enabled(player, enabled)
    if controller == nil or controller_owner ~= player then
        controller_owner = player
        controller = try_call(player, "getComponent(System.Type)", controller_type)
        if controller == nil then
            debug.controller = "CharacterController not found"
            return
        end
    end
    try_call(controller, "set_Enabled", enabled)
    debug.controller = enabled and "on (walking)" or "off (flying)"
end

local function set_flying(player, transform, on)
    if on == flying then return end
    flying = on
    if on then
        fly_pos = try_call(transform, "get_Position")
        if fly_pos == nil then
            flying = false
            return
        end
    end
    set_controller_enabled(player, not on)
end

-- Horizontal camera direction, so W flies where you look
local function get_camera_vectors()
    local camera = sdk.get_primary_camera()
    local cam_obj = camera and try_call(camera, "get_GameObject")
    local cam_transform = cam_obj and try_call(cam_obj, "get_Transform")
    local rot = cam_transform and try_call(cam_transform, "get_Rotation")
    if rot == nil then return nil end

    local ok, f = pcall(function() return rot * Vector3f.new(0, 0, -1) end)
    if not ok or f == nil then return nil end

    local len = math.sqrt(f.x * f.x + f.z * f.z)
    if len < 0.001 then return nil end
    local forward = Vector3f.new(f.x / len, 0, f.z / len)
    local right = Vector3f.new(-forward.z, 0, forward.x)
    return forward, right
end

local function update_flying(transform)
    local forward, right = get_camera_vectors()
    local move = Vector3f.new(0, 0, 0)

    if forward ~= nil then
        if is_down(KEY.W) then move = move + forward end
        if is_down(KEY.S) then move = move - forward end
        if is_down(KEY.D) then move = move + right end
        if is_down(KEY.A) then move = move - right end
    end
    if is_down(KEY.SPACE) then move = move + Vector3f.new(0, 1, 0) end
    if is_down(KEY.LCTRL) then move = move - Vector3f.new(0, 1, 0) end

    local speed = settings.fly_speed
    if is_down(KEY.LSHIFT) then speed = speed * settings.fast_multiplier end

    fly_pos = fly_pos + move * speed
    try_call(transform, "set_Position", fly_pos)
    debug.position = string.format("%.1f, %.1f, %.1f", fly_pos.x, fly_pos.y, fly_pos.z)
end

local function keep_full_health(ctx)
    local hp = try_call(ctx, "get_HitPoint")
    if hp == nil then
        debug.damage = "HitPoint not found"
        return
    end
    local max = try_call(hp, "get_DefaultHitPoint")
    local current = try_call(hp, "get_CurrentHitPoint")
    if max == nil or current == nil then
        debug.damage = "HP values not found"
        return
    end
    if current < max then
        try_call(hp, "set_CurrentHitPoint", max)
        if (try_call(hp, "get_CurrentHitPoint") or 0) < max then
            pcall(function() hp:set_field("<CurrentHitPoint>k__BackingField", max) end)
        end
        local now = try_call(hp, "get_CurrentHitPoint") or 0
        debug.damage = now >= max and "healing" or "could not set HP"
    else
        debug.damage = "full health"
    end
end

-- Runs after the game has moved Leon, so our flying position wins
re.on_application_entry("LateUpdateBehavior", function()
    frame = frame + 1

    local ctx = get_player_context()
    if ctx == nil then return end

    if settings.enabled and settings.no_damage then
        keep_full_health(ctx)
    end

    local player = get_player_object(ctx)
    local transform = player and try_call(player, "get_Transform")
    if transform == nil then return end

    if not settings.enabled then
        set_flying(player, transform, false)
        return
    end

    local toggle = pressed(KEY.F6)
    if pressed(KEY.SPACE) then
        if frame - last_space_frame <= DOUBLE_TAP_FRAMES then
            toggle = true
            last_space_frame = -100
        else
            last_space_frame = frame
        end
    end
    if toggle then
        set_flying(player, transform, not flying)
    end

    if flying then
        update_flying(transform)
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Creative") then
        local changed
        changed, settings.enabled = imgui.checkbox("Enabled", settings.enabled)
        changed, settings.no_damage = imgui.checkbox("No damage", settings.no_damage)
        changed, settings.fly_speed = imgui.slider_float("Fly speed", settings.fly_speed, 0.01, 0.5)
        changed, settings.fast_multiplier = imgui.slider_float("Shift speed multiplier", settings.fast_multiplier, 1.0, 10.0)
        imgui.text(flying and "Flying (double-tap Space or F6 to land)" or "Walking (double-tap Space or F6 to fly)")
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Player: " .. debug.player)
            imgui.text("Controller: " .. debug.controller)
            imgui.text("No damage: " .. debug.damage)
            if debug.position ~= "" then imgui.text("Position: " .. debug.position) end
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    if controller ~= nil then
        try_call(controller, "set_Enabled", true)
    end
end)
