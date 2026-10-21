-- Minecraft Cutscenes for RE4 Remake (REFramework Lua script)
-- Your Minecraft character plays Leon's part in cutscenes, grabs, talks and radio calls: Leon is hidden,
-- and Minecraft draws your character (your skin) where Leon is, seen through RE4's own cutscene camera
-- (same position, direction and field of view), into the overlay picture. It walks and turns with Leon,
-- and its arms and legs follow Leon's (from his skeleton) when those joints are found.
-- Needs minecraft_control.lua, the RE4 Bridge Minecraft mod and the overlay plugin.
-- Data for Minecraft: reframework\data\minecraft_puppet.json, written every frame while it's on.
-- Install: copy this file to <RE4 folder>\reframework\autorun\
-- Settings: press Insert -> Script Generated UI -> Minecraft Cutscenes

local settings = {
    enabled = true,
    limbs = true,
    show_debug = false,
}

local PUPPET_FILE = "minecraft_puppet.json"   -- relative to reframework\data

-- RE4's turns where Leon is on screen (not menus, loading or F7)
local SCENE_REASONS = {
    get_IsEventLocked = true,
    isGrappled = true,
    get_IsInGrappleDamage = true,
    get_IsJacked = true,
    get_IsTalkActing = true,
    get_IsWirelessCall = true,
}

-- Leon's skeleton: from the shoulder/hip joint to the wrist/ankle joint. RE4's names come first (as listed
-- by minecraft_diagnostics.lua: R_UpperArm, R_Hand, R_Thigh, R_Foot...), then other RE Engine spellings.
-- Joint names are case-sensitive.
local LIMBS = {
    right_arm = { { "R_UpperArm", "r_arm_upper", "R_arm_upper", "r_arm_humerus" }, { "R_Hand", "R_Forearm", "r_arm_wrist", "R_arm_wrist", "r_arm_hand" } },
    left_arm = { { "L_UpperArm", "l_arm_upper", "L_arm_upper", "l_arm_humerus" }, { "L_Hand", "L_Forearm", "l_arm_wrist", "L_arm_wrist", "l_arm_hand" } },
    right_leg = { { "R_Thigh", "r_leg_femur", "R_leg_femur", "r_leg_upper" }, { "R_Foot", "R_Shin", "r_leg_ankle", "R_leg_ankle", "r_leg_foot" } },
    left_leg = { { "L_Thigh", "l_leg_femur", "L_leg_femur", "l_leg_upper" }, { "L_Foot", "L_Shin", "l_leg_ankle", "L_leg_ankle", "l_leg_foot" } },
}

local state = {
    active = false,
    session = 0,
    seq = 0,
    start = nil,          -- Leon's position when the scene started; Minecraft moves its player by the difference
    frame = 0,
    plugin_beat = nil, plugin_beat_frame = -100000, plugin_ready = false,
    joints_owner = nil, joints = {},
}
local debug = { status = "off", joints = "not looked up" }

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function get_leon_transform()
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local ctx = cm and try_call(cm, "getPlayerContextRef")
    local body = ctx and try_call(ctx, "get_BodyGameObject")
    return body and try_call(body, "get_Transform")
end

-- The overlay plugin is drawing (otherwise hiding Leon would leave nobody on screen)
local function update_plugin_state()
    if state.frame % 30 ~= 0 then return end
    local ok, plugin = pcall(json.load_file, "minecraft_overlay_plugin.json")
    if ok and type(plugin) == "table" then
        if plugin.beat ~= state.plugin_beat then
            state.plugin_beat = plugin.beat
            state.plugin_beat_frame = state.frame
        end
        state.plugin_ready = plugin.ready == true
    end
end

local function plugin_alive()
    return state.plugin_ready and state.frame - state.plugin_beat_frame < 240
end

local function minecraft_connected()
    local ok, b = pcall(json.load_file, "minecraft_bridge.json")
    return ok and type(b) == "table" and b.in_world == true and b.re4_control == true
end

-- Minecraft's yaw (degrees; 0 = +Z, turning toward -X) for a direction
local function mc_yaw(dir)
    return math.deg(math.atan(-dir.x, dir.z))
end

local function find_joint(transform, names)
    for _, name in ipairs(names) do
        local joint = try_call(transform, "getJointByName", name)
        if joint ~= nil then return joint, name end
    end
    return nil
end

local function lookup_joints(transform)
    if state.joints_owner == transform then return end
    state.joints_owner = transform
    state.joints = {}
    local found = {}
    for limb, names in pairs(LIMBS) do
        local a, an = find_joint(transform, names[1])
        local b, bn = find_joint(transform, names[2])
        if a ~= nil and b ~= nil then
            state.joints[limb] = { a, b }
            table.insert(found, limb .. " (" .. an .. " -> " .. bn .. ")")
        end
    end
    table.sort(found)
    debug.joints = #found > 0 and table.concat(found, ", ") or "none of the known joint names"
end

-- Minecraft model angles for a limb pointing along dir, in Leon's frame (forward, up, right).
-- Minecraft's limbs hang down by default; xRot swings them forward (negative) or back, zRot sideways.
local function limb_angles(dir, forward, up, right)
    local len = dir:length()
    if len < 0.001 then return nil end
    local df = (dir.x * forward.x + dir.y * forward.y + dir.z * forward.z) / len
    local du = (dir.x * up.x + dir.y * up.y + dir.z * up.z) / len
    local dr = (dir.x * right.x + dir.y * right.y + dir.z * right.z) / len
    local x = math.asin(math.max(-1, math.min(1, -df)))
    local z = math.atan(dr, -du)
    return { x = x, z = z }
end

local function camera_data()
    local camera = sdk.get_primary_camera()
    local cam_obj = camera and try_call(camera, "get_GameObject")
    local cam_transform = cam_obj and try_call(cam_obj, "get_Transform")
    local pos = cam_transform and try_call(cam_transform, "get_Position")
    local rot = cam_transform and try_call(cam_transform, "get_Rotation")
    if pos == nil or rot == nil then return nil end
    local ok, f = pcall(function() return rot * Vector3f.new(0, 0, -1) end)
    if not ok or f == nil then return nil end
    -- Minecraft wants the vertical field of view
    local fov = try_call(camera, "get_FOV") or 70
    if try_call(camera, "get_VerticalEnable") ~= true then
        local ok_s, size = pcall(imgui.get_display_size)
        local aspect = (ok_s and size ~= nil and size.y > 0) and size.x / size.y or 16 / 9
        fov = math.deg(2 * math.atan(math.tan(math.rad(fov) / 2) / aspect))
    end
    return pos, f, fov
end

local function write_puppet(data)
    state.seq = state.seq + 1
    data.seq = state.seq
    data.session = state.session
    pcall(json.dump_file, PUPPET_FILE, data)
end

re.on_frame(function()
    state.frame = state.frame + 1
    update_plugin_state()

    local control = MinecraftRE4Control
    local want = settings.enabled and type(control) == "table" and control.mode == "re4"
        and SCENE_REASONS[control.reason] == true and plugin_alive()
    local transform = want and get_leon_transform() or nil
    local leon = transform and try_call(transform, "get_Position")
    if want and (leon == nil or (not state.active and not minecraft_connected())) then want = false end

    if not want then
        if state.active then
            state.active = false
            write_puppet({ active = false })
        end
        if type(control) == "table" then control.puppet = false end
        debug.status = "off"
        return
    end

    if not state.active then
        state.active = true
        state.session = state.session + 1
        state.start = Vector3f.new(leon.x, leon.y, leon.z)
    end
    control.puppet = true

    local rot = try_call(transform, "get_Rotation")
    local ok, forward, up, right = pcall(function()
        return rot * Vector3f.new(0, 0, 1), rot * Vector3f.new(0, 1, 0), rot * Vector3f.new(-1, 0, 0)
    end)
    if not ok or forward == nil then
        forward, up, right = Vector3f.new(0, 0, 1), Vector3f.new(0, 1, 0), Vector3f.new(-1, 0, 0)
    end

    local data = { active = true }
    local s = state.start
    data.body = { x = leon.x - s.x, y = leon.y - s.y, z = leon.z - s.z, yaw = mc_yaw(forward) }

    local cam_pos, cam_dir, fov = camera_data()
    if cam_pos ~= nil then
        data.camera = {
            x = cam_pos.x - s.x, y = cam_pos.y - s.y, z = cam_pos.z - s.z,
            yaw = mc_yaw(cam_dir),
            pitch = -math.deg(math.asin(math.max(-1, math.min(1, cam_dir.y)))),
            fov = fov,
        }
    end

    if settings.limbs then
        lookup_joints(transform)
        local limbs = {}
        for limb, pair in pairs(state.joints) do
            local a = try_call(pair[1], "get_Position")
            local b = try_call(pair[2], "get_Position")
            if a ~= nil and b ~= nil then limbs[limb] = limb_angles(b - a, forward, up, right) end
        end
        data.limbs = limbs
    end

    write_puppet(data)
    debug.status = "on (" .. tostring(control.reason) .. ")"
end)

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Cutscenes") then
        local changed
        changed, settings.enabled = imgui.checkbox("Your Minecraft character plays Leon in cutscenes", settings.enabled)
        changed, settings.limbs = imgui.checkbox("Copy Leon's arm and leg movement", settings.limbs)
        imgui.text("Status: " .. debug.status)
        changed, settings.show_debug = imgui.checkbox("Show debug info", settings.show_debug)
        if settings.show_debug then
            imgui.text("Overlay plugin: " .. (plugin_alive() and "drawing" or "not running"))
            imgui.text("Leon's joints: " .. debug.joints)
        end
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    if state.active then pcall(json.dump_file, PUPPET_FILE, { active = false, seq = state.seq + 1, session = state.session }) end
end)
