-- Minecraft First Person for RE4 Remake (REFramework Lua script)
-- Moves the camera into Leon's head and draws Minecraft's "+" crosshair.
-- Press F5 to switch between first person and the normal RE4 camera.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft First Person

local settings = {
    first_person = true,
    forward_offset = 0.10,  -- meters in front of the head joint
    up_offset = 0.05,
    hide_head = true,
    crosshair = true,
    show_debug = false,
}

local KEY_F5 = 0x74

local HEAD_JOINT_NAMES = { "head", "Head", "head_0", "neck_1", "neck_0", "Neck" }
local PLAYER_OBJECT_METHODS = { "get_BodyGameObject", "get_GameObject", "get_PlayerGameObject" }

local debug = {
    player = "not checked yet",
    head = "not checked yet",
    camera = "not checked yet",
    forward = "not checked yet",
    joints = "",
}

local head_joint = nil
local head_joint_owner = nil
local head_hidden = false
local f5_was_down = false

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
    end
    return head_joint, transform
end

-- Re-applied every frame while hidden, in case the animation resets the scale
local function set_head_hidden(hidden)
    if head_joint == nil then return end
    if not hidden and not head_hidden then return end
    local s = hidden and 0.001 or 1.0
    try_call(head_joint, "set_LocalScale", Vector3f.new(s, s, s))
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

local function update_toggle_key()
    local ok, down = pcall(function() return reframework:is_key_down(KEY_F5) end)
    if not ok then return end
    if down and not f5_was_down then
        settings.first_person = not settings.first_person
    end
    f5_was_down = down
end

-- Runs right before the frame is drawn, after the game has placed its own camera
re.on_pre_application_entry("BeginRendering", function()
    update_toggle_key()

    local joint = get_head_joint()
    if joint == nil then return end

    set_head_hidden(settings.first_person and settings.hide_head)
    if not settings.first_person then return end

    local camera = sdk.get_primary_camera()
    local cam_obj = camera and try_call(camera, "get_GameObject")
    local cam_transform = cam_obj and try_call(cam_obj, "get_Transform")
    if cam_transform == nil then
        debug.camera = "camera not found"
        return
    end
    debug.camera = "ok"

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
            debug.forward = "ok"
        else
            debug.forward = "could not compute forward"
        end
    end

    try_call(cam_transform, "set_Position", new_pos)
end)

local function get_screen_size()
    local ok, size = pcall(imgui.get_display_size)
    if ok and size ~= nil and size.x > 0 then
        return size.x, size.y
    end
    return 1920, 1080
end

-- Minecraft-style "+" crosshair
re.on_frame(function()
    if not (settings.crosshair and settings.first_person) then return end
    if head_joint == nil then return end

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
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Player: " .. debug.player)
            imgui.text("Head: " .. debug.head)
            imgui.text("Camera: " .. debug.camera)
            imgui.text("Forward: " .. debug.forward)
            if imgui.button("List joints") then
                list_joints()
            end
            if debug.joints ~= "" then
                imgui.text("Joints: " .. debug.joints)
            end
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    set_head_hidden(false)
end)
