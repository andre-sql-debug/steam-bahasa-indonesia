-- Minecraft First Person for RE4 Remake (REFramework Lua script)
-- Moves the camera into Leon's head and draws Minecraft's "+" crosshair.
-- Press F5 to switch between first person and the normal RE4 camera.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft First Person

local settings = {
    first_person = true,
    forward_offset = 0.10,  -- meters in front of the head joint
    up_offset = 0.05,
    hide_head = false,      -- experimental, see set_head_hidden
    crosshair = true,
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
}

local head_joint = nil
local head_joint_owner = nil
local head_hidden = false
local hidden_meshes = {}
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
        hidden_meshes = {}
    end
    return head_joint, transform
end

-- Calls fn(game_object, name, depth) for every child object under transform
local function for_each_child(transform, fn, depth)
    depth = depth or 1
    if depth > 4 then return end
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

-- Hides the head by switching off head/hair/face meshes.
-- (Shrinking the head joint to ~0 was removed: it can hang the GPU.)
local function set_head_hidden(hidden, transform)
    if head_joint == nil or hidden == head_hidden then return end

    if hidden and transform ~= nil then
        for_each_child(transform, function(go, name)
            if go ~= nil and is_head_part(name) then
                local mesh = try_call(go, "getComponent(System.Type)", mesh_type)
                if mesh ~= nil then
                    try_call(mesh, "set_Enabled", false)
                    table.insert(hidden_meshes, mesh)
                end
            end
        end)
    elseif not hidden then
        for _, mesh in ipairs(hidden_meshes) do
            try_call(mesh, "set_Enabled", true)
        end
        hidden_meshes = {}
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

local function update_toggle_key()
    local ok, down = pcall(function() return reframework:is_key_down(KEY_F5) end)
    if not ok then return end
    if down and not f5_was_down then
        settings.first_person = not settings.first_person
    end
    f5_was_down = down
end

local function update_camera(stage)
    local joint, transform = get_head_joint()
    if joint == nil then return end

    -- Only change meshes during the game update, never while a frame is being prepared for drawing
    if stage == "LateUpdateBehavior" then
        set_head_hidden(settings.first_person and settings.hide_head, transform)
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

    local pos = try_call(joint, "get_Position")
    if pos == nil then
        debug.camera = "could not read head position"
        return
    end

    -- Keep the game's camera rotation (mouse look), only move the camera into the head
    local new_pos = pos + Vector3f.new(0, settings.up_offset, 0)
    local rot = try_call(cam_transform, "get_Rotation")
    if rot ~= nil then
        local ok, forward = pcall(function() return rot * Vector3f.new(0, 0, -1) end)
        if ok and forward ~= nil then
            new_pos = new_pos + forward * settings.forward_offset
        end
    end

    try_call(cam_transform, "set_Position", new_pos)
    debug.camera = "moved (camera: " .. tostring(try_call(cam_obj, "get_Name")) .. ")"
    debug.last_stage = stage
end

re.on_pre_application_entry("UpdateBehavior", update_toggle_key)
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
local minecraft_crosshair = false

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
        changed, settings.first_person = imgui.checkbox("First person (F5)", settings.first_person)
        changed, settings.hide_head = imgui.checkbox("Hide Leon's head", settings.hide_head)
        changed, settings.crosshair = imgui.checkbox("Crosshair", settings.crosshair)
        changed, settings.forward_offset = imgui.slider_float("Forward offset", settings.forward_offset, -0.5, 0.5)
        changed, settings.up_offset = imgui.slider_float("Up offset", settings.up_offset, -0.3, 0.3)
        changed, settings.stage = imgui.combo("Camera timing", settings.stage, STAGES)
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Player: " .. debug.player)
            imgui.text("Head: " .. debug.head)
            imgui.text("Camera: " .. debug.camera)
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
