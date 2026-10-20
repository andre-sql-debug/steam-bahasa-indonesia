-- RE4 scanner for the Minecraft mod (REFramework Lua script)
-- Lists Leon's components, movement-related methods and how enemies can be found,
-- and saves it to reframework\data\minecraft_scan.json so it can be shared.
-- Usage: load a save, stand near some enemies, then press
-- Insert -> Script Generated UI -> Minecraft Scanner -> Scan.

local SCAN_FILE = "minecraft_scan.json"   -- relative to reframework\data

-- Method names containing one of these are interesting for movement and combat
local KEYWORDS = {
    "move", "velocity", "speed", "jump", "ground", "warp", "gravity", "fall", "position",
    "input", "damage", "attack", "hit", "dead", "die", "enemy", "knife", "melee",
}

local status = "not scanned yet"
local summary = {}

local function try_call(obj, method, ...)
    local args = { ... }
    local ok, result = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return result end
    return nil
end

local function type_name(obj)
    local ok, name = pcall(function() return obj:get_type_definition():get_full_name() end)
    return ok and name or "?"
end

local function matches(name)
    local lower = name:lower()
    for _, keyword in ipairs(KEYWORDS) do
        if lower:find(keyword) then return true end
    end
    return false
end

-- Method names of a type and its parents; all of them, or only the interesting ones
local function method_names(td, only_matching)
    local names = {}
    local seen = {}
    local depth = 0
    while td ~= nil and depth < 6 do
        local ok, methods = pcall(function() return td:get_methods() end)
        if ok and methods ~= nil then
            for _, m in ipairs(methods) do
                local ok_name, name = pcall(function() return m:get_name() end)
                if ok_name and name ~= nil and not seen[name] and (not only_matching or matches(name)) then
                    seen[name] = true
                    table.insert(names, td:get_full_name() .. "." .. name)
                end
            end
        end
        local ok_parent, parent = pcall(function() return td:get_parent_type() end)
        td = ok_parent and parent or nil
        depth = depth + 1
    end
    return names
end

local function list_components(go)
    local result = {}
    local components = try_call(go, "get_Components")
    if components == nil then return result end
    local ok, elements = pcall(function() return components:get_elements() end)
    if not ok or elements == nil then return result end
    for _, comp in ipairs(elements) do
        local name = type_name(comp)
        local td = comp:get_type_definition()
        table.insert(result, { type = name, methods = method_names(td, true) })
    end
    return result
end

-- Tries the usual ways RE Engine games keep a list of enemies
local function scan_enemies(cm)
    local found = {}
    for _, method in ipairs({ "get_EnemyContextList", "get_EnemyContexts", "getEnemyContextList", "get_EnemyList" }) do
        local list = try_call(cm, method)
        if list ~= nil then
            local count = try_call(list, "get_Count")
            local entry = { method = method, list_type = type_name(list), count = count }
            if count ~= nil and count > 0 then
                local first = try_call(list, "get_Item", 0)
                if first ~= nil then
                    entry.first_type = type_name(first)
                    entry.first_methods = method_names(first:get_type_definition(), true)
                end
            end
            table.insert(found, entry)
        end
    end
    return found
end

local function scan()
    local result = { version = 1 }
    summary = {}

    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if cm == nil then
        status = "CharacterManager not found"
        return
    end
    result.character_manager_methods = method_names(cm:get_type_definition(), false)

    local ctx = try_call(cm, "getPlayerContextRef")
    if ctx ~= nil then
        result.player_context_type = type_name(ctx)
        result.player_context_methods = method_names(ctx:get_type_definition(), false)

        local body = try_call(ctx, "get_BodyGameObject")
        if body ~= nil then
            result.player_object_name = try_call(body, "get_Name")
            result.player_components = list_components(body)
            table.insert(summary, "Leon components: " .. #result.player_components)
        else
            table.insert(summary, "Leon's body object not found")
        end
    else
        table.insert(summary, "player context not found (load a save first)")
    end

    local cc = sdk.find_type_definition("via.physics.CharacterController")
    if cc ~= nil then
        result.character_controller_methods = method_names(cc, false)
    end

    result.enemies = scan_enemies(cm)
    table.insert(summary, "enemy lists found: " .. #result.enemies)

    local ok, written = pcall(json.dump_file, SCAN_FILE, result)
    if ok and written ~= false then
        status = "saved to reframework\\data\\" .. SCAN_FILE
    else
        status = "scan done, but could not save the file"
    end
end

re.on_draw_ui(function()
    if imgui.tree_node("Minecraft Scanner") then
        imgui.text("Load a save and stand near enemies, then press Scan.")
        if imgui.button("Scan") then
            local ok, err = pcall(scan)
            if not ok then status = "scan failed: " .. tostring(err) end
        end
        imgui.text("Status: " .. status)
        for _, line in ipairs(summary) do
            imgui.text(line)
        end
        imgui.tree_pop()
    end
end)
