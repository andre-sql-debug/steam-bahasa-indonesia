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
    hide_all_re4_ui = true,     -- while Leon is in the game; F8 shows RE4's UI again
    hide_re4_ui = true,         -- picked elements (used when hide_all_re4_ui is off)
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

------------------------------------------------------------------------------
-- Real Minecraft item textures, sent by the Minecraft mod (16x16 pixels per item)
------------------------------------------------------------------------------

local TEXTURES_FILE = "minecraft_textures.json"   -- relative to reframework\data
local textures = {}           -- item id -> 256 colors (0xAABBGGRR, like draw.* uses)
local glint_textures = {}     -- same, tinted purple for enchanted items
local textures_version = nil

------------------------------------------------------------------------------
-- Minecraft's own HUD images and font (sent by the Minecraft mod), drawn pixel for pixel
------------------------------------------------------------------------------

local gui = {}       -- image name -> { w, h, runs = { {x, y, length, color}, ... }, px = hex }
local glyphs = {}    -- character code -> { advance, runs }

-- Turns "AABBGGRR" hex pixels into runs of same-colored pixels per row (far fewer rectangles to draw)
local function parse_image(img)
    if type(img) ~= "table" or type(img.px) ~= "string" or type(img.w) ~= "number" then return nil end
    local w, h, px = img.w, img.h, img.px
    if #px ~= w * h * 8 then return nil end
    local runs = {}
    for y = 0, h - 1 do
        local x = 0
        while x < w do
            local i = (y * w + x) * 8
            local hex = px:sub(i + 1, i + 8)
            local len = 1
            while x + len < w and px:sub(i + len * 8 + 1, i + len * 8 + 8) == hex do
                len = len + 1
            end
            local c = tonumber(hex, 16) or 0
            if (c >> 24) > 0 then table.insert(runs, { x, y, len, c }) end
            x = x + len
        end
    end
    return { w = w, h = h, runs = runs, px = px }
end

-- clip_w: only draw the first clip_w pixel columns (for the XP bar)
local function draw_image(name, x, y, px, clip_w)
    local img = gui[name]
    if img == nil then return false end
    for _, r in ipairs(img.runs) do
        local len = r[3]
        if clip_w ~= nil then len = math.min(len, clip_w - r[1]) end
        if len > 0 then
            draw.filled_rect(x + r[1] * px, y + r[2] * px, len * px, px, r[4])
        end
    end
    return true
end

-- Minecraft's font: 8x8 glyphs in a 16x16 grid in font/ascii.png
local function glyph(code)
    if glyphs[code] ~= nil then return glyphs[code] end
    local font = gui["font/ascii"]
    if font == nil or font.w ~= 128 then return nil end
    local gx, gy = (code % 16) * 8, (code // 16) * 8
    local runs, right = {}, -1
    for y = 0, 7 do
        local x = 0
        while x < 8 do
            local i = ((gy + y) * 128 + gx + x) * 8
            local on = (tonumber(font.px:sub(i + 1, i + 2), 16) or 0) > 0
            if on then
                local len = 1
                while x + len < 8 do
                    local j = ((gy + y) * 128 + gx + x + len) * 8
                    if (tonumber(font.px:sub(j + 1, j + 2), 16) or 0) == 0 then break end
                    len = len + 1
                end
                table.insert(runs, { x, y, len })
                right = math.max(right, x + len - 1)
                x = x + len
            else
                x = x + 1
            end
        end
    end
    local g = { advance = code == 32 and 4 or right + 2, runs = runs }
    glyphs[code] = g
    return g
end

local function mc_text_width(text)
    local width = 0
    for i = 1, #text do
        local g = glyph(text:byte(i))
        width = width + (g and g.advance or 6)
    end
    return width
end

local function mc_text_raw(text, x, y, px, color)
    for i = 1, #text do
        local g = glyph(text:byte(i))
        if g ~= nil then
            for _, r in ipairs(g.runs) do
                draw.filled_rect(x + r[1] * px, y + r[2] * px, r[3] * px, px, color)
            end
            x = x + g.advance * px
        end
    end
end

-- Text with Minecraft's drop shadow (the same color at 1/4 brightness, 1 pixel down-right)
local function mc_text(text, x, y, px, color)
    local shadow = (color & 0xFF000000) | (((color & 0x00FCFCFC) >> 2))
    mc_text_raw(text, x + px, y + px, px, shadow)
    mc_text_raw(text, x, y, px, color)
end

local function mc_gui_ready()
    return gui["gui/sprites/hud/hotbar"] ~= nil and gui["font/ascii"] ~= nil
end

local function load_textures()
    if data == nil or data.textures_version == nil or data.textures_version == textures_version then return end
    local ok, t = pcall(json.load_file, TEXTURES_FILE)
    if not ok or type(t) ~= "table" or type(t.items) ~= "table" then return end
    textures_version = data.textures_version
    if type(t.gui) == "table" then
        for name, img in pairs(t.gui) do
            if gui[name] == nil then gui[name] = parse_image(img) end
        end
        glyphs = {}
    end
    for id, hex in pairs(t.items) do
        if textures[id] == nil and type(hex) == "string" and #hex == 256 * 8 then
            local pixels = {}
            for i = 0, 255 do
                pixels[i + 1] = tonumber(hex:sub(i * 8 + 1, i * 8 + 8), 16) or 0
            end
            textures[id] = pixels
        end
    end
end

local function enchanted_texture(id)
    if glint_textures[id] == nil then
        local tinted = {}
        for i, c in ipairs(textures[id]) do
            local r, g, b = c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF
            tinted[i] = (c & 0xFF000000) | (((b * 2 + GLINT[3]) // 3) << 16) | (((g * 2 + GLINT[2]) // 3) << 8) | ((r * 2 + GLINT[1]) // 3)
        end
        glint_textures[id] = tinted
    end
    return glint_textures[id]
end

-- The item's 16x16 texture, or nil if Minecraft hasn't sent one
local function item_texture(item)
    if textures[item.id] == nil then return nil end
    return item.enchanted and enchanted_texture(item.id) or textures[item.id]
end

local function draw_texture(pixels, x, y, size)
    for i = 0, 255 do
        local c = pixels[i + 1]
        if (c >> 24) > 16 then
            draw.filled_rect(x + (i % 16) * size, y + (i // 16) * size, size, size, c | 0xFF000000)
        end
    end
end

local function draw_item(item, x, y, px)
    if item == nil or item.id == nil then return end

    local texture = item_texture(item)
    if texture ~= nil then
        draw_texture(texture, x, y, px)
    else
        local sprite, palette, letter = item_look(item)
        draw_sprite(sprite, x, y, px * 2, palette)   -- 8x8 sprites drawn at 16x16 GUI units
        if letter ~= nil then
            shadow_text(letter, x + 6 * px, y + 5 * px, WHITE)
        end
    end

    if item.max_damage ~= nil and item.damage ~= nil and item.damage > 0 then
        local left = 1 - item.damage / item.max_damage
        draw.filled_rect(x + 2 * px, y + 13 * px, 13 * px, 2 * px, BLACK)
        draw.filled_rect(x + 2 * px, y + 13 * px, math.floor(13 * left) * px, px,
            rgb(math.floor(255 * (1 - left)), math.floor(255 * left), 0))
    end

    if item.count ~= nil and item.count > 1 then
        local text = tostring(item.count)
        if mc_gui_ready() then
            mc_text(text, x + (19 - 2 - mc_text_width(text)) * px, y + (6 + 3) * px, px, WHITE)
        else
            shadow_text(text, x + 17 * px - #text * 7, y + 16 * px - 13, WHITE)
        end
    end
end

------------------------------------------------------------------------------
-- The HUD drawn with Minecraft's own images, laid out like Minecraft's Gui class
------------------------------------------------------------------------------

local XP_TEXT = 0xFF20FF80   -- Minecraft's 0x80FF20

local function mc_status_row(x0, y, px, value, empty, half, full, from_right)
    for i = 0, 9 do
        local x = from_right and (x0 - i * 8 * px - 9 * px) or (x0 + i * 8 * px)
        draw_image(empty, x, y, px)
        if i * 2 + 1 < value then
            draw_image(full, x, y, px)
        elseif i * 2 + 1 == value then
            draw_image(half, x, y, px)
        end
    end
end

local function draw_mc_hud(w, h, px, x0, selected, survival)
    local hotbar_y = h - 22 * px
    draw_image("gui/sprites/hud/hotbar", x0, hotbar_y, px)
    if selected ~= nil then
        draw_image("gui/sprites/hud/hotbar_selection", x0 - px + selected * 20 * px, hotbar_y - px, px)
    end
    for i = 0, 8 do
        draw_item(data.hotbar and data.hotbar["s" .. i], x0 + (3 + i * 20) * px, h - 19 * px, px)
    end
    if not survival then return end

    -- XP bar and level
    draw_image("gui/sprites/hud/experience_bar_background", x0, h - 29 * px, px)
    local fill = math.floor((data.xp_progress or 0) * 183)
    if fill > 0 then
        draw_image("gui/sprites/hud/experience_bar_progress", x0, h - 29 * px, px, fill)
    end
    local level = data.xp_level or 0
    if level > 0 then
        local text = tostring(level)
        local tx = x0 + 91 * px - math.floor(mc_text_width(text) / 2) * px
        local ty = h - 35 * px
        for _, o in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            mc_text_raw(text, tx + o[1] * px, ty + o[2] * px, px, 0xFF000000)
        end
        mc_text_raw(text, tx, ty, px, XP_TEXT)
    end

    -- Hearts (shaking when low), armor above them, hunger on the right
    local health = math.ceil(data.health or 0)
    local hearts_y = h - 39 * px
    for i = 0, 9 do
        local y = hearts_y
        if health <= 4 then y = y + math.random(0, 1) * px end
        local x = x0 + i * 8 * px
        draw_image("gui/sprites/hud/heart/container", x, y, px)
        if i * 2 + 1 < health then
            draw_image("gui/sprites/hud/heart/full", x, y, px)
        elseif i * 2 + 1 == health then
            draw_image("gui/sprites/hud/heart/half", x, y, px)
        end
    end
    if (data.armor or 0) > 0 then
        mc_status_row(x0, hearts_y - 10 * px, px, data.armor,
            "gui/sprites/hud/armor_empty", "gui/sprites/hud/armor_half", "gui/sprites/hud/armor_full", false)
    end
    mc_status_row(x0 + 182 * px, hearts_y, px, data.food or 0,
        "gui/sprites/hud/food_empty", "gui/sprites/hud/food_half", "gui/sprites/hud/food_full", true)
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

-- Same, for a 16x16 texture
local function draw_texture_rotated(pixels, pivot_x, pivot_y, size, angle)
    local c, s = math.cos(angle), math.sin(angle)
    for i = 0, 255 do
        local color = pixels[i + 1]
        if (color >> 24) > 16 then
            local lx = (i % 16 + 0.5) * size
            local ly = (i // 16 + 0.5 - 16) * size
            local rx, ry = lx * c - ly * s, lx * s + ly * c
            draw.filled_rect(pivot_x + rx - size / 2, pivot_y + ry - size / 2, size + 1, size + 1, color | 0xFF000000)
        end
    end
end

local function draw_held_item(w, h, px, item)
    if item == nil or item.id == nil then return end

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
    local texture = item_texture(item)
    if texture ~= nil then
        draw_texture_rotated(texture, pivot_x, pivot_y, size / 2, -swing * 0.9)
    else
        local sprite, palette = item_look(item)
        draw_sprite_rotated(sprite, pivot_x, pivot_y, size, -swing * 0.9, palette)
    end
end

------------------------------------------------------------------------------
-- RE4 -> Minecraft input
------------------------------------------------------------------------------

local INPUT_FILE = "minecraft_bridge_input.json"   -- relative to reframework\data
local input = { seq = 0, swings = 0, uses = 0, keys = {} }
local HEARTBEAT_FRAMES = 10   -- Minecraft gives control back to its keyboard if RE4 goes quiet

local MOVE_KEYS = {
    w = { 0x57 }, a = { 0x41 }, s = { 0x53 }, d = { 0x44 },
    jump = { 0x20 },
    sneak = { 0x10, 0xA0, 0xA1 },    -- Shift
    sprint = { 0x11, 0xA2, 0xA3 },   -- Ctrl
}
local number_keys_down = {}
local mouse_was_down = false
local right_was_down = false
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

-- Raw mouse buttons from the overlay plugin (counts every click, even between frames)
local plugin_mouse = nil
local plugin_mouse_frame = nil
local plugin_mouse_alive_until = -1
local last_presses = { left = nil, right = nil }

local function read_plugin_mouse()
    local ok, m = pcall(json.load_file, "minecraft_mouse.json")
    if not ok or type(m) ~= "table" or m.frame == nil then return end
    if m.frame ~= plugin_mouse_frame then
        plugin_mouse_frame = m.frame
        plugin_mouse_alive_until = frame + 30
    end
    plugin_mouse = m
end

local function plugin_mouse_alive()
    return plugin_mouse ~= nil and frame <= plugin_mouse_alive_until
end

-- New presses since the last call (nil when the plugin isn't running)
local function plugin_new_presses(button)
    local total = plugin_mouse[button .. "_presses"] or 0
    local last = last_presses[button]
    last_presses[button] = total
    if last == nil or total < last then return 0 end
    return total - last
end

local function right_mouse_down()
    if key_down(0x02) then return true end
    local ok, down = pcall(imgui.is_mouse_down, 1)
    return ok and down == true
end

local function menu_open()
    local ok, open = pcall(function() return reframework:is_drawing_ui() end)
    return ok and open == true
end

-- Leon's look direction in Minecraft's terms (yaw 0 = +Z, pitch positive = looking down),
-- so Minecraft's player aims its placing and breaking where Leon looks
local function camera_yaw_pitch()
    local camera = sdk.get_primary_camera()
    local ok, f = pcall(function()
        local rot = camera:call("get_GameObject"):call("get_Transform"):call("get_Rotation")
        return rot * Vector3f.new(0, 0, -1)
    end)
    if not ok or f == nil then return nil end
    local yaw = math.deg(math.atan(-f.x, f.z))
    local pitch = -math.deg(math.asin(math.max(-1, math.min(1, f.y))))
    return yaw, pitch
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

    local yaw, pitch = camera_yaw_pitch()
    if yaw ~= nil and (input.yaw == nil or math.abs(yaw - input.yaw) > 0.3 or math.abs(pitch - input.pitch) > 0.3) then
        input.yaw = math.floor(yaw * 100) / 100
        input.pitch = math.floor(pitch * 100) / 100
        changed = true
    end

    -- Left: attack / break (held = keep mining). Right: Minecraft's "use" (place blocks...)
    read_plugin_mouse()
    local mouse, new_left, new_right
    local right
    if plugin_mouse_alive() then
        mouse_source = "overlay plugin (raw)"
        mouse = plugin_mouse.left == true
        right = plugin_mouse.right == true
        new_left = plugin_new_presses("left")
        new_right = plugin_new_presses("right")
    else
        mouse = mouse_down()
        right = right_mouse_down()
        new_left = (mouse and not mouse_was_down) and 1 or 0
        new_right = (right and not right_was_down) and 1 or 0
    end
    if new_left > 0 then
        input.swings = input.swings + new_left
        swing_frame = frame
        changed = true
    end
    if input.keys.attack ~= mouse then
        input.keys.attack = mouse
        changed = true
    end
    mouse_was_down = mouse

    if new_right > 0 then
        input.uses = input.uses + new_right
        swing_frame = frame
        changed = true
    end
    right_was_down = right

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

local show_re4_ui = false     -- F8
local f8_was_down = false
local leon_present = false    -- RE4's title and loading menus stay visible
local leon_seen_frame = nil   -- when Leon appeared; RE4's loading screen and fade-in still run after that
local HIDE_UI_AFTER_FRAMES = 300   -- ~5 s

local function update_ui_toggle()
    local down = false
    local ok, d = pcall(function() return reframework:is_key_down(0x77) end)
    down = ok and d == true
    if down and not f8_was_down then show_re4_ui = not show_re4_ui end
    f8_was_down = down

    if frame % 30 == 0 then
        local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
        local ok_ctx, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
        local present = ok_ctx and ctx ~= nil
        if not present then
            leon_seen_frame = nil
        elseif leon_seen_frame == nil then
            leon_seen_frame = frame
        end
        leon_present = present and frame - leon_seen_frame >= HIDE_UI_AFTER_FRAMES
    end
end

-- Called by REFramework for every RE4 UI element before it is drawn; false = don't draw it
re.on_pre_gui_draw_element(function(element, context)
    local ok, name = pcall(function() return element:call("get_GameObject"):call("get_Name") end)
    if not ok or name == nil then return true end
    gui_seen[name] = frame
    if show_re4_ui then return true end
    if settings.hide_all_re4_ui then return not leon_present end
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

------------------------------------------------------------------------------
-- Live Minecraft overlay: when the re4_minecraft_overlay.dll plugin shows Minecraft's own
-- rendering (hand, item, HUD), this script doesn't draw its copies
------------------------------------------------------------------------------

local PLUGIN_STATUS_FILE = "minecraft_overlay_plugin.json"
local plugin_beat = nil
local plugin_beat_frame = -100000
local plugin_ready = false

local function update_plugin_status()
    if frame % 60 ~= 0 then return end
    local ok, d = pcall(json.load_file, PLUGIN_STATUS_FILE)
    if not ok or type(d) ~= "table" then return end
    if d.beat ~= plugin_beat then
        plugin_beat = d.beat
        plugin_beat_frame = frame
    end
    plugin_ready = d.ready == true
end

local function minecraft_draws_ui()
    return data ~= nil and data.overlay == true and plugin_ready and frame - plugin_beat_frame < 240
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
        load_textures()
    end
    update_ui_toggle()
    update_plugin_status()

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
    if minecraft_draws_ui() then return end

    -- Show the slot picked in RE4 right away, before Minecraft confirms it
    local selected = data.selected
    if input.selected ~= nil and frame - select_frame < 10 then
        selected = input.selected
    end

    if settings.held_item and data.hotbar ~= nil then
        draw_held_item(w, h, px, data.hotbar["s" .. tostring(selected)])
    end

    local creative = data.game_mode == "creative" or data.game_mode == "spectator"
    local survival = not creative or settings.survival_bars_in_creative

    -- Minecraft's own images when the mod has sent them; otherwise the built-in drawings
    if mc_gui_ready() then
        draw_mc_hud(w, h, px, x0, selected, survival)
        return
    end

    draw_hotbar(x0, h - 22 * px, px, data.hotbar, selected)
    if not survival then return end

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
        changed, settings.send_input = imgui.checkbox("Send keys, mouse and look direction to Minecraft", settings.send_input)
        changed, settings.hide_all_re4_ui = imgui.checkbox("Hide all RE4 UI while playing (F8 = show it)", settings.hide_all_re4_ui)
        if not settings.hide_all_re4_ui then
            changed, settings.hide_re4_ui = imgui.checkbox("Hide picked RE4 UI elements", settings.hide_re4_ui)
            draw_gui_picker()
        end
        imgui.text(is_connected() and "Minecraft: connected" or "Minecraft: not connected (showing Leon's health)")
        imgui.text(minecraft_draws_ui() and "UI: live from Minecraft (overlay plugin)" or "UI: drawn by this script")
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
