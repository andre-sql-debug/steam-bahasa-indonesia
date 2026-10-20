-- Minecraft Hearts for RE4 Remake (REFramework Lua script)
-- Shows Leon's health as Minecraft-style hearts (10 hearts = full HP).
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Hearts

local settings = {
    enabled = true,
    scale = 0,          -- 0 = auto (based on screen height)
    show_debug = false,
}

-- 9x8 pixel heart. K = outline, R = red, W = shine
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

-- Colors are 0xAABBGGRR
local COLOR_OUTLINE = 0xFF000000
local COLOR_RED     = 0xFF2020E0
local COLOR_SHINE   = 0xFFC0C0FF
local COLOR_EMPTY   = 0xFF303030

local debug_info = "not checked yet"

local function try_call(obj, method)
    local ok, result = pcall(function() return obj:call(method) end)
    if ok then return result end
    return nil
end

-- Returns current_hp, max_hp (or nil if the player isn't loaded, e.g. in menus)
local function get_player_hp()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if cm == nil then
        debug_info = "CharacterManager not found"
        return nil
    end

    local ctx = try_call(cm, "getPlayerContextRef")
    if ctx == nil then
        debug_info = "player context not found (in a menu?)"
        return nil
    end

    local hp = try_call(ctx, "get_HitPoint")
    if hp == nil then
        debug_info = "HitPoint not found"
        return nil
    end

    local current = try_call(hp, "get_CurrentHitPoint")
    local max = try_call(hp, "get_DefaultHitPoint")
    if current == nil or max == nil or max <= 0 then
        debug_info = "HP values not found"
        return nil
    end

    debug_info = "HP " .. tostring(current) .. " / " .. tostring(max)
    return current, max
end

local function get_screen_size()
    local ok, size = pcall(imgui.get_display_size)
    if ok and size ~= nil and size.x > 0 then
        return size.x, size.y
    end
    return 1920, 1080
end

-- fill: "full", "half" (left half red) or "empty"
local function draw_heart(x, y, px, fill)
    for row = 1, #HEART do
        local line = HEART[row]
        for col = 1, #line do
            local c = line:sub(col, col)
            if c ~= "." then
                local color = COLOR_OUTLINE
                if c ~= "K" then
                    local red = fill == "full" or (fill == "half" and col <= 5)
                    if not red then
                        color = COLOR_EMPTY
                    elseif c == "W" then
                        color = COLOR_SHINE
                    else
                        color = COLOR_RED
                    end
                end
                draw.filled_rect(x + (col - 1) * px, y + (row - 1) * px, px, px, color)
            end
        end
    end
end

re.on_frame(function()
    if not settings.enabled then return end

    local current, max = get_player_hp()
    if current == nil then return end

    local screen_w, screen_h = get_screen_size()
    local px = settings.scale
    if px <= 0 then
        px = math.max(1, math.floor(screen_h / 360))
    end

    -- Same layout as Minecraft: hearts sit above the left side of the hotbar
    local x0 = screen_w / 2 - 91 * px
    local y0 = screen_h - 39 * px

    -- 20 half-hearts, like Minecraft's 20 health points
    local halves = math.ceil(math.max(0, current) / max * 20)
    local low_hp = halves <= 4

    for i = 0, 9 do
        local fill = "empty"
        if halves >= (i + 1) * 2 then
            fill = "full"
        elseif halves == i * 2 + 1 then
            fill = "half"
        end

        -- Hearts shake when health is low, like in Minecraft
        local y = y0
        if low_hp then
            y = y + math.random(-1, 1) * px
        end

        draw_heart(x0 + i * 8 * px, y, px, fill)
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Hearts") then
        local changed
        changed, settings.enabled = imgui.checkbox("Enabled", settings.enabled)
        changed, settings.scale = imgui.slider_int("Size (0 = auto)", settings.scale, 0, 8)
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Status: " .. debug_info)
        end
        imgui.tree_pop()
    end
end)
