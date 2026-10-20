-- Minecraft Bridge HUD for RE4 Remake (REFramework Lua script)
-- Draws Minecraft's HUD (hotbar, hearts, hunger, XP, held item) using live data from Minecraft,
-- and sends RE4 input back to Minecraft: movement keys (Minecraft moves its player with them and
-- minecraft_gameplay.lua copies that movement to Leon), 1-9 select a hotbar slot, left-click attacks.
-- Needs the RE4 Bridge Minecraft mod, which writes reframework\data\minecraft_bridge.json
-- and reads reframework\data\minecraft_bridge_input.json.
-- When Minecraft isn't connected, the hearts show Leon's health instead.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft HUD

local settings = {
    enabled = true,
    scale = 0,                  -- 0 = auto (based on screen height)
    survival_bars_in_creative = false,
    held_item = true,
    send_input = true,
    hide_re4_ui = true,
    show_debug = false,
}

local BRIDGE_FILE = "minecraft_bridge.json"   -- relative to reframework\data
local READ_EVERY_FRAMES = 2
local DISCONNECT_FRAMES = 120                  -- no new data for ~2 s = disconnected

local data = nil
local last_seq = nil
local frames_since_change = math.huge
local frame = 0
local leon_hp_info = "not checked yet"

-- Colors for draw.* are 0xAABBGGRR
local function rgb(r, g, b, a)
    return ((a or 255) << 24) | (b << 16) | (g << 8) | r
end

local BLACK = rgb(0, 0, 0)
local WHITE = rgb(255, 255, 255)
local SHADOW = rgb(63, 63, 63)
local XP_GREEN = rgb(128, 255, 32)
local GLINT = { 160, 64, 255 }

------------------------------------------------------------------------------
-- Data from Minecraft
------------------------------------------------------------------------------

local function read_bridge()
    local ok, d = pcall(json.load_file, BRIDGE_FILE)
    if ok and type(d) == "table" and d.seq ~= nil then
        if d.seq ~= last_seq then
            last_seq = d.seq
            frames_since_change = 0
        end
        data = d
    end
end

local function is_connected()
    return data ~= nil and frames_since_change < DISCONNECT_FRAMES and data.in_world == true
end

-- Fallback when Minecraft isn't running: Leon's health on a 0..20 scale
local function leon_health()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local ok, current, max = pcall(function()
        local hp = cm:call("getPlayerContextRef"):call("get_HitPoint")
        return hp:call("get_CurrentHitPoint"), hp:call("get_DefaultHitPoint")
    end)
    if not ok or current == nil or max == nil or max <= 0 then
        leon_hp_info = "Leon's HP not found (in a menu?)"
        return nil
    end
    leon_hp_info = "HP " .. tostring(current) .. " / " .. tostring(max)
    return math.max(0, current) / max * 20
end

------------------------------------------------------------------------------
-- Pixel art
------------------------------------------------------------------------------

local HEART = {
    ".KK...KK.",
    "KRRK.KRRK",
    "KRWRKRRRK",
    "KRRRRRRRK",
    ".KRRRRRK.",
    "..KRRRK..",
    "...KRK...",
    "....K....",
}

local DRUMSTICK = {
    ".....KKK.",
    "....KMMMK",
    "...KMMMMK",
    "...KMMMK.",
    "..KWKKK..",
    ".KWK.....",
    "KWWK.....",
    ".KK......",
}

-- 8x8 item sprites: M = material color, H = handle (wood), S = string
local ITEM_SPRITES = {
    sword = {
        "......MM",
        ".....MMM",
        "....MMM.",
        ".K.MMM..",
        "..KMM...",
        "..HK....",
        ".H..K...",
        "H.......",
    },
    pickaxe = {
        "..MMMM..",
        ".M.HH.M.",
        "M..H...M",
        "...H....",
        "..H.....",
        "..H.....",
        ".H......",
        "H.......",
    },
    axe = {
        "...MM...",
        "..MMMH..",
        "..MMH...",
        "...H....",
        "..H.....",
        ".H......",
        "H.......",
        "........",
    },
    shovel = {
        ".....MM.",
        "....MMMM",
        ".....MM.",
        "....H...",
        "...H....",
        "..H.....",
        ".H......",
        "H.......",
    },
    bow = {
        "..HHH...",
        ".H...S..",
        "H.....S.",
        "H......S",
        "H.....S.",
        ".H...S..",
        "..HHH...",
        "........",
    },
    crossbow = {
        "HHHHHHH.",
        ".S.H.S..",
        "..SMS...",
        "...H....",
        "...H....",
        "...H....",
        "...H....",
        "........",
    },
}

local MATERIALS = {
    { "wooden", { 139, 90, 43 } },
    { "stone", { 138, 138, 138 } },
    { "iron", { 216, 216, 216 } },
    { "golden", { 245, 215, 66 } },
    { "diamond", { 78, 230, 230 } },
    { "netherite", { 74, 63, 69 } },
}

local BLOCK_COLORS = {
    { "grass", { 95, 168, 58 } },
    { "dirt", { 139, 90, 43 } },
    { "cobble", { 107, 107, 107 } },
    { "stone", { 125, 125, 125 } },
    { "planks", { 184, 148, 95 } },
    { "log", { 107, 81, 49 } },
    { "leaves", { 63, 125, 42 } },
    { "sand", { 219, 211, 160 } },
    { "glass", { 192, 232, 240 } },
    { "brick", { 150, 80, 63 } },
    { "wool", { 233, 236, 236 } },
    { "water", { 63, 118, 228 } },
    { "lava", { 240, 112, 32 } },
    { "obsidian", { 20, 18, 30 } },
    { "tnt", { 219, 68, 52 } },
    { "beef", { 150, 75, 50 } },
    { "porkchop", { 230, 150, 140 } },
    { "chicken", { 230, 190, 150 } },
    { "bread", { 200, 160, 80 } },
    { "golden_apple", { 245, 215, 66 } },
    { "apple", { 220, 40, 40 } },
    { "carrot", { 240, 140, 30 } },
    { "potato", { 210, 180, 100 } },
}

local function find_color(name, table_, fallback)
    for _, entry in ipairs(table_) do
        if name:find(entry[1]) then return entry[2] end
    end
    return fallback
end

-- Stable color for items we have no art for, based on the name
local function hash_color(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 360 end
    local r = math.floor(128 + 100 * math.sin(math.rad(h)))
    local g = math.floor(128 + 100 * math.sin(math.rad(h + 120)))
    local b = math.floor(128 + 100 * math.sin(math.rad(h + 240)))
    return { r, g, b }
end

local function shade(c, f)
    return { math.min(255, math.floor(c[1] * f)), math.min(255, math.floor(c[2] * f)), math.min(255, math.floor(c[3] * f)) }
end

local function to_color(c, enchanted)
    if enchanted then
        c = { (c[1] * 2 + GLINT[1]) // 3, (c[2] * 2 + GLINT[2]) // 3, (c[3] * 2 + GLINT[3]) // 3 }
    end
    return rgb(c[1], c[2], c[3])
end

local function draw_sprite(sprite, x, y, px, palette)
    for row = 1, #sprite do
        local line = sprite[row]
        for col = 1, #line do
            local color = palette[line:sub(col, col)]
            if color ~= nil then
                draw.filled_rect(x + (col - 1) * px, y + (row - 1) * px, px, px, color)
            end
        end
    end
end

local function outline(x, y, w, h, t, color)
    draw.filled_rect(x, y, w, t, color)
    draw.filled_rect(x, y + h - t, w, t, color)
    draw.filled_rect(x, y, t, h, color)
    draw.filled_rect(x + w - t, y, t, h, color)
end

local function shadow_text(text, x, y, color)
    draw.text(text, x + 1, y + 1, BLACK)
    draw.text(text, x, y, color)
end

------------------------------------------------------------------------------
-- HUD pieces (sizes are in Minecraft GUI units, multiplied by px)
------------------------------------------------------------------------------

-- fill: "full", "half" or "empty"; half_left = which side is filled for "half"
local function icon_palette(fill, half_left, colors)
    return function(c, column)
        if c == "K" then return BLACK end
        local filled = fill == "full" or (fill == "half" and ((half_left and column <= 5) or (not half_left and column >= 5)))
        if not filled then return SHADOW end
        return colors[c]
    end
end

local function draw_icon(sprite, x, y, px, fill, half_left, colors)
    local pick = icon_palette(fill, half_left, colors)
    for row = 1, #sprite do
        local line = sprite[row]
        for col = 1, #line do
            local c = line:sub(col, col)
            if c ~= "." then
                draw.filled_rect(x + (col - 1) * px, y + (row - 1) * px, px, px, pick(c, col))
            end
        end
    end
end

local HEART_COLORS = { R = rgb(224, 32, 32), W = rgb(255, 192, 192) }
local FOOD_COLORS = { M = rgb(170, 100, 50), W = rgb(240, 230, 210) }

local function fill_for(points, i)
    if points >= (i + 1) * 2 then return "full" end
    if points == i * 2 + 1 then return "half" end
    return "empty"
end

local function draw_hearts(x0, y, px, health)
    local points = math.ceil(health)
    local shake = points <= 4
    for i = 0, 9 do
        local dy = shake and math.random(-1, 1) * px or 0
        draw_icon(HEART, x0 + i * 8 * px, y + dy, px, fill_for(points, i), true, HEART_COLORS)
    end
end

-- Hunger fills from the right, like in Minecraft
local function draw_hunger(x_right, y, px, food)
    for i = 0, 9 do
        local x = x_right - (i + 1) * 8 * px - px
        draw_icon(DRUMSTICK, x, y, px, fill_for(food, i), false, FOOD_COLORS)
    end
end

local function draw_xp(x0, y, px, level, progress)
    draw.filled_rect(x0, y, 182 * px, 5 * px, BLACK)
    local fill = math.floor(180 * math.max(0, math.min(1, progress or 0)))
    if fill > 0 then
        draw.filled_rect(x0 + px, y + px, fill * px, 3 * px, XP_GREEN)
    end
    if level ~= nil and level > 0 then
        local text = tostring(level)
        shadow_text(text, x0 + 91 * px - #text * 3, y - 8 * px, XP_GREEN)
    end
end

local BLOCK_SPRITE = {
    "........",
    ".KKKKKK.",
    ".KTTTTK.",
    ".KBBBBK.",
    ".KBBBBK.",
    ".KBBBBK.",
    ".KKKKKK.",
    "........",
}

-- Returns the 8x8 sprite and palette for an item, plus a letter for items we have no art for
local function item_look(item)
    local name = item.id:gsub("^minecraft:", "")
    local enchanted = item.enchanted == true

    local kind = nil
    if name:find("_sword$") then kind = "sword"
    elseif name:find("_pickaxe$") then kind = "pickaxe"
    elseif name:find("_axe$") then kind = "axe"
    elseif name:find("_shovel$") or name:find("_hoe$") then kind = "shovel"
    elseif name == "crossbow" then kind = "crossbow"
    elseif name == "bow" then kind = "bow"
    end

    if kind ~= nil then
        local material = find_color(name, MATERIALS, { 200, 200, 200 })
        local string_color = (kind == "crossbow" and item.charged) and { 180, 180, 180 } or { 230, 230, 230 }
        return ITEM_SPRITES[kind], {
            M = to_color(material, enchanted),
            H = to_color({ 120, 80, 40 }, enchanted),
            S = to_color(string_color, enchanted),
            K = BLACK,
        }, nil
    end

    -- Blocks and everything else: a little shaded cube
    local base = find_color(name, BLOCK_COLORS, nil)
    local letter = base == nil and name:sub(1, 1):upper() or nil
    base = base or hash_color(name)
    return BLOCK_SPRITE, {
        T = to_color(shade(base, 1.15), enchanted),
        B = to_color(shade(base, 0.8), enchanted),
        K = BLACK,
    }, letter
end

local function draw_item(item, x, y, px)
    if item == nil or item.id == nil then return end
    local ipx = px * 2   -- 8x8 sprites drawn at 16x16 GUI units

    local sprite, palette, letter = item_look(item)
    draw_sprite(sprite, x, y, ipx, palette)
    if letter ~= nil then
        shadow_text(letter, x + 6 * px, y + 5 * px, WHITE)
    end

    if item.max_damage ~= nil and item.damage ~= nil and item.damage > 0 then
        local left = 1 - item.damage / item.max_damage
        draw.filled_rect(x + 2 * px, y + 13 * px, 13 * px, 2 * px, BLACK)
        draw.filled_rect(x + 2 * px, y + 13 * px, math.floor(13 * left) * px, px,
            rgb(math.floor(255 * (1 - left)), math.floor(255 * left), 0))
    end

    if item.count ~= nil and item.count > 1 then
        local text = tostring(item.count)
        shadow_text(text, x + 17 * px - #text * 7, y + 16 * px - 13, WHITE)
    end
end

local function draw_hotbar(x0, y, px, hotbar, selected)
    draw.filled_rect(x0, y, 182 * px, 22 * px, rgb(0, 0, 0, 140))
    outline(x0, y, 182 * px, 22 * px, px, rgb(40, 40, 40))
    for i = 0, 8 do
        outline(x0 + (1 + i * 20) * px, y + px, 20 * px, 20 * px, px, rgb(139, 139, 139, 200))
    end
    for i = 0, 8 do
        draw_item(hotbar and hotbar["s" .. i], x0 + (3 + i * 20) * px, y + 3 * px, px)
    end
    if selected ~= nil then
        outline(x0 + (selected * 20 - 1) * px, y - px, 24 * px, 24 * px, px * 2, WHITE)
    end
end

------------------------------------------------------------------------------
-- Held item (bottom right, like Minecraft's first-person hand)
------------------------------------------------------------------------------

local SWING_FRAMES = 18   -- Minecraft's swing takes 6 ticks (~0.3 s)
local swing_frame = nil

-- Draws the sprite rotated around its bottom-left corner (where the handle is)
local function draw_sprite_rotated(sprite, pivot_x, pivot_y, size, angle, palette)
    local c, s = math.cos(angle), math.sin(angle)
    local rows = #sprite
    for row = 1, rows do
        local line = sprite[row]
        for col = 1, #line do
            local color = palette[line:sub(col, col)]
            if color ~= nil then
                local lx = (col - 0.5) * size
                local ly = (row - 0.5 - rows) * size
                local rx, ry = lx * c - ly * s, lx * s + ly * c
                draw.filled_rect(pivot_x + rx - size / 2, pivot_y + ry - size / 2, size + 1, size + 1, color)
            end
        end
    end
end

local function draw_held_item(w, h, px, item)
    if item == nil or item.id == nil then return end
    local sprite, palette = item_look(item)

    -- Swing: the item dips toward the crosshair and back, like in Minecraft
    local t = 0
    if swing_frame ~= nil then
        t = (frame - swing_frame) / SWING_FRAMES
        if t >= 1 then
            swing_frame = nil
            t = 0
        end
    end
    local swing = math.sin(t * math.pi)
    local size = 9 * px
    local pivot_x = w * 0.70 - swing * size * 6
    local pivot_y = h * 0.97 - swing * size * 2
    draw_sprite_rotated(sprite, pivot_x, pivot_y, size, -swing * 0.9, palette)
end

------------------------------------------------------------------------------
-- RE4 -> Minecraft input
------------------------------------------------------------------------------

local INPUT_FILE = "minecraft_bridge_input.json"   -- relative to reframework\data
local input = { seq = 0, swings = 0, keys = {} }
local HEARTBEAT_FRAMES = 10   -- Minecraft gives control back to its keyboard if RE4 goes quiet

local MOVE_KEYS = {
    w = { 0x57 }, a = { 0x41 }, s = { 0x53 }, d = { 0x44 },
    jump = { 0x20 },
    sneak = { 0x10, 0xA0, 0xA1 },    -- Shift
    sprint = { 0x11, 0xA2, 0xA3 },   -- Ctrl
}
local number_keys_down = {}
local mouse_was_down = false
local input_info = "nothing sent yet"
local mouse_source = "none"
local select_frame = -1000

local function send_input()
    input.seq = input.seq + 1
    local ok, written = pcall(json.dump_file, INPUT_FILE, input)
    input_info = (ok and written ~= false) and ("sent #" .. input.seq) or "could not write input file"
end

local function key_down(key)
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    return ok and down == true
end

local function any_key_down(keys)
    for _, key in ipairs(keys) do
        if key_down(key) then return true end
    end
    return false
end

-- Not every REFramework build reports mouse buttons the same way, so try both
local function mouse_down()
    if key_down(0x01) then
        mouse_source = "is_key_down"
        return true
    end
    local ok, down = pcall(imgui.is_mouse_down, 0)
    if ok and down == true then
        mouse_source = "imgui"
        return true
    end
    return false
end

local function menu_open()
    local ok, open = pcall(function() return reframework:is_drawing_ui() end)
    return ok and open == true
end

local function update_input()
    local changed = frame % HEARTBEAT_FRAMES == 0

    -- With the REFramework menu open, release all keys so Minecraft's player stops
    local menu = menu_open()
    for name, keys in pairs(MOVE_KEYS) do
        local down = not menu and any_key_down(keys)
        if input.keys[name] ~= down then
            input.keys[name] = down
            changed = true
        end
    end
    if menu then
        if changed then send_input() end
        return
    end

    for i = 1, 9 do
        local down = key_down(0x30 + i)
        if down and not number_keys_down[i] then
            input.selected = i - 1
            select_frame = frame
            send_input()
        end
        number_keys_down[i] = down
    end

    local mouse = mouse_down()
    if mouse and not mouse_was_down then
        input.swings = input.swings + 1
        swing_frame = frame
        changed = true
    end
    mouse_was_down = mouse

    if changed then send_input() end
end

------------------------------------------------------------------------------
-- Hiding RE4's own UI
------------------------------------------------------------------------------

local HIDDEN_GUI_FILE = "minecraft_hidden_gui.json"   -- relative to reframework\data
local hidden_gui = {}
local gui_seen = {}   -- element name -> last frame it was drawn

do
    local ok, saved = pcall(json.load_file, HIDDEN_GUI_FILE)
    if ok and type(saved) == "table" then
        for _, name in ipairs(saved) do hidden_gui[name] = true end
    end
end

local function save_hidden_gui()
    local list = {}
    for name in pairs(hidden_gui) do table.insert(list, name) end
    table.sort(list)
    pcall(json.dump_file, HIDDEN_GUI_FILE, list)
end

local function visible_gui_names()
    local names = {}
    for name, last in pairs(gui_seen) do
        if frame - last < 60 or hidden_gui[name] then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

-- Called by REFramework for every RE4 UI element before it is drawn; false = don't draw it
re.on_pre_gui_draw_element(function(element, context)
    local ok, name = pcall(function() return element:call("get_GameObject"):call("get_Name") end)
    if not ok or name == nil then return true end
    gui_seen[name] = frame
    if settings.hide_re4_ui and hidden_gui[name] then return false end
    return true
end)

local function draw_gui_picker()
    if not imgui.tree_node("Hide RE4 UI elements") then return end
    imgui.text("Elements on screen right now. Ticked ones are hidden.")
    imgui.text("Tip: during normal gameplay (aim a gun so ammo shows), press the button below.")
    if imgui.button("Hide everything on screen now") then
        for _, name in ipairs(visible_gui_names()) do hidden_gui[name] = true end
        save_hidden_gui()
    end
    imgui.same_line()
    if imgui.button("Show all again") then
        hidden_gui = {}
        save_hidden_gui()
    end
    for _, name in ipairs(visible_gui_names()) do
        local changed, hide = imgui.checkbox(name, hidden_gui[name] == true)
        if changed then
            hidden_gui[name] = hide or nil
            save_hidden_gui()
        end
    end
    imgui.tree_pop()
end

local function get_screen_size()
    local ok, size = pcall(imgui.get_display_size)
    if ok and size ~= nil and size.x > 0 then
        return size.x, size.y
    end
    return 1920, 1080
end

------------------------------------------------------------------------------

re.on_frame(function()
    frame = frame + 1
    frames_since_change = frames_since_change + 1
    if frame % READ_EVERY_FRAMES == 0 then
        read_bridge()
    end

    if not settings.enabled then return end

    local w, h = get_screen_size()
    local px = settings.scale
    if px <= 0 then px = math.max(1, math.floor(h / 360)) end
    local x0 = math.floor(w / 2 - 91 * px)

    if not is_connected() then
        swing_frame = nil
        local health = leon_health()
        if health ~= nil then
            draw_hearts(x0, h - 39 * px, px, health)
        end
        return
    end

    if settings.send_input then
        update_input()
    end

    -- Show the slot picked in RE4 right away, before Minecraft confirms it
    local selected = data.selected
    if input.selected ~= nil and frame - select_frame < 10 then
        selected = input.selected
    end

    if settings.held_item and data.hotbar ~= nil then
        draw_held_item(w, h, px, data.hotbar["s" .. tostring(selected)])
    end
    draw_hotbar(x0, h - 22 * px, px, data.hotbar, selected)

    local creative = data.game_mode == "creative" or data.game_mode == "spectator"
    if creative and not settings.survival_bars_in_creative then return end

    draw_xp(x0, h - 29 * px, px, data.xp_level, data.xp_progress)
    draw_hearts(x0, h - 39 * px, px, data.health or 0)
    draw_hunger(x0 + 182 * px, h - 39 * px, px, data.food or 0)
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft HUD") then
        local changed
        changed, settings.enabled = imgui.checkbox("Enabled", settings.enabled)
        changed, settings.scale = imgui.slider_int("Size (0 = auto)", settings.scale, 0, 8)
        changed, settings.survival_bars_in_creative = imgui.checkbox("Show hearts/hunger/XP in Creative", settings.survival_bars_in_creative)
        changed, settings.held_item = imgui.checkbox("Show held item", settings.held_item)
        changed, settings.send_input = imgui.checkbox("Send 1-9 and left-click to Minecraft", settings.send_input)
        changed, settings.hide_re4_ui = imgui.checkbox("Hide picked RE4 UI elements", settings.hide_re4_ui)
        draw_gui_picker()
        imgui.text(is_connected() and "Minecraft: connected" or "Minecraft: not connected (showing Leon's health)")
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Data file: reframework\\data\\" .. BRIDGE_FILE)
            imgui.text("Last update: " .. (frames_since_change == math.huge and "never" or (frames_since_change .. " frames ago")))
            if data ~= nil then
                imgui.text(string.format("Mode: %s  Health: %s  Food: %s  XP: %s  Slot: %s",
                    tostring(data.game_mode), tostring(data.health), tostring(data.food),
                    tostring(data.xp_level), tostring(data.selected)))
            end
            imgui.text("Input to Minecraft: " .. input_info .. " (mouse via " .. mouse_source .. ")")
            imgui.text("Leon: " .. leon_hp_info)
        end
        imgui.tree_pop()
    end
end)
