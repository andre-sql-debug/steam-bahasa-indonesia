-- Minecraft Terrain for RE4 Remake (REFramework Lua script)
-- Makes Minecraft's own physics move Leon on RE4's ground:
--  1. Scans RE4's floor heights and walls around Leon with RE4's physics raycasts (a 0.5 m grid) and sends
--     them to the RE4 Bridge Minecraft mod (reframework\data\minecraft_terrain.json).
--  2. Minecraft's player walks on that terrain with real Minecraft physics (walking, sprinting, jumping,
--     stepping up, falling, walls).
--  3. Leon is placed exactly where Minecraft's player is; RE4's own physics for Leon is switched off.
-- The worlds are lined up by an "anchor": RE4 position = anchor_re4 + (Minecraft position - anchor_mc).
-- A new anchor is made when Minecraft connects, when Leon is very far from the anchor, or with F9.
-- While minecraft_control.lua gives Leon to RE4 (ladders, doors, cutscenes, grabs, menus, F7), RE4 moves
-- him; afterwards Minecraft's player is moved to where Leon ended up ("sync"), keeping the same anchor so
-- the blocks you built stay where they were. The same happens when the game moves Leon by itself.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Terrain

local settings = {
    enabled = true,
    cell = 0.5,              -- grid size in meters
    radius = 10.0,           -- scanned radius around Leon
    cells_per_frame = 60,    -- each cell costs 3 raycasts
    show_grid = false,
    show_debug = false,
}

local TERRAIN_FILE = "minecraft_terrain.json"   -- relative to reframework\data
local BRIDGE_FILE = "minecraft_bridge.json"
local RAY_ABOVE = 2.0          -- floor rays start this far above Leon's feet...
local RAY_BELOW = 4.0          -- ...and look this far below them
local WALL_RAY_HEIGHT = 0.9    -- wall rays run this far above each cell's floor
local REFRESH_SECONDS = 5.0    -- rescan cells older than this (doors, moving things)
local RECENTER_DISTANCE = 1.5  -- start the scan around Leon again after he moved this far
local TELEPORT_DISTANCE = 3.0  -- the game moved Leon this far in one frame = move Minecraft's player too
local FAR_FROM_ANCHOR = 2000.0 -- farther than this sideways = new anchor
local FAR_ABOVE_BELOW = 60.0   -- this far up or down from the anchor = new anchor (Minecraft only follows
                               -- the RE4 terrain within 64 blocks of the anchor height)
local SYNC_TIMEOUT_FRAMES = 120
local ENEMY_RANGE = 48.0       -- RE4 enemies this close to Leon get a Minecraft stand-in (mobs can fight them)
local WRITE_EVERY_FRAMES = 6
local LOST_FRAMES = 60         -- no Minecraft authority for this long while connected = new anchor

local state = {
    frame = 0,
    time = 0,
    request_epoch = 0,
    epoch = 0,               -- anchor in use (matches Minecraft's anchor epoch)
    anchor_re4 = nil,
    anchor_mc = nil,
    cells = {},              -- "i,k" -> { h = number|false, flags = n, t = scan time }
    spiral = {},
    cursor = 1,
    center = nil,            -- RE4 position the scan is centered on
    done_radius = 0,
    seq = 0,
    authority = false,
    lost_frames = 0,
    leon_set = nil,          -- where we last put Leon
    mc_prev = nil, mc_cur = nil, mc_seq = nil, mc_arrival = nil, mc_interval = 0.05,
    target_frame = -1, target = nil,   -- where Leon goes this frame (computed once, used by every placement)
    physics_off = false,
    released = false,        -- RE4 has Leon (see minecraft_control.lua)
    sync_seq = 0,
    sync_target = nil,       -- Minecraft position we asked Minecraft's player to move to
    sync_frames = 0,
    f9_was = false,
}

local debug = { layer = "not calibrated", rays_ms = 0, status = "waiting for Minecraft", scanned = 0, enemies = 0 }

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function key_pressed(key, field)
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    down = ok and down == true
    local pressed = down and not state[field]
    state[field] = down
    return pressed
end

------------------------------------------------------------------------------
-- RE4 physics raycasts (same calls as REFramework's RE4 VR crosshair script)
------------------------------------------------------------------------------

local physics_td = sdk.find_type_definition("via.physics.System")
local cast_ray_method = physics_td and physics_td:get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
local ray_query = nil
local ray_result = nil
local terrain_layer = nil

local function make_ray_objects()
    if ray_query ~= nil then return true end
    local ok = pcall(function()
        ray_query = sdk.create_instance("via.physics.CastRayQuery")
        ray_result = sdk.create_instance("via.physics.CastRayResult")
        ray_query:add_ref()
        ray_result:add_ref()
    end)
    return ok and ray_query ~= nil and ray_result ~= nil
end

-- Nearest hit position between two points, or nil
local function cast_ray(from, to, layer)
    if cast_ray_method == nil or not make_ray_objects() then return nil end
    local ok, hit = pcall(function()
        ray_query:call("setRay(via.vec3, via.vec3)", from, to)
        ray_query:call("clearOptions")
        ray_query:call("enableAllHits")
        ray_query:call("enableNearSort")
        local filter = ray_query:call("get_FilterInfo")
        filter:call("set_Group", 0)
        filter:call("set_MaskBits", 0xFFFFFFFF & ~1)   -- everything except the player
        filter:call("set_Layer", layer)
        ray_query:call("set_FilterInfo", filter)
        cast_ray_method:call(sdk.get_native_singleton("via.physics.System"), ray_query, ray_result)
        if ray_result:call("get_NumContactPoints") > 0 then
            return ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Position")
        end
        return nil
    end)
    if ok then return hit end
    return nil
end

-- Finds the collision layer RE4 uses for its ground: the first layer whose ray finds the floor
-- right under Leon's feet. Layers with names like terrain/ground are tried first.
local function calibrate_layer(feet)
    local td = sdk.find_type_definition(sdk.game_namespace("CollisionUtil.Layer"))
    local candidates = {}
    if td ~= nil then
        for _, field in ipairs(td:get_fields()) do
            if field:is_static() then
                local ok, value = pcall(function() return field:get_data(nil) end)
                if ok and type(value) == "number" then
                    table.insert(candidates, { name = field:get_name(), value = value })
                end
            end
        end
    end
    if #candidates == 0 then
        for v = 0, 31 do table.insert(candidates, { name = tostring(v), value = v }) end
    end
    local function rank(c)
        local n = c.name:lower()
        if n:find("terrain") or n:find("ground") or n:find("stage") or n:find("floor") then return 0 end
        if n:find("move") or n:find("character") or n:find("player") or n:find("static") then return 1 end
        return 2
    end
    table.sort(candidates, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.value < b.value
    end)
    for _, c in ipairs(candidates) do
        local hit = cast_ray(feet + Vector3f.new(0, 1.5, 0), feet - Vector3f.new(0, 1.0, 0), c.value)
        if hit ~= nil and math.abs(hit.y - feet.y) < 0.4 then
            debug.layer = c.name .. " (" .. tostring(c.value) .. ")"
            return c.value
        end
    end
    debug.layer = "no layer found the floor under Leon"
    return nil
end

------------------------------------------------------------------------------
-- Leon
------------------------------------------------------------------------------

local adsorber_type = sdk.typeof("chainsaw.GroundAdsorber")
local controller_type = sdk.typeof("via.physics.CharacterController")

local function get_leon()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local ctx = cm and try_call(cm, "getPlayerContextRef")
    local body = ctx and try_call(ctx, "get_BodyGameObject")
    if body == nil then return nil end
    return {
        transform = try_call(body, "get_Transform"),
        adsorber = try_call(body, "getComponent(System.Type)", adsorber_type),
        controller = try_call(body, "getComponent(System.Type)", controller_type),
    }
end

-- While Minecraft moves Leon, RE4's own collision and gravity for him are off so nothing fights it
local function set_re4_physics(leon, on)
    if leon == nil or state.physics_off == not on then return end
    if leon.controller ~= nil then try_call(leon.controller, "set_Enabled", on) end
    if leon.adsorber ~= nil then
        try_call(leon.adsorber, "set_EnabledGravity", on)
        try_call(leon.adsorber, "set_EnabledCheckGround", on)
    end
    state.physics_off = not on
end

------------------------------------------------------------------------------
-- Scanning
------------------------------------------------------------------------------

local function build_spiral()
    state.spiral = {}
    local r = math.ceil(settings.radius / settings.cell)
    for i = -r, r do
        for k = -r, r do
            local d = math.sqrt(i * i + k * k) * settings.cell
            if d <= settings.radius then table.insert(state.spiral, { i = i, k = k, d = d }) end
        end
    end
    table.sort(state.spiral, function(a, b) return a.d < b.d end)
end

local function cell_key(i, k) return i .. "," .. k end

-- Scans one cell: floor height, and walls toward its +x and +z neighbors
local function scan_cell(i, k, ref_y)
    local a = state.anchor_re4
    local cs = settings.cell
    local cx, cz = a.x + (i + 0.5) * cs, a.z + (k + 0.5) * cs
    local hit = cast_ray(Vector3f.new(cx, ref_y + RAY_ABOVE, cz), Vector3f.new(cx, ref_y - RAY_BELOW, cz), terrain_layer)
    local cell = { h = false, flags = 0, t = state.time, ref = ref_y }
    if hit ~= nil then
        cell.h = hit.y - a.y
        local wy = hit.y + WALL_RAY_HEIGHT
        if cast_ray(Vector3f.new(cx, wy, cz), Vector3f.new(cx + cs, wy, cz), terrain_layer) ~= nil then
            cell.flags = cell.flags | 1
        end
        if cast_ray(Vector3f.new(cx, wy, cz), Vector3f.new(cx, wy, cz + cs), terrain_layer) ~= nil then
            cell.flags = cell.flags | 2
        end
    end
    state.cells[cell_key(i, k)] = cell
end

local function update_scan(leon_pos)
    if state.center == nil or (leon_pos - state.center):length() > RECENTER_DISTANCE then
        -- The cells already scanned stay valid: around the new center, everything within the old covered
        -- radius minus the distance moved is still covered (resetting it to 0 made Minecraft hold the player
        -- still until the scan caught up: getting stuck while walking)
        local moved = state.center and (leon_pos - state.center):length() or math.huge
        state.done_radius = math.max(0, state.done_radius - moved - settings.cell)
        state.center = Vector3f.new(leon_pos.x, leon_pos.y, leon_pos.z)
        state.cursor = 1
    end
    local a = state.anchor_re4
    local ci = math.floor((state.center.x - a.x) / settings.cell)
    local ck = math.floor((state.center.z - a.z) / settings.cell)
    -- Little ground known around Leon (just arrived, fast running): scan the near cells first and faster
    local budget = settings.cells_per_frame * (state.done_radius < 5 and 3 or 1)
    local start = os.clock()
    local scanned = 0
    -- Look at each spiral entry at most once per frame; already fresh cells cost nothing
    for _ = 1, #state.spiral do
        if budget <= 0 then break end
        if state.cursor > #state.spiral then
            state.cursor = 1   -- full circle done; keep refreshing old cells
            state.done_radius = settings.radius
        end
        local s = state.spiral[state.cursor]
        local i, k = ci + s.i, ck + s.k
        local cell = state.cells[cell_key(i, k)]
        -- "No floor" depends on where the ray started; after Leon went up or down, look again
        local stale_miss = cell ~= nil and cell.h == false and math.abs(cell.ref - state.center.y) > 0.5
        if cell == nil or stale_miss or state.time - cell.t > REFRESH_SECONDS then
            scan_cell(i, k, state.center.y)
            budget = budget - 1
            scanned = scanned + 1
        end
        if state.done_radius < settings.radius then state.done_radius = s.d end
        state.cursor = state.cursor + 1
    end
    debug.rays_ms = (os.clock() - start) * 1000
    debug.scanned = scanned
end

-- Alive by the game's own flags (an enemy can be at 0 HP and still standing); HP > 0 only as a last resort
local function enemy_alive(hp)
    if hp == nil then return false end
    local live = try_call(hp, "get_IsLive")
    if live ~= nil then return live == true end
    local dead = try_call(hp, "get_IsDead")
    if dead ~= nil then return dead ~= true end
    return (try_call(hp, "get_CurrentHitPoint") or 0) > 0
end

-- RE4's living enemies near Leon in Minecraft coordinates: "key,x,y,z;..." (key = the enemy's address,
-- the same key minecraft_gameplay.lua uses to apply the damage Minecraft reports back)
local function enemies_for_minecraft(leon_pos)
    local a, m = state.anchor_re4, state.anchor_mc
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and try_call(cm, "get_EnemyContextList")
    local count = list and try_call(list, "get_Count") or 0
    local parts = {}
    for i = 0, count - 1 do
        local enemy = try_call(list, "get_Item", i)
        local pos = enemy and try_call(enemy, "get_Position")
        local hp = enemy and try_call(enemy, "get_HitPoint")
        if pos ~= nil and enemy_alive(hp) and (pos - leon_pos):length() <= ENEMY_RANGE then
            local ok, address = pcall(function() return enemy:get_address() end)
            if ok and address ~= nil then
                parts[#parts + 1] = string.format("%s,%.2f,%.2f,%.2f", tostring(address),
                    m.x + (pos.x - a.x), m.y + (pos.y - a.y), m.z + (pos.z - a.z))
            end
        end
    end
    debug.enemies = #parts
    return table.concat(parts, ";")
end

local function write_terrain(leon_pos)
    state.seq = state.seq + 1
    local data = {
        seq = state.seq,
        request_epoch = state.request_epoch,
        epoch = state.epoch,
        cell = settings.cell,
    }
    if state.sync_target ~= nil then
        local t = state.sync_target
        data.sync = { seq = state.sync_seq, x = t.x, y = t.y, z = t.z }
    end
    if state.epoch ~= 0 and state.anchor_re4 ~= nil and state.center ~= nil then
        local a = state.anchor_re4
        local parts = {}
        local ci = math.floor((state.center.x - a.x) / settings.cell)
        local ck = math.floor((state.center.z - a.z) / settings.cell)
        for _, s in ipairs(state.spiral) do
            if s.d > state.done_radius then break end
            local i, k = ci + s.i, ck + s.k
            local cell = state.cells[cell_key(i, k)]
            if cell ~= nil then
                local h = cell.h == false and "x" or string.format("%.2f", cell.h)
                parts[#parts + 1] = i .. "," .. k .. "," .. h .. "," .. cell.flags
            end
        end
        data.anchor_re4 = { x = a.x, y = a.y, z = a.z }
        data.center = { x = state.center.x, y = state.center.y, z = state.center.z }
        data.radius = math.max(0.1, state.done_radius)
        data.cells = table.concat(parts, ";")
        if state.anchor_mc ~= nil then data.enemies = enemies_for_minecraft(leon_pos) end
    end
    pcall(json.dump_file, TERRAIN_FILE, data)
end

------------------------------------------------------------------------------
-- Anchor and following Minecraft
------------------------------------------------------------------------------

local function request_anchor(reason)
    state.request_epoch = state.request_epoch + 1
    state.epoch = 0
    state.anchor_re4 = nil
    state.anchor_mc = nil
    state.cells = {}
    state.center = nil
    state.authority = false
    state.lost_frames = 0
    debug.status = "asking Minecraft for a new anchor (" .. reason .. ")"
end

local bridge = nil   -- Minecraft's latest state (minecraft_bridge.json)

-- Who has Leon right now (minecraft_control.lua); without that script Minecraft always has him
local function control_mode()
    local c = MinecraftRE4Control
    if type(c) ~= "table" then return "minecraft", "" end
    return c.mode, c.reason
end

-- Move Minecraft's player to Leon's spot, keeping the anchor (and so the blocks you built)
local function request_sync(pos, reason)
    if state.epoch == 0 or state.anchor_re4 == nil then return end
    local a, m = state.anchor_re4, state.anchor_mc
    local target = Vector3f.new(m.x + (pos.x - a.x), m.y + (pos.y - a.y), m.z + (pos.z - a.z))
    local far = math.abs(target.x - m.x) > FAR_FROM_ANCHOR or math.abs(target.z - m.z) > FAR_FROM_ANCHOR
    if far or math.abs(target.y - m.y) >= FAR_ABOVE_BELOW then
        request_anchor(reason .. ", far from the anchor")
        return
    end
    -- Never reuse a number Minecraft already did (this script may have been reset, Minecraft not)
    local done = bridge and tonumber(bridge.sync_done) or 0
    state.sync_seq = math.max(state.sync_seq, done) + 1
    state.sync_target = target
    state.sync_frames = 0
    state.authority = false
    state.mc_prev, state.mc_cur, state.mc_seq, state.mc_shown = nil, nil, nil, nil
    debug.status = "moving Minecraft's player to Leon (" .. reason .. ")"
end

local function read_bridge()
    local ok, d = pcall(json.load_file, BRIDGE_FILE)
    bridge = (ok and type(d) == "table" and d.in_world) and d or nil
end

-- Real time in seconds: the game's own clock (via.Application uptime), else os.clock
local uptime_method = nil
pcall(function() uptime_method = sdk.find_type_definition("via.Application"):get_method("get_UpTimeSecond") end)
local function now_seconds()
    local app = sdk.get_native_singleton("via.Application")
    if uptime_method ~= nil and app ~= nil then
        local ok, t = pcall(function() return uptime_method:call(app) end)
        if ok and type(t) == "number" then return t end
    end
    return os.clock()
end

-- Minecraft's player position mapped into RE4, smoothed between Minecraft's 20 updates per second
local function minecraft_leon_position()
    if bridge == nil or type(bridge.pos) ~= "table" or state.anchor_mc == nil then return nil end
    local p = bridge.pos
    local now = now_seconds()
    if bridge.seq ~= state.mc_seq then
        -- How often Minecraft's position arrives (20 times a second, give or take), smoothed
        if state.mc_arrival ~= nil then
            local gap = now - state.mc_arrival
            if gap > 0.02 and gap < 0.2 then state.mc_interval = state.mc_interval * 0.8 + gap * 0.2 end
        end
        -- Count the glide from the previous frame, so this frame already moves on
        state.mc_arrival = state.mc_last_now or now
        state.mc_seq = bridge.seq
        -- Glide on from where Leon is shown now (an early update must not make him jump)
        state.mc_prev = state.mc_shown or state.mc_cur or Vector3f.new(p.x, p.y, p.z)
        state.mc_cur = Vector3f.new(p.x, p.y, p.z)
    end
    -- Glide from the previous position to the newest one over one update, by real time: smooth at any frame
    -- rate (counting frames made Leon stop and go above 60 FPS)
    local t = math.max(0, math.min(1, (now - (state.mc_arrival or now)) / state.mc_interval))
    local mc = state.mc_prev + (state.mc_cur - state.mc_prev) * t
    state.mc_shown = mc
    state.mc_last_now = now
    local a, m = state.anchor_re4, state.anchor_mc
    return Vector3f.new(a.x + (mc.x - m.x), a.y + (mc.y - m.y), a.z + (mc.z - m.z))
end

local function controlling()
    return settings.enabled and bridge ~= nil and bridge.re4_control == true
end

------------------------------------------------------------------------------
-- Frame updates
------------------------------------------------------------------------------

-- Start of the frame: notice when the game itself moved Leon (doors, cutscenes, loading)
re.on_pre_application_entry("UpdateBehavior", function()
    state.frame = state.frame + 1
    state.time = state.time + 1 / 60
    read_bridge()
    local f9 = key_pressed(0x78, "f9_was")

    local leon = get_leon()
    local pos = leon and leon.transform and try_call(leon.transform, "get_Position")
    if pos == nil then
        state.leon_set = nil
        return
    end
    if not controlling() then
        set_re4_physics(leon, true)
        debug.status = bridge == nil and "waiting for Minecraft" or "Minecraft isn't getting RE4's keys"
        return
    end

    -- RE4's turn (ladder, door, cutscene, grab, menu, F7): RE4 moves Leon; keep scanning around him
    local mode, reason = control_mode()
    if mode ~= "minecraft" then
        if not state.released then
            state.released = true
            set_re4_physics(leon, true)
        end
        state.leon_set = nil
        state.sync_target = nil
        debug.status = "RE4 has Leon (" .. tostring(reason) .. ")"
    elseif state.released then
        state.released = false
        request_sync(pos, "RE4 gave Leon back")
    end

    if state.leon_set ~= nil and (pos - state.leon_set):length() > TELEPORT_DISTANCE then
        request_sync(pos, "the game moved Leon")
    elseif f9 then
        request_anchor("F9")
    elseif state.request_epoch == 0 then
        request_anchor("Minecraft connected")
    end
    state.leon_set = nil

    -- Minecraft moved its player to Leon: follow it again
    if state.sync_target ~= nil then
        state.sync_frames = state.sync_frames + 1
        if bridge.sync_done == state.sync_seq then
            state.sync_target = nil
            state.mc_prev, state.mc_cur, state.mc_seq, state.mc_shown = nil, nil, nil, nil
        elseif state.sync_frames > SYNC_TIMEOUT_FRAMES then
            request_anchor("Minecraft didn't move its player")
            state.sync_target = nil
        end
    end

    -- Minecraft made the anchor we asked for: Leon's current spot is its match
    if state.epoch == 0 and type(bridge.anchor) == "table" and bridge.anchor.epoch == state.request_epoch then
        state.epoch = state.request_epoch
        state.anchor_re4 = Vector3f.new(pos.x, pos.y, pos.z)
        state.anchor_mc = Vector3f.new(bridge.anchor.x, bridge.anchor.y, bridge.anchor.z)
        state.mc_prev, state.mc_cur, state.mc_seq, state.mc_shown = nil, nil, nil, nil
        build_spiral()
        debug.status = "anchored, scanning RE4's terrain"
    end

    if state.epoch ~= 0 then
        if terrain_layer == nil then terrain_layer = calibrate_layer(pos) end
        if terrain_layer ~= nil then update_scan(pos) end
    end

    state.authority = state.epoch ~= 0 and bridge.authority == true and bridge.anchor ~= nil
        and bridge.anchor.epoch == state.epoch and state.sync_target == nil and not state.released
    if state.epoch ~= 0 and not state.authority and not state.released and state.sync_target == nil then
        state.lost_frames = state.lost_frames + 1
        if state.lost_frames > LOST_FRAMES and (bridge.terrain_boxes or 0) > 0 then
            request_sync(pos, "Minecraft's player lost the terrain")
            state.lost_frames = 0
        end
    else
        state.lost_frames = 0
    end

    if state.frame % WRITE_EVERY_FRAMES == 0 then write_terrain(pos) end
end)

-- Leon faces where you look, so RE4's "interact" (F: ladders, doors, items) works on what you look at
local function face_camera_direction(leon)
    local camera = sdk.get_primary_camera()
    local ok, forward = pcall(function()
        return camera:call("get_GameObject"):call("get_Transform"):call("get_Rotation") * Vector3f.new(0, 0, -1)
    end)
    if not ok or forward == nil or (forward.x == 0 and forward.z == 0) then return end
    local half = math.atan(forward.x, forward.z) * 0.5   -- Leon's model looks along its +Z
    local ok_q, rot = pcall(function() return Quaternion.new(math.cos(half), 0, math.sin(half), 0) end)
    if ok_q and rot ~= nil then try_call(leon.transform, "set_Rotation", rot) end
end

-- After RE4's own update: put Leon where Minecraft's player is
local function place_leon()
    if not (controlling() and state.authority) then
        if not controlling() then return end
        local leon = get_leon()
        set_re4_physics(leon, true)
        return
    end
    local leon = get_leon()
    -- One spot per frame for Leon and the camera (minecraft_first_person.lua reads it), so they never
    -- disagree within a frame
    if state.target_frame ~= state.frame then
        state.target = minecraft_leon_position()
        state.target_frame = state.frame
        local c = MinecraftRE4Control
        if type(c) == "table" then
            c.leon_feet = state.target
            c.leon_feet_frame = c.frame
        end
    end
    local target = state.target
    if leon == nil or leon.transform == nil or target == nil then return end
    set_re4_physics(leon, false)
    try_call(leon.transform, "set_Position", target)
    face_camera_direction(leon)
    state.leon_set = target
    debug.status = "Minecraft physics on RE4 terrain"
end

re.on_application_entry("LateUpdateBehavior", place_leon)
re.on_pre_application_entry("LockScene", place_leon)

------------------------------------------------------------------------------

-- Optional: show the scanned grid (green floor points, red walls)
re.on_frame(function()
    if not settings.show_grid or state.anchor_re4 == nil then return end
    local a = state.anchor_re4
    local cs = settings.cell
    for key, cell in pairs(state.cells) do
        if cell.h ~= false then
            local i, k = key:match("^(-?%d+),(-?%d+)$")
            local p = Vector3f.new(a.x + (tonumber(i) + 0.5) * cs, a.y + cell.h + 0.02, a.z + (tonumber(k) + 0.5) * cs)
            local ok, s = pcall(draw.world_to_screen, p)
            if ok and s ~= nil then
                draw.filled_rect(s.x - 2, s.y - 2, 4, 4, cell.flags ~= 0 and 0xFF2020FF or 0xFF20FF20)
            end
        end
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Terrain") then
        local changed
        changed, settings.enabled = imgui.checkbox("Minecraft physics on RE4 terrain", settings.enabled)
        changed, settings.cells_per_frame = imgui.slider_int("Cells scanned per frame", settings.cells_per_frame, 10, 200)
        changed, settings.show_grid = imgui.checkbox("Show scanned grid", settings.show_grid)
        imgui.text("Status: " .. debug.status)
        imgui.text("F7 = everything to RE4 / back to Minecraft,  F9 = re-anchor here")
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Ground layer: " .. debug.layer)
            imgui.text(string.format("Anchor epoch %d (asked %d), scanned radius %.1f m", state.epoch, state.request_epoch, state.done_radius))
            imgui.text(string.format("This frame: %d cells, %.2f ms", debug.scanned, debug.rays_ms))
            imgui.text(string.format("RE4 enemies sent to Minecraft: %d", debug.enemies))
            if bridge ~= nil then
                imgui.text(string.format("Minecraft: authority %s, %s terrain boxes", tostring(bridge.authority), tostring(bridge.terrain_boxes)))
            end
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    set_re4_physics(get_leon(), true)
end)
