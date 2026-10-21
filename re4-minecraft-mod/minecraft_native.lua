-- Minecraft Real Mobs for RE4 Remake (REFramework Lua script) - experimental
-- Minecraft's mobs as real RE4 objects: RE4 itself draws them, so RE4's lights, shadows, fog and walls work on them
-- like on its own things (instead of a Minecraft picture laid over RE4's).
--  * The RE4 Bridge Minecraft mod writes each mob part (a few textured cuboids) as an RE4 model file with its
--    texture into <RE4>\natives\STM\minecraft\ (from Minecraft's own model and texture on this PC), and lists them in
--    reframework\data\minecraft_native_assets.json.
--  * Every frame it writes where each part is (minecraft_native_poses.json); this script moves one real RE4 object
--    per part there, and tells Minecraft which parts it shows (minecraft_native_status.json), so Minecraft stops
--    drawing those over the picture.
-- Needs REFramework's Loose File Loader: Insert -> LooseFileLoader -> Enable (the installer switches it on).
-- Settings: press Insert -> Script Generated UI -> Minecraft Real Mobs

local SETTINGS_FILE = "minecraft_native_settings.json"
local STATUS_FILE = "minecraft_native_status.json"
local POSES_FILE = "minecraft_native_poses.json"
local ASSETS_FILE = "minecraft_native_assets.json"
local ASSETS_EVERY_FRAMES = 30
local STATUS_EVERY_FRAMES = 10
local STALE_FRAMES = 60          -- no new poses from Minecraft for this long: hide everything

local settings = { enabled = false, show_debug = false }
do
    local ok, saved = pcall(json.load_file, SETTINGS_FILE)
    if ok and type(saved) == "table" and type(saved.enabled) == "boolean" then settings.enabled = saved.enabled end
end

local state = {
    frame = 0,
    assets = {},          -- export id (string) -> { mesh = holder, material = holder } or { error = text }
    objects = {},         -- "mob:export:n" -> { go, tr, mesh, export, seen = frame, shown = bool }
    pool = {},            -- export id -> list of hidden objects for reuse
    poses_seq = nil,
    poses_frame = 0,
    session = nil,        -- the Minecraft session the loaded parts belong to (part numbers restart per session)
    quat_order = nil,     -- how Quaternion.new takes its numbers ("wxyz" or "xyzw")
    acked = {},           -- export ids with a working object
}
local debug = { status = "off", errors = {}, loaded = 0, failed = 0, shown = 0, pooled = 0 }
-- For the diagnostics report (minecraft_diagnostics.lua): how loading and placing the parts went
MinecraftRE4Native = { debug = debug, settings = settings, state = state }

local function note_error(text)
    if #debug.errors < 12 then debug.errors[#debug.errors + 1] = text end
end

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function leon_present()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local ctx = cm and try_call(cm, "getPlayerContextRef")
    return ctx ~= nil
end

------------------------------------------------------------------------------
-- Resources and objects
------------------------------------------------------------------------------

local function load_holder(resource_type, holder_type, path)
    local ok, res = pcall(function() return sdk.create_resource(resource_type, path) end)
    if not ok or res == nil then return nil, "not found: " .. path end
    pcall(function() res = res:add_ref() end)
    local okh, holder = pcall(function() return res:create_holder(holder_type) end)
    if not okh or holder == nil then return nil, "no holder for " .. path end
    pcall(function() holder = holder:add_ref() end)
    return holder
end

local destroy_all

local function load_assets()
    local ok, data = pcall(json.load_file, ASSETS_FILE)
    if not ok or type(data) ~= "table" or type(data.exports) ~= "table" then return end
    if data.session ~= state.session then
        -- Minecraft restarted: its part numbers mean other parts now
        destroy_all(true)
        state.assets = {}
        state.acked = {}
        state.session = data.session
    end
    for id, e in pairs(data.exports) do
        if state.assets[id] == nil and type(e) == "table" and type(e.mesh) == "string" and type(e.material) == "string" then
            local mesh, merr = load_holder("via.render.MeshResource", "via.render.MeshResourceHolder", e.mesh)
            local material, terr = load_holder("via.render.MeshMaterialResource", "via.render.MeshMaterialResourceHolder", e.material)
            if mesh ~= nil and material ~= nil then
                state.assets[id] = { mesh = mesh, material = material }
                debug.loaded = debug.loaded + 1
            else
                state.assets[id] = { error = merr or terr }
                debug.failed = debug.failed + 1
                note_error("part " .. id .. ": " .. tostring(merr or terr))
            end
        end
    end
end

local create_method = nil
pcall(function() create_method = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)") end)
local mesh_type = sdk.typeof("via.render.Mesh")

local function new_object(id, asset)
    if create_method == nil or mesh_type == nil then return nil, "via.GameObject.create or via.render.Mesh missing" end
    local okc, go = pcall(function() return create_method:call(nil, "MinecraftPart_" .. id) end)
    if not okc or go == nil then return nil, "create failed: " .. tostring(go) end
    pcall(function() go = go:add_ref() end)
    pcall(function() go:call(".ctor") end)
    local okm, mesh = pcall(function() return go:call("createComponent(System.Type)", mesh_type) end)
    if not okm or mesh == nil then return nil, "createComponent failed: " .. tostring(mesh) end
    pcall(function() mesh = mesh:add_ref() end)
    pcall(function() mesh:call(".ctor") end)
    local oks = pcall(function() mesh:call("setMesh", asset.mesh) end)
    local okt = pcall(function() mesh:call("set_Material", asset.material) end)
    if not oks or not okt then return nil, "setMesh/set_Material failed" end
    -- it moves every frame: a dynamic mesh that casts shadows
    pcall(function() mesh:call("set_ForceDynamicMesh", true) end)
    pcall(function() mesh:call("set_StaticMesh", false) end)
    pcall(function() mesh:call("set_DrawShadowCast", true) end)
    local tr = try_call(go, "get_Transform")
    if tr == nil then return nil, "no transform" end
    return { go = go, tr = tr, mesh = mesh, export = id, shown = true }
end

local function show(o, on)
    if o.shown ~= on then
        o.shown = on
        pcall(function() o.go:call("set_DrawSelf", on) end)
    end
end

local function take_object(id)
    local free = state.pool[id]
    if free ~= nil and #free > 0 then
        local o = table.remove(free)
        debug.pooled = debug.pooled - 1
        show(o, true)
        return o
    end
    local asset = state.assets[id]
    if asset == nil or asset.mesh == nil then return nil end
    local o, err = new_object(id, asset)
    if o == nil then
        asset.error = err
        asset.mesh = nil
        note_error("part " .. id .. ": " .. tostring(err))
        return nil
    end
    state.acked[id] = true
    return o
end

destroy_all = function(touch)
    for key, o in pairs(state.objects) do
        if touch then pcall(function() o.go:call("destroy(via.GameObject)", o.go) end) end
        state.objects[key] = nil
    end
    for id, list in pairs(state.pool) do
        for _, o in ipairs(list) do
            if touch then pcall(function() o.go:call("destroy(via.GameObject)", o.go) end) end
        end
        state.pool[id] = nil
    end
    debug.pooled = 0
end

------------------------------------------------------------------------------
-- Poses
------------------------------------------------------------------------------

local function make_quat(x, y, z, w)
    if state.quat_order == nil then
        -- find out once how Quaternion.new takes its numbers
        local ok, q = pcall(function() return Quaternion.new(1, 2, 3, 4) end)
        if ok and q ~= nil and q.w == 1 and q.x == 2 then
            state.quat_order = "wxyz"
        elseif ok and q ~= nil and q.x == 1 and q.w == 4 then
            state.quat_order = "xyzw"
        else
            state.quat_order = "wxyz"
        end
    end
    if state.quat_order == "wxyz" then return Quaternion.new(w, x, y, z) end
    return Quaternion.new(x, y, z, w)
end

-- One snapshot from Minecraft: every part shown this frame. Parts not in it are hidden and kept for reuse.
local function apply_poses(parts)
    local entries, present, count = {}, {}, {}
    for mob, id, px, py, pz, qx, qy, qz, qw, sx, sy, sz in parts:gmatch(
            "(%-?%d+),(%d+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^;]+);") do
        local pair = mob .. ":" .. id
        count[pair] = (count[pair] or 0) + 1
        local key = pair .. ":" .. count[pair]
        present[key] = true
        entries[#entries + 1] = { key = key, id = id, values = { px, py, pz, qx, qy, qz, qw, sx, sy, sz } }
    end
    for key, o in pairs(state.objects) do
        if not present[key] then
            show(o, false)
            state.objects[key] = nil
            state.pool[o.export] = state.pool[o.export] or {}
            table.insert(state.pool[o.export], o)
            debug.pooled = debug.pooled + 1
        end
    end
    local shown = 0
    for _, e in ipairs(entries) do
        local o = state.objects[e.key]
        if o == nil and state.assets[e.id] ~= nil and state.assets[e.id].mesh ~= nil then
            o = take_object(e.id)
            state.objects[e.key] = o
        end
        if o ~= nil then
            local v = e.values
            local ok = pcall(function()
                o.tr:call("set_Position", Vector3f.new(tonumber(v[1]), tonumber(v[2]), tonumber(v[3])))
                o.tr:call("set_Rotation", make_quat(tonumber(v[4]), tonumber(v[5]), tonumber(v[6]), tonumber(v[7])))
                o.tr:call("set_LocalScale", Vector3f.new(tonumber(v[8]), tonumber(v[9]), tonumber(v[10])))
            end)
            if ok then
                show(o, true)
                shown = shown + 1
            else
                note_error("could not move part " .. e.id)
                state.objects[e.key] = nil
                state.acked[e.id] = nil
            end
        end
    end
    debug.shown = shown
end

-- Minecraft stopped sending (closed, frozen, Real mobs off there): hide everything
local function hide_all()
    for key, o in pairs(state.objects) do
        show(o, false)
        state.objects[key] = nil
        state.pool[o.export] = state.pool[o.export] or {}
        table.insert(state.pool[o.export], o)
        debug.pooled = debug.pooled + 1
    end
    debug.shown = 0
end

local function read_poses()
    local ok, data = pcall(json.load_file, POSES_FILE)
    if not ok or type(data) ~= "table" or data.seq == nil or data.seq == state.poses_seq
            or data.session ~= state.session then
        if state.frame - state.poses_frame > STALE_FRAMES then hide_all() end
        return
    end
    state.poses_seq = data.seq
    state.poses_frame = state.frame
    if type(data.parts) == "string" then apply_poses(data.parts) end
end

local function write_status()
    local acked = {}
    for id in pairs(state.acked) do acked[#acked + 1] = tonumber(id) end
    pcall(json.dump_file, STATUS_FILE, { enabled = settings.enabled, acked = acked, frame = state.frame, session = state.session })
end

------------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------------

local was_present = false

-- Late in RE4's frame, after its own movement: our objects go where Minecraft's parts are
re.on_application_entry("LateUpdateBehavior", function()
    state.frame = state.frame + 1
    local present = leon_present()
    if not present then
        -- loading or title screen: RE4 may be destroying the area, our objects with it; don't touch them
        if was_present then destroy_all(false) end
        was_present = false
        state.acked = {}
        if state.frame % STATUS_EVERY_FRAMES == 0 then write_status() end
        debug.status = "waiting for Leon"
        return
    end
    was_present = true
    if settings.enabled then
        if state.frame % ASSETS_EVERY_FRAMES == 0 then pcall(load_assets) end
        local ok, err = pcall(read_poses)
        if not ok then note_error("poses: " .. tostring(err)) end
        debug.status = "on"
    else
        if next(state.objects) ~= nil or next(state.pool) ~= nil then destroy_all(true) end
        state.acked = {}
        debug.status = "off"
    end
    if state.frame % STATUS_EVERY_FRAMES == 0 then write_status() end
end)

re.on_script_reset(function()
    destroy_all(true)
    pcall(json.dump_file, STATUS_FILE, { enabled = false, acked = {}, frame = state.frame })
end)

local function draw_ui()
    if not imgui.tree_node("Minecraft Real Mobs") then return end
    local changed
    changed, settings.enabled = imgui.checkbox("Real RE4 mobs (experimental)", settings.enabled)
    if changed then pcall(json.dump_file, SETTINGS_FILE, { enabled = settings.enabled }) end
    imgui.text("Needs REFramework's LooseFileLoader enabled (Insert -> LooseFileLoader).")
    imgui.text(string.format("Status: %s | parts loaded %d, failed %d | shown %d, kept %d",
        debug.status, debug.loaded, debug.failed, debug.shown, debug.pooled))
    if debug.failed > 0 and debug.loaded == 0 then
        imgui.text("RE4 can't open the mob files: turn on Insert -> LooseFileLoader (or run install.bat with RE4")
        imgui.text("closed), then restart RE4. Minecraft keeps drawing the mobs meanwhile.")
    end
    changed, settings.show_debug = imgui.checkbox("Show errors", settings.show_debug)
    if settings.show_debug then
        for _, e in ipairs(debug.errors) do imgui.text("  " .. e) end
    end
    imgui.tree_pop()
end

-- Drawn inside the one Minecraft menu (minecraft_menu.lua, which also saves the settings), or on its own
MinecraftRE4Menu = MinecraftRE4Menu or { sections = {}, settings = {} }
MinecraftRE4Menu.sections.native = { order = 50, draw = draw_ui }
MinecraftRE4Menu.settings.native = settings
re.on_draw_ui(function()
    if not MinecraftRE4Menu.present then draw_ui() end
end)
