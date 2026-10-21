-- Minecraft Blocks for RE4 Remake (REFramework Lua script)
-- Shows the blocks you build in Minecraft (right-click places, left-click breaks; Minecraft does
-- the placing and breaking) as 3D cubes in RE4, at the same spot relative to Leon.
-- Also keeps Minecraft's player lined up with Leon when RE4 walls stop him.
--
-- How the two worlds line up: when Minecraft connects, Leon's position is "anchored" to the
-- Minecraft player's position. Everything Minecraft builds is shown relative to that anchor.
-- F9 = re-anchor here (e.g. after moving to another RE4 area).
-- Needs the RE4 Bridge Minecraft mod 0.4.0 or newer and minecraft_bridge_hud.lua.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Blocks

local settings = {
    enabled = true,
    outlines = true,
    max_distance = 24,
    show_debug = false,
}

local BRIDGE_FILE = "minecraft_bridge.json"
local BLOCKS_FILE = "minecraft_blocks.json"
local SYNC_FILE = "minecraft_bridge_sync.json"
local SYNC_EVERY_FRAMES = 5
local MAX_FACES = 900

local bridge = nil
local bridge_seq = nil
local bridge_age = math.huge
local blocks = {}             -- list of { x, y, z, name } in Minecraft coordinates
local block_set = {}          -- "x,y,z" -> true, to hide faces between two blocks
local colors = {}             -- name -> { top = {r,g,b}, side = {r,g,b} }
local blocks_version = nil
local anchor_re4 = nil        -- Leon's feet when anchored
local anchor_mc = nil         -- Minecraft player's feet (on its flat ground) when anchored
local frame = 0
local sync_seq = 0
local f9_was_down = false
local quad_mode = nil         -- "quad" if draw.filled_quad works, else "lines"
local last_leon = nil         -- to notice when the game teleports Leon to another area
local terrain_mode = false    -- anchor comes from minecraft_terrain.lua
local REANCHOR_DISTANCE = 20
local debug = { faces = 0, status = "waiting for Minecraft" }

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function rgb(c, f)
    local r = math.min(255, math.floor(c[1] * f))
    local g = math.min(255, math.floor(c[2] * f))
    local b = math.min(255, math.floor(c[3] * f))
    return 0xFF000000 | (b << 16) | (g << 8) | r
end

------------------------------------------------------------------------------
-- Data from Minecraft
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

local function connected()
    return bridge ~= nil and bridge_age < 60 and bridge.in_world == true and type(bridge.pos) == "table"
end

local function parse_hex_color(hex)
    local n = tonumber(hex, 16) or 0x808080
    return { (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF }
end

local function load_blocks()
    if bridge.blocks_version == nil or bridge.blocks_version == blocks_version then return end
    local ok, d = pcall(json.load_file, BLOCKS_FILE)
    if not ok or type(d) ~= "table" or type(d.blocks) ~= "table" then return end
    blocks_version = bridge.blocks_version
    blocks, block_set = {}, {}
    for key, name in pairs(d.blocks) do
        local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
        if x ~= nil then
            table.insert(blocks, { tonumber(x), tonumber(y), tonumber(z), name })
            block_set[key] = true
        end
    end
    if type(d.colors) == "table" then
        for name, value in pairs(d.colors) do
            local top, side = value:match("^(%x+),(%x+)$")
            if top ~= nil then
                colors[name] = { top = parse_hex_color(top), side = parse_hex_color(side) }
            end
        end
    end
end

------------------------------------------------------------------------------
-- Lining up Leon and the Minecraft player
------------------------------------------------------------------------------

local function leon_position()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local ctx = cm and try_call(cm, "getPlayerContextRef")
    local body = ctx and try_call(ctx, "get_BodyGameObject")
    local transform = body and try_call(body, "get_Transform")
    return transform and try_call(transform, "get_Position")
end

local function set_anchor(leon)
    local elevation = (type(bridge.move) == "table" and bridge.move.elevation) or 0
    local flat_y = type(bridge.flat_y) == "number" and bridge.flat_y or bridge.pos.y
    anchor_re4 = { x = leon.x, y = leon.y - elevation, z = leon.z }
    anchor_mc = { x = bridge.pos.x, y = flat_y, z = bridge.pos.z }
    debug.status = "anchored"
end

-- Minecraft coordinates -> RE4 position
local function to_re4(x, y, z)
    return Vector3f.new(anchor_re4.x + (x - anchor_mc.x), anchor_re4.y + (y - anchor_mc.y), anchor_re4.z + (z - anchor_mc.z))
end

-- Tell Minecraft where Leon is (in Minecraft coordinates), so it can pull its player back next to him
local function write_sync(leon)
    sync_seq = sync_seq + 1
    pcall(json.dump_file, SYNC_FILE, {
        seq = sync_seq,
        active = true,
        x = anchor_mc.x + (leon.x - anchor_re4.x),
        z = anchor_mc.z + (leon.z - anchor_re4.z),
    })
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

-- Each face: normal, the 4 corners as offsets in the unit cube, and how bright it is (like Minecraft)
local FACES = {
    { n = { 0, 1, 0 }, c = { { 0, 1, 0 }, { 1, 1, 0 }, { 1, 1, 1 }, { 0, 1, 1 } }, shade = 1.0, top = true },
    { n = { 0, -1, 0 }, c = { { 0, 0, 0 }, { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 } }, shade = 0.5 },
    { n = { 1, 0, 0 }, c = { { 1, 0, 0 }, { 1, 0, 1 }, { 1, 1, 1 }, { 1, 1, 0 } }, shade = 0.6 },
    { n = { -1, 0, 0 }, c = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 1, 1 }, { 0, 0, 1 } }, shade = 0.6 },
    { n = { 0, 0, 1 }, c = { { 0, 0, 1 }, { 0, 1, 1 }, { 1, 1, 1 }, { 1, 0, 1 } }, shade = 0.8 },
    { n = { 0, 0, -1 }, c = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 } }, shade = 0.8 },
}

local function camera_position()
    local camera = sdk.get_primary_camera()
    local obj = camera and try_call(camera, "get_GameObject")
    local transform = obj and try_call(obj, "get_Transform")
    return transform and try_call(transform, "get_Position")
end

local function project(p)
    local ok, s = pcall(draw.world_to_screen, p)
    if ok and s ~= nil then return s end
    return nil
end

local function draw_quad(s, color, edge)
    if quad_mode == nil then
        quad_mode = pcall(draw.filled_quad, s[1].x, s[1].y, s[2].x, s[2].y, s[3].x, s[3].y, s[4].x, s[4].y, color) and "quad" or "lines"
    elseif quad_mode == "quad" then
        draw.filled_quad(s[1].x, s[1].y, s[2].x, s[2].y, s[3].x, s[3].y, s[4].x, s[4].y, color)
    end
    if edge ~= nil or quad_mode == "lines" then
        local line_color = edge or color
        for i = 1, 4 do
            local a, b = s[i], s[i % 4 + 1]
            pcall(draw.line, a.x, a.y, b.x, b.y, line_color)
        end
    end
end

local function collect_faces(cam)
    local faces = {}
    local max_d2 = settings.max_distance * settings.max_distance
    for _, b in ipairs(blocks) do
        local bx, by, bz = b[1], b[2], b[3]
        local origin = to_re4(bx, by, bz)
        local cx, cy, cz = origin.x + 0.5 - cam.x, origin.y + 0.5 - cam.y, origin.z + 0.5 - cam.z
        if cx * cx + cy * cy + cz * cz <= max_d2 then
            local color = colors[b[4]] or { top = { 128, 128, 128 }, side = { 128, 128, 128 } }
            for _, face in ipairs(FACES) do
                local n = face.n
                local covered = block_set[(bx + n[1]) .. "," .. (by + n[2]) .. "," .. (bz + n[3])]
                -- Face center relative to the camera; only faces turned toward the camera are visible
                local fx = cx + n[1] * 0.5
                local fy = cy + n[2] * 0.5
                local fz = cz + n[3] * 0.5
                if not covered and (n[1] * fx + n[2] * fy + n[3] * fz) < 0 then
                    table.insert(faces, {
                        origin = origin, face = face, dist = fx * fx + fy * fy + fz * fz,
                        color = rgb(face.top and color.top or color.side, face.shade),
                    })
                end
            end
        end
    end
    -- Far faces first, so near ones are drawn over them
    table.sort(faces, function(a, b) return a.dist > b.dist end)
    return faces
end

local function draw_face(entry, edge)
    local screen = {}
    for i, c in ipairs(entry.face.c) do
        local s = project(entry.origin + Vector3f.new(c[1], c[2], c[3]))
        if s == nil then return false end
        screen[i] = s
    end
    draw_quad(screen, entry.color, edge)
    return true
end

-- Minecraft's black outline around the block you're looking at
local function draw_target()
    local t = bridge.target
    if type(t) ~= "table" then return end
    local origin = to_re4(t.x, t.y, t.z)
    for _, face in ipairs(FACES) do
        local screen = {}
        local ok = true
        for i, c in ipairs(face.c) do
            local s = project(origin + Vector3f.new(c[1], c[2], c[3]))
            if s == nil then ok = false break end
            screen[i] = s
        end
        if ok then
            for i = 1, 4 do
                local a, b = screen[i], screen[i % 4 + 1]
                pcall(draw.line, a.x, a.y, b.x, b.y, 0xFF000000)
            end
        end
    end
end

------------------------------------------------------------------------------

-- The overlay plugin is drawing (it writes a heartbeat into minecraft_overlay_plugin.json)
local plugin_beat, plugin_beat_frame, plugin_ready = nil, -100000, false
local function overlay_plugin_alive()
    if frame % 30 == 0 then
        local ok, p = pcall(json.load_file, "minecraft_overlay_plugin.json")
        if ok and type(p) == "table" then
            if p.beat ~= plugin_beat then
                plugin_beat = p.beat
                plugin_beat_frame = frame
            end
            plugin_ready = p.ready == true
        end
    end
    return plugin_ready and frame - plugin_beat_frame < 240
end

re.on_frame(function()
    frame = frame + 1
    read_bridge()

    local f9 = false
    local ok, down = pcall(function() return reframework:is_key_down(0x78) end)
    f9 = ok and down == true
    local reanchor = f9 and not f9_was_down
    f9_was_down = f9

    if not settings.enabled or not connected() then
        debug.status = "waiting for Minecraft"
        return
    end

    local leon = leon_position()
    if leon == nil then
        last_leon = nil
        return
    end
    -- In terrain mode (minecraft_terrain.lua) both worlds share the terrain script's anchor
    if frame % 30 == 0 then
        local ok, t = pcall(json.load_file, "minecraft_terrain.json")
        if ok and type(t) == "table" and type(t.anchor_re4) == "table" and type(bridge.anchor) == "table"
            and t.epoch ~= 0 and bridge.anchor.epoch == t.epoch then
            anchor_re4 = { x = t.anchor_re4.x, y = t.anchor_re4.y, z = t.anchor_re4.z }
            anchor_mc = { x = bridge.anchor.x, y = bridge.anchor.y, z = bridge.anchor.z }
            terrain_mode = true
        end
    end
    if terrain_mode then reanchor = false end
    -- New area (save loaded, door, cutscene): line the two worlds up again here
    if last_leon ~= nil then
        local dx, dz = leon.x - last_leon.x, leon.z - last_leon.z
        if dx * dx + dz * dz > REANCHOR_DISTANCE * REANCHOR_DISTANCE then reanchor = true end
    end
    last_leon = Vector3f.new(leon.x, leon.y, leon.z)
    if anchor_re4 == nil or reanchor then set_anchor(leon) end

    if frame % SYNC_EVERY_FRAMES == 0 and not reanchor and not terrain_mode then write_sync(leon) end
    load_blocks()

    -- With the overlay plugin running, Minecraft draws your blocks itself (real models and textures);
    -- these flat cubes are only the fallback. The target outline is still drawn here.
    if bridge.blocks_in_overlay == true and overlay_plugin_alive() then
        debug.faces = 0
        debug.status = "Minecraft draws the blocks"
        draw_target()
        return
    end

    local cam = camera_position()
    if cam == nil then return end
    local faces = collect_faces(cam)
    local start = math.max(1, #faces - MAX_FACES + 1)
    local drawn = 0
    for i = start, #faces do
        if draw_face(faces[i], settings.outlines and 0x60000000 or nil) then drawn = drawn + 1 end
    end
    debug.faces = drawn
    draw_target()
end)

local function draw_ui()
    if imgui.tree_node("Minecraft Blocks") then
        local changed
        changed, settings.enabled = imgui.checkbox("Show Minecraft blocks", settings.enabled)
        changed, settings.outlines = imgui.checkbox("Block edges", settings.outlines)
        changed, settings.max_distance = imgui.slider_int("Draw distance (blocks)", settings.max_distance, 8, 48)
        if imgui.button("Re-anchor here (F9)") and bridge ~= nil and connected() then
            local leon = leon_position()
            if leon ~= nil then set_anchor(leon) end
        end
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Status: " .. debug.status)
            imgui.text(string.format("Blocks: %d   Faces drawn: %d   Draw mode: %s", #blocks, debug.faces, tostring(quad_mode)))
            if anchor_mc ~= nil then
                imgui.text(string.format("Anchor: Minecraft %.1f, %.1f, %.1f", anchor_mc.x, anchor_mc.y, anchor_mc.z))
            end
        end
        imgui.tree_pop()
    end
end

-- Drawn inside the one Minecraft menu (minecraft_menu.lua, which also saves the settings), or on its own
MinecraftRE4Menu = MinecraftRE4Menu or { sections = {}, settings = {} }
MinecraftRE4Menu.sections.blocks = { order = 40, draw = draw_ui }
MinecraftRE4Menu.settings.blocks = settings
re.on_draw_ui(function()
    if not MinecraftRE4Menu.present then draw_ui() end
end)
