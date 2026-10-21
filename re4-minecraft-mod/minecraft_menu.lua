-- RE4 Minecraft mod: the one "Minecraft" menu in REFramework's Script Generated UI.
-- Every minecraft_*.lua script registers its settings table and its menu section in MinecraftRE4Menu; this
-- script draws them all under one heading (quick settings first), saves the settings in
-- reframework\data\minecraft_settings.json whenever they change and puts them back when RE4 starts, and has
-- the buttons for the diagnostics report and the support zip (made by the Minecraft mod).
-- Without this script, each script draws its own section as before.

local SETTINGS_FILE = "minecraft_settings.json"
local BRIDGE_FILE = "minecraft_bridge.json"
local SAVE_CHECK_FRAMES = 30        -- look for changed settings this often
local ZIP_AFTER_REPORT_FRAMES = 30  -- the diagnostics report is saved first, then the zip is asked for

MinecraftRE4Menu = MinecraftRE4Menu or { sections = {}, settings = {} }
local menu = MinecraftRE4Menu
menu.present = true

-- The most used switches, shown first: { section, key, label }
local QUICK = {
    { "gameplay", "no_damage", "RE4's hits cost Minecraft hearts (Leon keeps full health)" },
    { "gameplay", "share_death", "Shared death (Minecraft and Leon die together)" },
    { "gameplay", "flinch", "Enemies flinch at Minecraft hits" },
    { "gameplay", "enemies_look_at_mobs", "Enemies look at the Minecraft mobs fighting them" },
    { "gameplay", "enemies_attack_mobs", "Enemies swing at the Minecraft mobs fighting them" },
    { "native", "enabled", "Real RE4 mobs (experimental)" },
    { "first_person", "first_person", "Minecraft camera (F5 views)" },
    { "cutscenes", "enabled", "Your Minecraft character plays Leon in cutscenes" },
    { "hud", "smart_hide_re4_ui", "Hide RE4's HUD (keeps its prompts)" },
}

local state = {
    frame = 0,
    applied = false,     -- saved settings put back (on the first frame, when every script has loaded)
    defaults = {},       -- section -> key -> value at start (for "Reset to defaults")
    last_saved = nil,
    zip_at = nil,        -- frame to ask the Minecraft mod for the zip
    zip_status = nil,
    bridge = nil,
    bridge_seq = nil,
    bridge_seen = -1000, -- frame the bridge file last changed
}

-- Settings worth keeping: plain values, not the debug switches
local function kept(key, value)
    local t = type(value)
    return type(key) == "string" and not key:find("^show_") and (t == "boolean" or t == "number" or t == "string")
end

local function snapshot()
    local out = {}
    for name, tbl in pairs(menu.settings) do
        if type(tbl) == "table" then
            local s = {}
            for k, v in pairs(tbl) do
                if kept(k, v) then s[k] = v end
            end
            out[name] = s
        end
    end
    return out
end

-- The same settings always give the same text (to see whether anything changed)
local function canonical(snap)
    local names = {}
    for name in pairs(snap) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local keys = {}
        for k in pairs(snap[name]) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do parts[#parts + 1] = name .. "." .. k .. "=" .. tostring(snap[name][k]) end
    end
    return table.concat(parts, ";")
end

local function apply_saved()
    state.defaults = snapshot()
    local ok, saved = pcall(json.load_file, SETTINGS_FILE)
    if ok and type(saved) == "table" then
        for name, values in pairs(saved) do
            local tbl = menu.settings[name]
            if type(tbl) == "table" and type(values) == "table" then
                for k, v in pairs(values) do
                    -- only settings that still exist, with the same kind of value
                    if kept(k, v) and tbl[k] ~= nil and type(tbl[k]) == type(v) then tbl[k] = v end
                end
            end
        end
    end
    state.last_saved = canonical(snapshot())
end

local function save_if_changed()
    local snap = snapshot()
    local text = canonical(snap)
    if text ~= state.last_saved then
        if pcall(json.dump_file, SETTINGS_FILE, snap) then state.last_saved = text end
    end
end

local function reset_defaults()
    for name, values in pairs(state.defaults) do
        local tbl = menu.settings[name]
        if type(tbl) == "table" then
            for k, v in pairs(values) do tbl[k] = v end
        end
    end
end

local function read_bridge()
    local ok, data = pcall(json.load_file, BRIDGE_FILE)
    if not ok or type(data) ~= "table" then return end
    state.bridge = data
    if data.seq ~= state.bridge_seq then
        state.bridge_seq = data.seq
        state.bridge_seen = state.frame
    end
end

re.on_frame(function()
    state.frame = state.frame + 1
    if not state.applied then
        state.applied = true
        apply_saved()
    end
    if state.frame % SAVE_CHECK_FRAMES == 0 then save_if_changed() end
    if state.frame % 30 == 0 or state.zip_at ~= nil or (state.zip_status == "busy") then read_bridge() end
    if state.zip_at ~= nil and state.frame >= state.zip_at then
        state.zip_at = nil
        -- a time: always larger than the last request, also after Reset scripts
        menu.report_request = math.max(os.time(), (menu.report_request or 0) + 1)
        state.zip_status = "busy"
    end
    if state.zip_status == "busy" and type(state.bridge) == "table" and type(state.bridge.report) == "table"
            and state.bridge.report.seq == menu.report_request and state.bridge.report.busy == false then
        state.zip_status = "done"
    end
end)

re.on_script_reset(function()
    pcall(save_if_changed)
end)

local function quick_settings()
    local any = false
    for _, q in ipairs(QUICK) do
        local tbl = menu.settings[q[1]]
        if type(tbl) == "table" and type(tbl[q[2]]) == "boolean" then
            local _, value = imgui.checkbox(q[3], tbl[q[2]])
            tbl[q[2]] = value
            any = true
        end
    end
    if not any then imgui.text("(no Minecraft scripts found)") end
end

local function connection_line()
    local b = state.bridge
    local live = b ~= nil and state.frame - state.bridge_seen < 120
    local control = MinecraftRE4Control
    local who = type(control) == "table" and (tostring(control.mode) .. " (" .. tostring(control.reason) .. ")") or "?"
    if not live then
        imgui.text("Minecraft: not connected (start Minecraft and open your world)")
    else
        imgui.text(string.format("Minecraft: %s | in charge of Leon: %s",
            b.in_world and ("in a world, " .. tostring(b.game_mode)) or "on the title screen", who))
    end
end

local function support_buttons()
    if imgui.button("Save diagnostics report") then
        if type(menu.save_report) == "function" then menu.save_report() end
    end
    imgui.same_line()
    if imgui.button("Make support zip") and state.zip_status ~= "busy" and state.zip_at == nil then
        if type(menu.save_report) == "function" then menu.save_report() end
        state.zip_at = state.frame + ZIP_AFTER_REPORT_FRAMES
        state.zip_status = "waiting"
    end
    local report = type(state.bridge) == "table" and state.bridge.report or nil
    if state.zip_status == "waiting" or state.zip_status == "busy" then
        local live = state.bridge ~= nil and state.frame - state.bridge_seen < 120
        imgui.text(live and "  making the zip..." or "  waiting for Minecraft (the zip is made by the Minecraft mod)")
    elseif state.zip_status == "done" and type(report) == "table" then
        if report.path then
            imgui.text("  Saved: " .. tostring(report.path))
            imgui.text("  Send this file. It holds the logs and reports (and your Windows user name in file paths).")
        else
            imgui.text("  Could not make the zip: " .. tostring(report.error))
        end
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("Minecraft") then return end
    connection_line()
    quick_settings()
    support_buttons()
    if imgui.button("Reset all settings to defaults") then reset_defaults() end
    imgui.text("Settings are saved by themselves (reframework\\data\\" .. SETTINGS_FILE .. ").")

    local list = {}
    for name, s in pairs(menu.sections) do
        if type(s) == "table" and type(s.draw) == "function" then list[#list + 1] = { name = name, s = s } end
    end
    table.sort(list, function(a, b) return (a.s.order or 99) < (b.s.order or 99) end)
    for _, entry in ipairs(list) do
        local ok, err = pcall(entry.s.draw)
        if not ok then imgui.text(entry.name .. ": " .. tostring(err)) end
    end
    imgui.tree_pop()
end)
