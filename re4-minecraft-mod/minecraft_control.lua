-- Minecraft Control for RE4 Remake (REFramework Lua script)
-- Decides, every frame, who is in charge of Leon, so the story can be played from start to end:
--   "minecraft"  Minecraft moves Leon (walking, jumping, fighting, building).
--   "re4_moves"  RE4 moves Leon: ladders, windows, jumping down, doors, kicks, being knocked back,
--                elevators, the boat and other rides. Minecraft's camera, picture and mouse stay (shoot
--                your bow from the boat); RE4 gets the movement keys (steering the boat); Leon stays
--                hidden. When it's over, Minecraft's player is put where Leon ended up.
--   "re4"        RE4's turn: cutscenes, grabs and QTEs, talking (merchant), radio calls, menus
--                (Tab / I / M / Esc), loading, and F7. RE4's own camera, mouse, keys and UI; Leon is
--                shown and Minecraft's picture is hidden.
-- The other Minecraft scripts read the result from the global MinecraftRE4Control.
-- It reads RE4's own player flags (chainsaw.PlayerBaseContext), so it knows exactly what Leon is doing.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Control

local settings = {
    auto = true,          -- hand Leon to RE4 automatically for its actions and scenes
    calm_frames = 8,      -- an action must be over for this many frames before Minecraft takes Leon again
    show_debug = false,
}

-- RE4 plays the scene: its camera, mouse, keys and UI
local SCENE_FLAGS = {
    "get_IsEventLocked",        -- cutscenes and scripted events
    "isGrappled",               -- an enemy grabbed Leon (QTE)
    "get_IsInGrappleDamage",
    "get_IsJacked",
    "get_IsTalkActing",         -- merchant and other talks
    "get_IsWirelessCall",       -- radio calls
}

-- RE4 moves Leon for a moment; Minecraft's camera stays
local MOVE_FLAGS = {
    "get_IsBoat",               -- RE4 steers the boat, you aim and shoot with Minecraft
    "get_IsMoveGimmickRide",    -- mine cart and other rides
    "get_IsLadder",
    "get_IsTerrainAction",
    "get_IsTerrainAction_2m",
    "get_IsTerrainAction_Jump",
    "get_IsTerrainAction_Window",
    "get_IsTerrainUpWithPartner",
    "get_IsTerrainUpWithPartner_1m",
    "get_IsDoorPass",
    "get_IsOpenDoubleDoor",
    "get_IsHookShot",
    "get_IsInsideElevator",
    "get_IsLiftActing",
    "get_IsDamaging",
    "get_IsFatalKick",
    "get_IsFatalKill",
    "get_IsFatalRoundKick",
}

local KEY = { F7 = 0x76, TAB = 0x09, I = 0x49, M = 0x4D, ESC = 0x1B }
local MENU_KEYS = { KEY.TAB, KEY.I, KEY.M, KEY.ESC }

local control = {
    mode = "re4",         -- see above
    reason = "starting",
    leon_present = false,
    menu = false,         -- an RE4 menu is (probably) open
    manual = false,       -- F7: everything to RE4
    frame = 0,
    flags = {},           -- flag name -> true, for the debug panel
}
MinecraftRE4Control = control

local keys_was = {}
local calm = 0
local missing_methods = {}   -- methods this RE4 version doesn't have
local failures = {}          -- method -> calls failed in a row (a call can fail while a level loads)
local MISSING_AFTER = 600
local menu_leon_pos = nil

local function key_pressed(key)
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    down = ok and down == true
    local was = keys_was[key]
    keys_was[key] = down
    return down and not was
end

local function player_context()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if cm == nil then return nil end
    local ok, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
    if ok then return ctx end
    return nil
end

-- A flag of Leon's context; unknown methods (other characters, game updates) count as false
local function flag(ctx, method)
    if missing_methods[method] then return false end
    local ok, value = pcall(function() return ctx:call(method) end)
    if not ok then
        failures[method] = (failures[method] or 0) + 1
        if failures[method] >= MISSING_AFTER then missing_methods[method] = true end
        return false
    end
    failures[method] = nil
    return value == true
end

local function first_flag(ctx, list)
    for _, method in ipairs(list) do
        if flag(ctx, method) then return method end
    end
    return nil
end

local function leon_position(ctx)
    local ok, pos = pcall(function()
        return ctx:call("get_BodyGameObject"):call("get_Transform"):call("get_Position")
    end)
    if ok then return pos end
    return nil
end

re.on_pre_application_entry("UpdateBehavior", function()
    control.frame = control.frame + 1
    if key_pressed(KEY.F7) then control.manual = not control.manual end

    local ctx = player_context()
    control.leon_present = ctx ~= nil
    local pos = ctx and leon_position(ctx)

    -- Menus pause the game; RE4 needs the keys and mouse there. A menu key opens or closes it, and if
    -- Leon walks while we think a menu is open, it was closed some other way.
    local menu_key = false
    for _, key in ipairs(MENU_KEYS) do
        if key_pressed(key) then menu_key = true end
    end
    if menu_key and control.leon_present then
        control.menu = not control.menu
        menu_leon_pos = pos
    end
    if control.menu then
        if not control.leon_present then
            control.menu = false
        elseif pos ~= nil and menu_leon_pos ~= nil and (pos - menu_leon_pos):length() > 0.3 then
            control.menu = false
        end
    end

    control.flags = {}
    local scene, move = nil, nil
    if ctx ~= nil and settings.auto then
        scene = first_flag(ctx, SCENE_FLAGS)
        move = first_flag(ctx, MOVE_FLAGS)
        if scene then control.flags[scene] = true end
        if move then control.flags[move] = true end
    end

    local mode, reason
    if not control.leon_present then
        mode, reason = "re4", "no Leon (menu or loading)"
    elseif control.manual then
        mode, reason = "re4", "F7"
    elseif control.menu then
        mode, reason = "re4", "menu"
    elseif scene then
        mode, reason = "re4", scene
    elseif move then
        mode, reason = "re4_moves", move
    else
        mode, reason = "minecraft", "Minecraft"
    end

    -- Hand Leon to RE4 at once; take him back only after things have been calm for a few frames
    if mode == "minecraft" and control.mode ~= "minecraft" then
        calm = calm + 1
        if calm < settings.calm_frames then return end
    end
    calm = 0
    control.mode = mode
    control.reason = reason
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Control") then
        local changed
        changed, settings.auto = imgui.checkbox("Give Leon to RE4 for ladders, doors, cutscenes, grabs...", settings.auto)
        changed, control.manual = imgui.checkbox("Everything to RE4 (F7)", control.manual)
        imgui.text("In charge: " .. control.mode .. "  (" .. control.reason .. ")")
        imgui.text("Menu open: " .. tostring(control.menu) .. "  (Tab / I / M / Esc)")
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            changed, settings.calm_frames = imgui.slider_int("Calm frames before Minecraft takes over", settings.calm_frames, 1, 60)
            local missing = {}
            for name in pairs(missing_methods) do table.insert(missing, name) end
            table.sort(missing)
            imgui.text("Flags not found: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
        end
        imgui.tree_pop()
    end
end)
