-- Minecraft Lights for RE4 Remake (REFramework Lua script) - experimental
-- The light blocks near you in Minecraft (torches, lanterns, campfires, glowstone, sea lanterns, lit furnaces...)
-- become real RE4 lights: RE4's own point lights at their spots, as bright and as far-reaching as their Minecraft
-- light level and coloured by kind, so they light RE4's floors, walls, enemies and Leon like RE4's own lamps.
--  * The RE4 Bridge Minecraft mod lists the light blocks nearest its player (at most 24) in minecraft_bridge.json:
--    "lights" = "x,y,z,level,RRGGBB,inside;" per light, in RE4's coordinates (inside = 1: the light sits in a full
--    block such as glowstone, which must not shadow it).
--  * This script keeps at most 16 RE4 light objects on the ones nearest Leon. A light object is moved and set up
--    again only when its light changes; ones no longer needed are switched off and kept for reuse.
-- Which of RE4's light settings exist isn't known for sure yet: each is tried, and this script's menu section (and
-- the diagnostics report) says which ones worked. Off by default; when off it does nothing at all.
-- Settings: press Insert -> Script Generated UI -> Minecraft -> Minecraft Lights

local BRIDGE_FILE = "minecraft_bridge.json"
local MAX_LIGHTS = 16             -- RE4 light objects at most (on the Minecraft lights nearest Leon)
local READ_EVERY_FRAMES = 3       -- Minecraft writes 20 times a second
local PICK_EVERY_FRAMES = 30      -- Leon walks: the nearest lights are picked again this often
local STALE_FRAMES = 90           -- nothing new from Minecraft for this long: lights off
local MAX_NEW_PER_FRAME = 4       -- new light objects made in one frame at most
local RETRY_FRAMES = 300          -- after a light object couldn't be made, wait this long before trying again
local RANGE_FULL = 8.0            -- metres a level 15 light reaches (less for dimmer ones)
local INTENSITY_FULL = 800.0      -- RE4 intensity of a level 15 light, times the Brightness setting
local SOURCE_RADIUS = 0.1         -- size of the glowing spot (a torch flame)

local settings = { enabled = false, brightness = 1.0, shadows = false, show_debug = false }

local state = {
    frame = 0,
    text = nil,               -- the "lights" text last read from Minecraft
    lights = {},              -- what it says: { key, x, y, z, level, r, g, b, inside, look }
    bridge_seq = nil,
    bridge_frame = -100000,   -- frame Minecraft last wrote something new
    picked_frame = -100000,
    dirty = true,             -- the lights must be picked and placed again
    applied = nil,            -- the settings the lights were last set up with
    objects = {},             -- light objects made: { go, tr, light, name, key, look, shown }
    retry_at = 0,
}
-- setters: which of RE4's light setters worked ("works" / "failed"); values: what the first light reads back
local debug = { status = "off", sent = 0, shown = 0, objects = 0, errors = {}, setters = {}, values = nil }
-- For the diagnostics report (minecraft_diagnostics.lua)
MinecraftRE4Lights = { settings = settings, debug = debug, state = state }

local function note_error(text)
    if #debug.errors < 12 then debug.errors[#debug.errors + 1] = text end
end

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function leon_context()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    return cm and try_call(cm, "getPlayerContextRef")
end

local function leon_position(ctx)
    local body = try_call(ctx, "get_BodyGameObject")
    local tr = body and try_call(body, "get_Transform")
    return tr and try_call(tr, "get_Position")
end

------------------------------------------------------------------------------
-- RE4's light setters (not all confirmed): each is tried, and one that never worked is given up after a few tries
------------------------------------------------------------------------------

local SETTERS = { "set_Enabled", "set_Color", "set_Intensity", "set_AttenuationRange", "set_Radius",
    "set_ShadowCastFlag", "set_ShadowEnable", "set_BlackBodyRadiation", "set_UsingSameIntensity" }
local GETTERS = { "get_Enabled", "get_Color", "get_Intensity", "get_AttenuationRange", "get_Radius",
    "get_ShadowCastFlag", "get_ShadowEnable" }
local GIVE_UP_AFTER = 3
local tries = {}   -- setter name -> { ok = n, failed = n }

local function set(o, name, value)
    local t = tries[name]
    if t == nil then
        t = { ok = 0, failed = 0 }
        tries[name] = t
    end
    if t.ok == 0 and t.failed >= GIVE_UP_AFTER then return false end
    local ok = pcall(function() o.light:call(name, value) end)
    if ok then t.ok = t.ok + 1 else t.failed = t.failed + 1 end
    debug.setters[name] = t.ok > 0 and "works" or "failed"
    return ok
end

-- What the first light reads back after it was set up (did the setters that "worked" change anything?)
local function read_back(o)
    local values = {}
    for _, name in ipairs(GETTERS) do
        local ok, v = pcall(function() return o.light:call(name) end)
        if not ok then
            values[name] = "failed"
        elseif type(v) == "userdata" or type(v) == "table" then
            local okv, text = pcall(function() return string.format("%.2f, %.2f, %.2f", v.x, v.y, v.z) end)
            values[name] = okv and text or tostring(v)
        else
            values[name] = tostring(v)
        end
    end
    debug.values = values
end

------------------------------------------------------------------------------
-- Light objects
------------------------------------------------------------------------------

local create_method, light_type = nil, nil
pcall(function() create_method = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)") end)
pcall(function() light_type = sdk.typeof("via.render.PointLight") end)

-- Every object gets its own name, remembered: objects RE4 kept through a loading screen are found again by name
local made_names, name_counter = {}, 0

local function new_light()
    if create_method == nil or light_type == nil then return nil, "via.GameObject.create or via.render.PointLight missing" end
    name_counter = name_counter + 1
    local name = string.format("MinecraftLight_%d", name_counter)
    made_names[name] = true
    local okc, go = pcall(function() return create_method:call(nil, name) end)
    if not okc or go == nil then
        made_names[name] = nil
        return nil, "create failed: " .. tostring(go)
    end
    pcall(function() go = go:add_ref() end)
    pcall(function() go:call(".ctor") end)
    local okl, light = pcall(function() return go:call("createComponent(System.Type)", light_type) end)
    local tr = try_call(go, "get_Transform")
    if not okl or light == nil or tr == nil then
        pcall(function() go:call("destroy(via.GameObject)", go) end)
        made_names[name] = nil
        return nil, okl and light ~= nil and "no transform" or ("createComponent failed: " .. tostring(light))
    end
    pcall(function() light = light:add_ref() end)
    pcall(function() light:call(".ctor") end)
    local o = { go = go, tr = tr, light = light, name = name }
    -- what stays the same for every light: plain colour (not a temperature), one intensity, a small glowing spot
    set(o, "set_BlackBodyRadiation", false)
    set(o, "set_UsingSameIntensity", false)
    set(o, "set_Radius", SOURCE_RADIUS)
    return o
end

local function show(o)
    if o.shown ~= true then
        o.shown = true
        pcall(function() o.go:call("set_DrawSelf", true) end)
        set(o, "set_Enabled", true)
    end
end

-- Switched off and kept (also at no brightness, in case switching off doesn't work); set up again when shown
local function hide(o)
    if o.shown ~= false then
        o.shown = false
        pcall(function() o.go:call("set_DrawSelf", false) end)
        set(o, "set_Enabled", false)
        set(o, "set_Intensity", 0.0)
        o.look = nil
    end
end

local function hide_all()
    for _, o in ipairs(state.objects) do hide(o) end
    debug.shown = 0
    state.dirty = true
end

-- touch = false: RE4 may have freed them (loading screen), so they are only forgotten (and looked for by name later)
local function destroy_all(touch)
    for _, o in ipairs(state.objects) do
        if touch then pcall(function() o.go:call("destroy(via.GameObject)", o.go) end) end
    end
    state.objects = {}
    if touch then made_names = {} end
    state.dirty = true
    debug.shown, debug.objects = 0, 0
end

-- After a loading screen: lights of ours that RE4 kept (forgotten while it loaded) are looked up by name in the
-- current scene and removed, so no light stays behind where the torch no longer is
local function remove_survivors()
    if next(made_names) == nil then return end
    local names = made_names
    made_names = {}
    local ok, scene = pcall(function()
        return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"),
            "get_CurrentScene()")
    end)
    if not ok or scene == nil then return end
    local removed = 0
    for name in pairs(names) do
        local okf, go = pcall(function() return scene:call("findGameObject(System.String)", name) end)
        if okf and go ~= nil and pcall(function() go:call("destroy(via.GameObject)", go) end) then removed = removed + 1 end
    end
    if removed > 0 then note_error(string.format("removed %d lights left from before the loading screen", removed)) end
end

------------------------------------------------------------------------------
-- Lights from Minecraft
------------------------------------------------------------------------------

local LIGHT_PATTERN = "([^,;]+),([^,;]+),([^,;]+),(%d+),(%x+),([01]);"

local function parse(text)
    local out = {}
    for x, y, z, level, hex, inside in text:gmatch(LIGHT_PATTERN) do
        local px, py, pz, lv, c = tonumber(x), tonumber(y), tonumber(z), tonumber(level), tonumber(hex, 16)
        -- (a coordinate that isn't a plain number, like NaN, leaves the light out)
        if px and py and pz and lv and c and lv > 0 and math.abs(px) < 1e6 and math.abs(py) < 1e6 and math.abs(pz) < 1e6 then
            out[#out + 1] = { key = x .. "," .. y .. "," .. z, x = px, y = py, z = pz, level = math.min(lv, 15),
                r = ((c >> 16) & 0xFF) / 255, g = ((c >> 8) & 0xFF) / 255, b = (c & 0xFF) / 255, inside = inside == "1",
                look = level .. "," .. hex .. "," .. inside }
        end
    end
    return out
end

local function read_bridge()
    local ok, data = pcall(json.load_file, BRIDGE_FILE)
    if not ok or type(data) ~= "table" or data.seq == nil or data.seq == state.bridge_seq then return end
    -- a file seen for the first time may be left from a Minecraft that is gone (closed or crashed in a world):
    -- it only counts once its seq changes while we watch
    local first = state.bridge_seq == nil
    state.bridge_seq = data.seq
    if first then return end
    state.bridge_frame = state.frame
    local text = (data.in_world == true and type(data.lights) == "string") and data.lights or ""
    if text ~= state.text then
        state.text = text
        state.lights = parse(text)
        debug.sent = #state.lights
        state.dirty = true
    end
end

local function settings_text()
    return tostring(settings.brightness) .. "," .. tostring(settings.shadows)
end

-- A light object on a Minecraft light: moved only when it is another light, set up again only when the light's
-- level or colour (or the settings) changed
local function place(o, l)
    if o.key ~= l.key then
        o.key = nil
        if not pcall(function() o.tr:call("set_Position", Vector3f.new(l.x, l.y, l.z)) end) then return false end
        o.key = l.key
    end
    show(o)
    -- a light inside its own full block never casts shadows: the block's RE4 copy would swallow it
    local shadows = settings.shadows == true and not l.inside
    local look = l.look .. "," .. settings_text() .. "," .. tostring(shadows)
    if o.look ~= look then
        local f = l.level / 15
        set(o, "set_Color", Vector3f.new(l.r, l.g, l.b))
        set(o, "set_Intensity", INTENSITY_FULL * f * settings.brightness)
        set(o, "set_AttenuationRange", RANGE_FULL * f)
        set(o, "set_ShadowCastFlag", shadows)
        set(o, "set_ShadowEnable", shadows)
        o.look = look
        if debug.values == nil then read_back(o) end
    end
    return true
end

-- The Minecraft lights nearest Leon get the light objects: ones already on such a light stay (no calls into RE4),
-- the others move to the remaining lights, new ones are made (a few per frame) and the rest are switched off
local function update_lights(leon)
    state.dirty = false
    state.picked_frame = state.frame
    state.applied = settings_text()
    local wanted = {}
    for _, l in ipairs(state.lights) do
        local dx, dy, dz = l.x - leon.x, l.y - leon.y, l.z - leon.z
        l.d2 = dx * dx + dy * dy + dz * dz
        wanted[#wanted + 1] = l
    end
    table.sort(wanted, function(a, b) return a.d2 < b.d2 end)
    for i = #wanted, MAX_LIGHTS + 1, -1 do wanted[i] = nil end
    local want, on_light, free = {}, {}, {}
    for _, l in ipairs(wanted) do want[l.key] = true end
    for _, o in ipairs(state.objects) do
        if o.key ~= nil and want[o.key] and on_light[o.key] == nil then on_light[o.key] = o else free[#free + 1] = o end
    end
    local shown, made = 0, 0
    for _, l in ipairs(wanted) do
        local o = on_light[l.key] or table.remove(free)
        if o == nil and #state.objects < MAX_LIGHTS and made < MAX_NEW_PER_FRAME and state.frame >= state.retry_at then
            local err
            o, err = new_light()
            if o == nil then
                note_error("light: " .. tostring(err))
                state.retry_at = state.frame + RETRY_FRAMES
            else
                state.objects[#state.objects + 1] = o
                made = made + 1
            end
        end
        if o ~= nil then
            if place(o, l) then
                shown = shown + 1
            else
                note_error("could not move a light")
                hide(o)
            end
        end
    end
    for _, o in ipairs(free) do hide(o) end
    -- more lights wanted than could be made this frame: go on next frame
    if made >= MAX_NEW_PER_FRAME and shown < #wanted then state.dirty = true end
    debug.shown, debug.objects = shown, #state.objects
end

------------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------------

local was_present = false

re.on_application_entry("LateUpdateBehavior", function()
    state.frame = state.frame + 1
    -- (switched on again later: nothing is lit until Minecraft writes anew, as it may have closed meanwhile)
    if not settings.enabled then state.bridge_seq, state.bridge_frame = nil, -100000 end
    -- off, and nothing of ours left anywhere: nothing to do
    if not settings.enabled and #state.objects == 0 and next(made_names) == nil then
        debug.status = "off"
        return
    end
    local ctx = leon_context()
    if ctx == nil then
        -- loading or title screen: RE4 may be destroying the area, our lights with it; don't touch them
        if was_present then destroy_all(false) end
        was_present = false
        debug.status = settings.enabled and "waiting for Leon" or "off"
        return
    end
    if not was_present then pcall(remove_survivors) end
    was_present = true
    if not settings.enabled then
        destroy_all(true)
        debug.status = "off"
        return
    end
    if state.frame % READ_EVERY_FRAMES == 0 then pcall(read_bridge) end
    if state.frame - state.bridge_frame > STALE_FRAMES then
        -- Minecraft closed or stopped writing: lights off until it is back
        if debug.shown > 0 then hide_all() end
        debug.status = "waiting for Minecraft"
        return
    end
    if settings_text() ~= state.applied then state.dirty = true end
    if state.dirty or state.frame - state.picked_frame >= PICK_EVERY_FRAMES then
        local leon = leon_position(ctx)
        if leon ~= nil then
            local ok, err = pcall(update_lights, leon)
            if not ok then note_error("lights: " .. tostring(err)) end
        end
    end
    debug.status = state.frame < state.retry_at and "on, but RE4 lights could not be made (see errors)" or "on"
end)

re.on_script_reset(function()
    destroy_all(true)
end)

-- "Color works, Intensity failed, ..." in a fixed order
local function setter_summary()
    local parts = {}
    for _, name in ipairs(SETTERS) do
        local s = debug.setters[name]
        if s ~= nil then parts[#parts + 1] = (name:gsub("^set_", "")) .. " " .. s end
    end
    return #parts > 0 and table.concat(parts, ", ") or "not tried yet"
end

local function draw_ui()
    if not imgui.tree_node("Minecraft Lights") then return end
    local changed
    changed, settings.enabled = imgui.checkbox("Minecraft lights light RE4 (experimental)", settings.enabled)
    changed, settings.brightness = imgui.slider_float("Brightness", settings.brightness, 0.1, 4.0)
    changed, settings.shadows = imgui.checkbox("Lights cast shadows (slower)", settings.shadows)
    imgui.text(string.format("Torches, lanterns, glowstone... near you become RE4 lights (the %d nearest Leon).", MAX_LIGHTS))
    imgui.text(string.format("Status: %s | Minecraft lights near you %d | RE4 lights on %d (made %d)",
        debug.status, debug.sent, debug.shown, debug.objects))
    imgui.text("RE4 light settings: " .. setter_summary())
    changed, settings.show_debug = imgui.checkbox("Show errors and light values", settings.show_debug)
    if settings.show_debug then
        for _, e in ipairs(debug.errors) do imgui.text("  " .. e) end
        for _, name in ipairs(GETTERS) do
            if debug.values ~= nil and debug.values[name] ~= nil then imgui.text("  " .. name .. " = " .. debug.values[name]) end
        end
    end
    imgui.tree_pop()
end

-- Drawn inside the one Minecraft menu (minecraft_menu.lua, which also saves the settings), or on its own
MinecraftRE4Menu = MinecraftRE4Menu or { sections = {}, settings = {} }
MinecraftRE4Menu.sections.lights = { order = 55, draw = draw_ui }
MinecraftRE4Menu.settings.lights = settings
re.on_draw_ui(function()
    if not MinecraftRE4Menu.present then draw_ui() end
end)
