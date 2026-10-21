-- Minecraft First Person for RE4 Remake (REFramework Lua script)
-- Minecraft's first-person camera for Leon: a steady eye height above his feet (1.62 m, 1.27 m when
-- sneaking), turned only by the mouse with Minecraft's sensitivity formula (needs the overlay plugin,
-- which reads the raw mouse; without it RE4's own camera rotation is used). Also draws a "+" crosshair
-- when Minecraft isn't drawing its own.
-- F5 works like Minecraft's F5 while Minecraft is connected: first person -> behind -> in front, and
-- the third-person views show your Minecraft character (drawn by Minecraft) instead of Leon. RE4's
-- camera is put exactly where Minecraft's camera is, with Minecraft's field of view, so they line up.
-- Without Minecraft, F5 switches between first person and the normal RE4 camera.
-- During RE4's turn (cutscenes, grabs, menus, F7: see minecraft_control.lua) RE4's own camera is used and
-- Leon is shown.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft First Person

local settings = {
    first_person = true,
    minecraft_camera = true,   -- eye height above the feet + mouse look; off = follow the head bone
    eye_height = 1.62,         -- Minecraft's eye height in blocks (= meters)
    sneak_eye_height = 1.27,
    forward_offset = 0.10,  -- meters in front of the eye/head position
    up_offset = 0.05,       -- only for the head bone camera
    hide_head = true,       -- hides all of Leon (body, separate head, hair, weapons): like Minecraft, you only see its hand
    crosshair = true,
    minecraft_fov = true,   -- use Minecraft's field of view (and its sprint zoom) for RE4's camera
    stage = 1,              -- index into STAGES
    show_debug = false,
}

local KEY_F5 = 0x74

-- Points in the game's frame where we move the camera. The game captures the
-- camera for drawing around LockScene, so we have to move it before that.
local STAGES = { "All", "LateUpdateBehavior", "PrepareRendering", "BeforeLockSceneRendering", "LockScene" }

local HEAD_JOINT_NAMES = { "head", "Head", "head_0", "neck_1", "neck_0", "Neck" }
local PLAYER_OBJECT_METHODS = { "get_BodyGameObject", "get_GameObject", "get_PlayerGameObject" }
local HEAD_PART_PATTERNS = { "head", "hair", "face", "eye", "lash", "teeth", "tongue" }

local debug = {
    player = "not checked yet",
    head = "not checked yet",
    camera = "not checked yet",
    last_stage = "none",
    joints = "",
    parts = "",
    look = "not started",
    fov = "RE4's own",
}

local head_joint = nil
local head_joint_owner = nil
local head_hidden = false
local hidden_renderers = {}     -- address -> component we switched off to hide Leon
local f5_was_down = false

local mesh_type = sdk.typeof("via.render.Mesh")

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function get_player_object()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if cm == nil then
        debug.player = "CharacterManager not found"
        return nil
    end

    local ctx = try_call(cm, "getPlayerContextRef")
    if ctx == nil then
        debug.player = "player context not found (in a menu?)"
        return nil
    end

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

local function find_head_joint(transform)
    for _, name in ipairs(HEAD_JOINT_NAMES) do
        local joint = try_call(transform, "getJointByName", name)
        if joint ~= nil then
            debug.head = "joint '" .. name .. "'"
            return joint
        end
    end
    debug.head = "no head joint found (use 'List joints')"
    return nil
end

local function get_head_joint()
    local player = get_player_object()
    if player == nil then return nil end

    local transform = try_call(player, "get_Transform")
    if transform == nil then
        debug.head = "player has no Transform"
        return nil
    end

    -- Leon's object can change (e.g. after a level load), so look the joint up again when it does
    if head_joint == nil or head_joint_owner ~= transform then
        head_joint = find_head_joint(transform)
        head_joint_owner = transform
        head_hidden = false
        hidden_renderers = {}
    end
    return head_joint, transform
end

-- Calls fn(game_object, name, depth) for every child object under transform
local function for_each_child(transform, fn, depth)
    depth = depth or 1
    if depth > 6 then return end
    local child = try_call(transform, "get_Child")
    while child ~= nil do
        local go = try_call(child, "get_GameObject")
        local name = go and try_call(go, "get_Name") or "?"
        fn(go, name, depth)
        for_each_child(child, fn, depth + 1)
        child = try_call(child, "get_Next")
    end
end

local function is_head_part(name)
    local lower = name:lower()
    for _, pattern in ipairs(HEAD_PART_PATTERNS) do
        if lower:find(pattern) then return true end
    end
    return false
end

-- Hides all of Leon in first person by switching off every mesh/hair renderer on his body, his
-- separate head object (hair, face) and everything attached to them (weapons, gear).
-- (Shrinking the head joint to ~0 was removed: it can hang the GPU.)
local last_hide_scan = -1000
local hide_frame = 0

local function is_renderer(component)
    local ok, name = pcall(function() return component:get_type_definition():get_full_name() end)
    if not ok or name == nil or name:sub(1, 11) ~= "via.render." then return false end
    return name:find("Mesh") ~= nil or name:find("Hair") ~= nil or name:find("Strand") ~= nil
end

local function hide_renderers_of(go)
    local components = try_call(go, "get_Components")
    local ok, list = pcall(function() return components:get_elements() end)
    if not ok or list == nil then return end
    for _, component in ipairs(list) do
        if is_renderer(component) then
            local ok_addr, address = pcall(function() return component:get_address() end)
            local key = ok_addr and address or tostring(component)
            -- Also when the game switched it back on (cutscenes show and hide Leon's parts themselves)
            if hidden_renderers[key] == nil or try_call(component, "get_Enabled") == true then
                try_call(component, "set_Enabled", false)
                hidden_renderers[key] = component
            end
        end
    end
end

local function leon_objects()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local ctx = cm and try_call(cm, "getPlayerContextRef")
    if ctx == nil then return {} end
    local objects = {}
    for _, method in ipairs({ "get_BodyGameObject", "get_HeadGameObject" }) do
        local go = try_call(ctx, method)
        if go ~= nil then table.insert(objects, go) end
    end
    return objects
end

-- Your Minecraft character plays Leon in this cutscene (minecraft_cutscenes.lua): keep Leon hidden
local function puppet_on()
    local c = MinecraftRE4Control
    return type(c) == "table" and c.puppet == true
end

local function set_head_hidden(hidden, transform)
    hide_frame = hide_frame + 1
    if hidden then
        -- Rescan now and then: weapons and gear get attached and swapped during play
        if not head_hidden or hide_frame - last_hide_scan >= (puppet_on() and 10 or 120) then
            last_hide_scan = hide_frame
            for _, go in ipairs(leon_objects()) do
                hide_renderers_of(go)
                local t = try_call(go, "get_Transform")
                if t ~= nil then
                    for_each_child(t, function(child) if child ~= nil then hide_renderers_of(child) end end)
                end
            end
        end
    elseif head_hidden then
        for _, component in pairs(hidden_renderers) do
            try_call(component, "set_Enabled", true)
        end
        hidden_renderers = {}
    end
    head_hidden = hidden
end

-- Collects head/neck joint names so we can pick the right one if the defaults don't match
local function list_joints()
    local _, transform = get_head_joint()
    if transform == nil then
        debug.joints = "player not found"
        return
    end
    local joints = try_call(transform, "get_Joints")
    if joints == nil then
        debug.joints = "could not read joints"
        return
    end
    local names = {}
    for _, joint in ipairs(joints:get_elements()) do
        local name = try_call(joint, "get_Name")
        if name ~= nil and (name:lower():find("head") or name:lower():find("neck")) then
            table.insert(names, name)
        end
    end
    debug.joints = #names > 0 and table.concat(names, ", ") or "no head/neck joints"
end

-- Lists Leon's child objects (body parts, weapons...) so we can see which ones are the head
local function list_parts()
    local _, transform = get_head_joint()
    if transform == nil then
        debug.parts = "player not found"
        return
    end
    local names = {}
    for_each_child(transform, function(_, name, depth)
        table.insert(names, string.rep("  ", depth - 1) .. name)
    end)
    debug.parts = #names > 0 and table.concat(names, "\n") or "no child objects"
end

------------------------------------------------------------------------------
-- Minecraft mouse look (raw mouse from the overlay plugin) and eye height
------------------------------------------------------------------------------

local MOUSE_FILE = "minecraft_mouse.json"
local mouse = { x = nil, y = nil, frame = nil, alive_until = -1 }
local look = { yaw = nil, pitch = nil }   -- radians; yaw 0 = looking down -Z, pitch > 0 = looking up
local frame_counter = 0
local eye = nil
local bridge_settings = { sensitivity = 0.5, invert = false, sneaking = false }

-- Minecraft's camera (from minecraft_bridge.json): 0 = first person, 1 = behind, 2 = in front
local mc_camera = { mode = 0, distance = 0, fov = nil }
local bridge_seq, bridge_live_until = nil, -1
local re4_fov = nil   -- RE4's own camera settings, put back when Minecraft's FOV is no longer used

local function read_bridge()
    local ok, b = pcall(json.load_file, "minecraft_bridge.json")
    if not ok or type(b) ~= "table" then return end
    if type(b.sensitivity) == "number" then bridge_settings.sensitivity = b.sensitivity end
    bridge_settings.invert = b.invert_mouse == true
    if b.seq ~= bridge_seq then
        bridge_seq = b.seq
        if b.re4_control == true and b.in_world == true then bridge_live_until = frame_counter + 120 end
    end
    local c = b.camera
    if type(c) == "table" then
        mc_camera.mode = tonumber(c.mode) or 0
        mc_camera.distance = tonumber(c.distance) or 0
        mc_camera.fov = tonumber(c.fov)
    end
end

-- RE4's turn (minecraft_control.lua): hands off the camera, Leon shown
local function re4_turn()
    local c = MinecraftRE4Control
    return type(c) == "table" and c.mode == "re4"
end


-- Minecraft is running and takes RE4's input (so it also follows F5)
local function minecraft_live()
    return frame_counter <= bridge_live_until
end

local function minecraft_view_mode()
    if minecraft_live() and settings.minecraft_camera then return mc_camera.mode end
    return 0
end

local function update_toggle_key()
    frame_counter = frame_counter + 1
    if frame_counter % 2 == 0 then read_bridge() end
    local ok, down = pcall(function() return reframework:is_key_down(KEY_F5) end)
    if not ok then return end
    -- While Minecraft is connected, the HUD script passes F5 on to Minecraft, which switches its camera
    if down and not f5_was_down and not minecraft_live() then
        settings.first_person = not settings.first_person
    end
    f5_was_down = down
end

local function key_is_down(key)
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    return ok and down == true
end

-- Degrees per mouse count, exactly like Minecraft: (sensitivity * 0.6 + 0.2)^3 * 8 * 0.15
local function degrees_per_count()
    local f = bridge_settings.sensitivity * 0.6 + 0.2
    return f * f * f * 8 * 0.15
end

local function read_mouse()
    local ok, m = pcall(json.load_file, MOUSE_FILE)
    if not ok or type(m) ~= "table" or m.frame == nil then return 0, 0 end
    if m.frame == mouse.frame then return 0, 0 end
    mouse.frame = m.frame
    mouse.alive_until = frame_counter + 30
    if mouse.x == nil then
        mouse.x, mouse.y = m.x, m.y
        return 0, 0
    end
    local dx, dy = m.x - mouse.x, m.y - mouse.y
    mouse.x, mouse.y = m.x, m.y
    return dx, dy
end

local function look_from_rotation(rot)
    local ok, f = pcall(function() return rot * Vector3f.new(0, 0, -1) end)
    if not ok or f == nil then return end
    look.yaw = math.atan(-f.x, -f.z)
    look.pitch = math.asin(math.max(-1, math.min(1, f.y)))
end

local function rotation_from_look(yaw, pitch)
    local ok, q = pcall(function()
        local y, p = (yaw or look.yaw) * 0.5, (pitch or look.pitch) * 0.5
        return Quaternion.new(math.cos(y), 0, math.sin(y), 0) * Quaternion.new(math.cos(p), math.sin(p), 0, 0)
    end)
    if ok then return q end
    return nil
end

-- Once per frame: turn by the mouse, ease the eye height between standing and sneaking
local function update_look(cam_transform)
    local dx, dy = read_mouse()
    local rot = try_call(cam_transform, "get_Rotation")
    -- A Minecraft screen is open (inventory, chat): the mouse moves its cursor, not the camera
    local c = MinecraftRE4Control
    if type(c) == "table" and c.minecraft_screen then dx, dy = 0, 0 end
    if re4_turn() then
        -- RE4 turns its camera; carry on from where it looks when Minecraft takes over again
        if rot ~= nil then look_from_rotation(rot) end
        debug.look = "RE4's camera (RE4's turn)"
    elseif look.yaw == nil or frame_counter > mouse.alive_until then
        -- No raw mouse (plugin missing) or just started: follow RE4's camera
        if rot ~= nil then look_from_rotation(rot) end
        debug.look = "RE4 camera rotation (no raw mouse)"
    else
        if bridge_settings.invert then dy = -dy end
        local k = math.rad(degrees_per_count())
        look.yaw = look.yaw - dx * k
        look.pitch = math.max(math.rad(-90), math.min(math.rad(90), look.pitch - dy * k))
        debug.look = string.format("Minecraft mouse look (%.3f deg/count)", degrees_per_count())
    end

    -- The look direction for Minecraft (yaw/pitch in Minecraft's degrees), also right in the third-person
    -- views where the camera looks elsewhere (minecraft_bridge_hud.lua sends it)
    local c = MinecraftRE4Control
    if type(c) == "table" and look.yaw ~= nil then
        c.look = { yaw = math.deg(math.pi - look.yaw), pitch = -math.deg(look.pitch), at = os.clock() }
    end

    local target = key_is_down(0x10) and settings.sneak_eye_height or settings.eye_height
    eye = eye and (eye + (target - eye) * 0.35) or target
end

-- Minecraft's FOV is vertical; RE4's camera is told to read it that way too
local function apply_fov(camera, allowed)
    local use = allowed and settings.minecraft_fov and settings.minecraft_camera and minecraft_live() and mc_camera.fov ~= nil
    if use then
        if re4_fov == nil then
            re4_fov = { fov = try_call(camera, "get_FOV"), vertical = try_call(camera, "get_VerticalEnable") }
        end
        try_call(camera, "set_VerticalEnable", true)
        try_call(camera, "set_FOV", mc_camera.fov)
        debug.fov = string.format("Minecraft %.1f (vertical)", mc_camera.fov)
    elseif re4_fov ~= nil then
        if re4_fov.vertical ~= nil then try_call(camera, "set_VerticalEnable", re4_fov.vertical) end
        if re4_fov.fov ~= nil then try_call(camera, "set_FOV", re4_fov.fov) end
        re4_fov = nil
        debug.fov = "RE4's own"
    end
end

local minecraft_crosshair = false   -- = Minecraft's picture is shown over RE4 (see update_overlay_state)
local function minecraft_picture_shown() return minecraft_crosshair end

local function update_camera(stage)
    local joint, transform = get_head_joint()
    if joint == nil then return end

    -- Only change meshes during the game update, never while a frame is being prepared for drawing
    if stage == "LateUpdateBehavior" then
        local third = minecraft_view_mode() ~= 0
        set_head_hidden(puppet_on() or (settings.first_person and settings.hide_head and not re4_turn()
            and not (third and not minecraft_picture_shown())), transform)
    end

    local selected = STAGES[settings.stage]
    if selected ~= "All" and selected ~= stage then return end
    if not settings.first_person then return end

    local camera = sdk.get_primary_camera()
    local cam_obj = camera and try_call(camera, "get_GameObject")
    local cam_transform = cam_obj and try_call(cam_obj, "get_Transform")
    if cam_transform == nil then
        debug.camera = "camera not found"
        return
    end
    if re4_turn() then
        apply_fov(camera, false)
        debug.camera = "RE4's camera (RE4's turn)"
        return
    end

    local new_pos
    local rot
    if settings.minecraft_camera then
        -- Minecraft camera: steady eye height above Leon's feet, turned only by the mouse
        if eye == nil then update_look(cam_transform) end
        local feet = transform and try_call(transform, "get_Position")
        if feet == nil then
            debug.camera = "could not read Leon's position"
            return
        end
        local yaw, pitch = look.yaw or 0, look.pitch or 0
        local eye_pos = feet + Vector3f.new(0, eye, 0)
        local mode = minecraft_view_mode()
        if mode == 1 or mode == 2 then
            -- Minecraft's third person: the camera backs away from the eyes (behind, or in front looking back)
            local forward = Vector3f.new(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch))
            if mode == 1 then
                rot = rotation_from_look()
                new_pos = eye_pos - forward * mc_camera.distance
            else
                rot = rotation_from_look(yaw + math.pi, -pitch)
                new_pos = eye_pos + forward * mc_camera.distance
            end
        else
            rot = rotation_from_look()
            local flat_forward = Vector3f.new(-math.sin(yaw), 0, -math.cos(yaw))
            new_pos = eye_pos + flat_forward * settings.forward_offset
        end
        if rot ~= nil then try_call(cam_transform, "set_Rotation", rot) end
    else
        local pos = try_call(joint, "get_Position")
        if pos == nil then
            debug.camera = "could not read head position"
            return
        end
        -- Keep the game's camera rotation, only move the camera into the head
        new_pos = pos + Vector3f.new(0, settings.up_offset, 0)
        rot = try_call(cam_transform, "get_Rotation")
        if rot ~= nil then
            local ok, forward = pcall(function() return rot * Vector3f.new(0, 0, -1) end)
            if ok and forward ~= nil then
                new_pos = new_pos + forward * settings.forward_offset
            end
        end
    end

    try_call(cam_transform, "set_Position", new_pos)
    apply_fov(camera, true)
    debug.camera = "moved (camera: " .. tostring(try_call(cam_obj, "get_Name")) .. ")"
    debug.last_stage = stage
end

re.on_pre_application_entry("UpdateBehavior", update_toggle_key)

-- Mouse look and eye height advance once per frame, whichever camera timing is selected
re.on_application_entry("LateUpdateBehavior", function()
    if not (settings.first_person and settings.minecraft_camera) then
        look.yaw = nil
        return
    end
    local camera = sdk.get_primary_camera()
    local cam_obj = camera and try_call(camera, "get_GameObject")
    local cam_transform = cam_obj and try_call(cam_obj, "get_Transform")
    if cam_transform ~= nil then update_look(cam_transform) end
end)
re.on_application_entry("LateUpdateBehavior", function() update_camera("LateUpdateBehavior") end)
re.on_pre_application_entry("PrepareRendering", function() update_camera("PrepareRendering") end)
re.on_pre_application_entry("BeforeLockSceneRendering", function() update_camera("BeforeLockSceneRendering") end)
re.on_pre_application_entry("LockScene", function() update_camera("LockScene") end)

local function get_screen_size()
    local ok, size = pcall(imgui.get_display_size)
    if ok and size ~= nil and size.x > 0 then
        return size.x, size.y
    end
    return 1920, 1080
end

-- While the overlay plugin shows Minecraft's own rendering, Minecraft draws the real crosshair
local overlay_check_frame = 0
local overlay_beat, overlay_beat_frame = nil, -100000

local function update_overlay_state()
    overlay_check_frame = overlay_check_frame + 1
    if overlay_check_frame % 60 ~= 0 then return end
    local ok_b, bridge = pcall(json.load_file, "minecraft_bridge.json")
    local ok_p, plugin = pcall(json.load_file, "minecraft_overlay_plugin.json")
    if ok_p and type(plugin) == "table" and plugin.beat ~= overlay_beat then
        overlay_beat = plugin.beat
        overlay_beat_frame = overlay_check_frame
    end
    minecraft_crosshair = ok_b and type(bridge) == "table" and bridge.overlay == true
        and ok_p and type(plugin) == "table" and plugin.ready == true
        and overlay_check_frame - overlay_beat_frame < 240
end

-- Minecraft-style "+" crosshair
re.on_frame(function()
    update_overlay_state()
    if not (settings.crosshair and settings.first_person) then return end
    if head_joint == nil or minecraft_crosshair then return end

    local w, h = get_screen_size()
    local px = math.max(1, math.floor(h / 360))
    local cx, cy = math.floor(w / 2), math.floor(h / 2)
    local arm = 4 * px

    -- dark outline first, then white on top
    draw.filled_rect(cx - arm - 1, cy - px / 2 - 1, arm * 2 + 2, px + 2, 0x80000000)
    draw.filled_rect(cx - px / 2 - 1, cy - arm - 1, px + 2, arm * 2 + 2, 0x80000000)
    draw.filled_rect(cx - arm, cy - px / 2, arm * 2, px, 0xFFFFFFFF)
    draw.filled_rect(cx - px / 2, cy - arm, px, arm * 2, 0xFFFFFFFF)
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft First Person") then
        local changed
        changed, settings.first_person = imgui.checkbox("Minecraft camera on (F5 without Minecraft)", settings.first_person)
        changed, settings.minecraft_camera = imgui.checkbox("Minecraft camera (eye height + mouse look)", settings.minecraft_camera)
        changed, settings.eye_height = imgui.slider_float("Eye height", settings.eye_height, 1.2, 2.0)
        changed, settings.hide_head = imgui.checkbox("Hide Leon's body (first person)", settings.hide_head)
        changed, settings.crosshair = imgui.checkbox("Crosshair", settings.crosshair)
        changed, settings.minecraft_fov = imgui.checkbox("Minecraft's field of view", settings.minecraft_fov)
        changed, settings.forward_offset = imgui.slider_float("Forward offset", settings.forward_offset, -0.5, 0.5)
        changed, settings.up_offset = imgui.slider_float("Up offset", settings.up_offset, -0.3, 0.3)
        changed, settings.stage = imgui.combo("Camera timing", settings.stage, STAGES)
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Player: " .. debug.player)
            imgui.text("Head: " .. debug.head)
            imgui.text("Camera: " .. debug.camera)
            imgui.text("Look: " .. debug.look)
            imgui.text(string.format("Minecraft camera: %s, distance %.2f", ({ [0] = "first person", "behind", "in front" })[mc_camera.mode] or "?", mc_camera.distance))
            imgui.text("FOV: " .. debug.fov)
            imgui.text("Last timing used: " .. debug.last_stage)
            if imgui.button("List joints") then list_joints() end
            imgui.same_line()
            if imgui.button("List parts") then list_parts() end
            if debug.joints ~= "" then imgui.text("Joints: " .. debug.joints) end
            if debug.parts ~= "" then imgui.text("Parts:\n" .. debug.parts) end
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    set_head_hidden(false, head_joint_owner)
end)
