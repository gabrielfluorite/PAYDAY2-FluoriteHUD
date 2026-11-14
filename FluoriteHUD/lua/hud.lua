-- FluoriteHUD (SuperBLT, PAYDAY 2, Lua 5.1-compatible)
-- Client-side visual overlay only. The separate optional spotting module handles player interaction.

if _G.IS_VR or not HUDManager or not Hooks then
    return
end

local TAG = "[FluoriteHUD] "
local DEFAULT_CONFIG = {
    hide_vanilla_hostage_counter = true,
    top = 140,
    right_margin = 38,
    row_gap = 29,
    font_size = 24,
    alpha = 0.95,
    refresh_seconds = 0.25,
    initial_capture_delay_seconds = 1.0,
    width = 66,
    icon_offset = 0,
    number_offset = 24
}
local CONFIG = {}
for key, value in pairs(DEFAULT_CONFIG) do
    CONFIG[key] = value
end

_G.FluoriteHUDConfig = nil
local config_ok, config_result = pcall(dofile, ModPath .. "config.lua")
local custom_config = type(_G.FluoriteHUDConfig) == "table" and _G.FluoriteHUDConfig or
                      (type(config_result) == "table" and config_result or nil)
if type(custom_config) == "table" then
    for key, default in pairs(DEFAULT_CONFIG) do
        if type(custom_config[key]) == type(default) then
            CONFIG[key] = custom_config[key]
        end
    end
end
CONFIG.alpha = math.max(0, math.min(1, CONFIG.alpha))
CONFIG.refresh_seconds = math.max(0.05, math.min(10, CONFIG.refresh_seconds))
local capture_delay = CONFIG.initial_capture_delay_seconds
if capture_delay ~= capture_delay or capture_delay == math.huge or capture_delay < 0 then
    CONFIG.initial_capture_delay_seconds = DEFAULT_CONFIG.initial_capture_delay_seconds
end
CONFIG.row_gap = math.max(22, math.min(100, CONFIG.row_gap))
CONFIG.font_size = math.max(10, math.min(40, CONFIG.font_size))
CONFIG.width = math.max(50, math.min(200, CONFIG.width))
CONFIG.top = math.max(0, CONFIG.top)
CONFIG.right_margin = math.max(0, CONFIG.right_margin)

local PANEL_NAME = "fluorite_hud_v1"
local logged = {}
local update_disabled = false
local native_hide_disabled = false
local mission

-- GameSetup:init_managers creates a new EnemyManager for each level load,
-- including Setup:restart. Empty registries/player absence are not resets.
-- This state belongs to the EnemyManager generation, never to a panel.
local function get_mission()
    local enemy_mgr = managers and managers.enemy
    if not enemy_mgr then
        -- No generation change is inferred, but continuity before capture is
        -- uncertain. Require the full valid-player period again on return.
        if mission and not mission.tracking.initialized then mission.capture_elapsed = 0 end
        return nil
    end
    if not mission or mission.enemy_manager ~= enemy_mgr then
        mission = {
            enemy_manager = enemy_mgr,
            tracking = {
                initialized = false,
                initial_ids = {},
                initial_active = {},
                initial_civilian_ids = {}
            },
            capture_ready = false,
            capture_elapsed = 0,
            counts = nil,
            elapsed = 0
        }
    end
    return mission
end

local function trace(message)
    if log then
        log(TAG .. tostring(message))
    end
end

local function warn_once(key, message)
    if logged[key] then
        return
    end
    logged[key] = true
    if log then
        log(TAG .. tostring(message))
    end
end

local function is_living(unit)
    if not alive(unit) then
        return false
    end

    local damage = type(unit.character_damage) == "function" and unit:character_damage()
    return not damage or not damage.dead or not damage:dead()
end

-- CoreClass instances use their class as metatable and a .super chain.
-- Recognize host and husk brains before reading their different state layouts.
local function brain_is(brain, class)
    if type(brain) ~= "table" or type(class) ~= "table" then
        return false
    end
    local current, seen = getmetatable(brain), {}
    while type(current) == "table" and not seen[current] do
        if current == class then return true end
        seen[current] = true
        current = rawget(current, "super")
    end
    return false
end

-- Returns the observed state and eligibility for a hostile counter.
-- No remembered cuff state: missing current evidence never creates a hostage.
local function enemy_status(unit)
    local brain = type(unit.brain) == "function" and unit:brain()
    if brain_is(brain, HuskCopBrain) then
        if brain._dead then return "dead", false end
        if type(brain.converted) ~= "function" then return "unknown", false end
        if brain:converted() then return "converted", false end
        if type(brain.is_tied) ~= "function" then return "unknown", false end
        if brain:is_tied() == true then return "cuffed", false end
        if type(brain.surrendered) == "function" and brain:surrendered() then
            return "surrendered", false
        end
    elseif brain_is(brain, CopBrain) then
        local data = brain._logic_data
        if type(data) ~= "table" then return "unknown", false end
        if data.is_converted then return "converted", false end
        if data.name == "intimidated" then
            local internal = data.internal_data
            if type(internal) == "table" and internal.tied == true then
                return "cuffed", false
            end
            return "surrendered", false
        end
        -- CopLogicTrade replaces internal_data; is_hostile() can still be true.
        -- Conservatively omit offered/fleeing trade units until current evidence
        -- is restored (e.g. cancel_trade re-enters intimidated and _do_tied).
        if data.name == "trade" then return "unknown", false end
    else
        -- Preserve the existing hostile fallback for unrecognized/missing brains,
        -- but never infer cuffs from arbitrary is_tied/hostage/animation fields.
        return "unknown", not brain or type(brain.is_hostile) ~= "function" or brain:is_hostile()
    end
    local hostile = type(brain.is_hostile) == "function" and brain:is_hostile()
    return hostile and "hostile" or "unknown", hostile
end

-- Seal the initial population at the first valid in-heist reading.
-- Keys are EnemyManager registry keys (unit:key()), not NPC classes.
-- Baseline membership never grows; retired baseline enemies never reactivate.
-- Civilian baseline membership stays fixed, but a civilian can change between free and tied.
local function read_counts(tracking)
    local enemy_mgr = managers and managers.enemy
    if not enemy_mgr or not enemy_mgr.all_enemies or not enemy_mgr.all_civilians then
        return nil
    end

    -- Avoid accidentally sealing an empty menu/loading-screen registry.
    if not tracking.initialized then
        local player_mgr = managers and managers.player
        local player_unit = player_mgr and player_mgr.player_unit and player_mgr:player_unit()
        if not player_unit or not alive(player_unit) then
            return nil
        end
    end

    local initial_count, spawned_count, free_count, spawned_civil_count, tied_count = 0, 0, 0, 0, 0
    local cuffed_count = 0
    local enemies = enemy_mgr:all_enemies() or {}
    local civilians = enemy_mgr:all_civilians() or {}

    if not tracking.initialized then
        for key, data in pairs(enemies) do
            local unit = data and data.unit
            if unit and alive(unit) then
                tracking.initial_ids[key] = true
                local hostile = false
                if is_living(unit) then
                    local status
                    status, hostile = enemy_status(unit)
                end
                tracking.initial_active[key] = hostile and true or false
            end
        end
        -- A civilian is initial only if already alive at this first reading,
        -- regardless of whether they are currently tied.
        for key, data in pairs(civilians) do
            local unit = data and data.unit
            if unit and is_living(unit) then
                tracking.initial_civilian_ids[key] = true
            end
        end
        tracking.initialized = true
        trace("Initial enemy and civilian populations recorded")
    end

    local still_active = {}
    for key, data in pairs(enemies) do
        local unit = data and data.unit
        if unit and is_living(unit) then
            local status, hostile = enemy_status(unit)
            if status == "cuffed" then
                cuffed_count = cuffed_count + 1
            elseif tracking.initial_ids[key] then
                if tracking.initial_active[key] and hostile then
                    still_active[key] = true
                end
            elseif hostile then
                spawned_count = spawned_count + 1
            end
        end
    end

    for key, active in pairs(tracking.initial_active) do
        if active then
            if still_active[key] then
                initial_count = initial_count + 1
            else
                -- An initial unit can never return to the initial count.
                tracking.initial_active[key] = false
            end
        end
    end

    for key, data in pairs(civilians) do
        local unit = data and data.unit
        if unit and is_living(unit) then
            local brain = unit:brain()
            local logic_data = brain and brain._logic_data
            if logic_data and logic_data.is_tied then
                -- Tied civilians (including newly spawned ones) contribute
                -- only to the existing combined hostage counter.
                tied_count = tied_count + 1
            elseif tracking.initial_civilian_ids[key] then
                free_count = free_count + 1
            else
                spawned_civil_count = spawned_civil_count + 1
            end
        end
    end

    return initial_count, spawned_count, free_count, spawned_civil_count, tied_count, cuffed_count
end

local function should_hide_for_stats_screen(hud_manager)
    if hud_manager and hud_manager._fluorite_hud_force_hidden ~= nil then
        return hud_manager._fluorite_hud_force_hidden
    end

    if hud_manager and hud_manager._hud_statistics and alive(hud_manager._hud_statistics) then
        return hud_manager._hud_statistics:visible()
    end

    return false
end

local FADE_SECONDS = 0.15

local function valid_progress(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 1
end

local function frame_delta(dt)
    if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt == math.huge then return 0 end
    return dt
end

local function apply_panel_visibility(hud_manager, dt)
    local state = hud_manager and hud_manager._fluorite_hud
    if not state or not alive(state.panel) then
        return
    end

    state.fade_target = should_hide_for_stats_screen(hud_manager) and 0 or 1
    if state.fade_disabled then return end
    local progress = state.fade_progress
    if not valid_progress(progress) then error("Invalid panel fade progress") end
    local step = math.min(frame_delta(dt), FADE_SECONDS) / FADE_SECONDS
    if step > 0 and progress ~= state.fade_target then
        -- Snap tiny floating-point residues to the exact endpoint.
        if math.abs(progress - state.fade_target) <= step + 1e-9 then
            progress = state.fade_target
        else
            progress = progress + (state.fade_target == 1 and step or -step)
        end
    end
    local want_visible = progress > 0 or state.fade_target == 1
    -- Show at the existing alpha before a fade-in; never flash at full alpha.
    if want_visible and not state.currently_visible then
        state.panel:set_visible(true)
        state.currently_visible = true
    end
    local alpha = CONFIG.alpha * progress
    if state.applied_alpha ~= alpha then
        state.panel:set_alpha(alpha)
        state.applied_alpha = alpha
    end
    if state.currently_visible ~= want_visible then
        state.panel:set_visible(want_visible)
        state.currently_visible = want_visible
    end
    state.fade_progress = progress
end

local function update_panel_visibility(hud_manager, dt)
    -- Isolate Lua presentation failures. This is not protection from native crashes.
    local ok, err = pcall(apply_panel_visibility, hud_manager, dt)
    if not ok then
        local state = hud_manager and hud_manager._fluorite_hud
        if state then state.fade_disabled = true end
        warn_once("fade", "Panel fade disabled until setup after error: " .. tostring(err))
    end
end

local function hide_native_hostage_counter(hud_manager)
    if not CONFIG.hide_vanilla_hostage_counter then
        return
    end

    local state = hud_manager._fluorite_hud
    if not state or not alive(state.panel) or state.last.tied == nil or CONFIG.alpha <= 0 then
        return
    end

    local corner = hud_manager._hud_assault_corner
    local corner_panel = corner and corner._hud_panel
    if not corner_panel or not alive(corner_panel) then
        return
    end

    local native_panel = corner_panel:child("hostages_panel")
    if native_panel and alive(native_panel) and native_panel:visible() then
        native_panel:hide()
        warn_once("native_hidden", "Vanilla hostage panel hidden; other HUD elements untouched")
    end
end

-- Icons redrawn to closely match the original reference style:
-- white minimalist silhouettes, no colored background blocks.
local ICONS = {
    enemy = {
        { 8,  0,  8, 1 },
        { 6,  1, 12, 1 },
        { 7,  2, 10, 1 },
        { 9,  3,  6, 3 },
        { 8,  6,  8, 2 },
        { 7,  8, 10, 4 },
        { 5, 10,  2, 4 },
        {17,  8,  1, 3 },
        {18,  9,  2, 1 },
        {19, 10,  2, 1 },
        {20, 11,  2, 1 },
        { 8, 12,  3, 6 },
        {13, 12,  3, 6 }
    },
    free = {
        { 8,  1,  6, 6 },
        {10,  7,  2, 1 },
        { 8,  8,  6, 5 },
        { 6,  9,  2, 5 },
        {14,  9,  2, 5 },
        { 8, 13,  2, 6 },
        {12, 13,  2, 6 }
    },
    tied = {
        { 8,  1,  6, 6 },
        {10,  7,  2, 1 },
        { 8,  8,  6, 5 },
        { 5,  7,  3, 2 },
        { 3,  4,  2, 3 },
        {14,  7,  3, 2 },
        {17,  4,  2, 3 },
        { 8, 13,  2, 6 },
        {12, 13,  2, 6 }
    },
    enemies_cuffed = {
        { 6,  0, 12, 2 },
        { 8,  2,  8, 1 },
        { 9,  3,  6, 3 },
        { 8,  7,  8, 5 },
        { 5,  7,  3, 2 },
        { 3,  4,  2, 3 },
        {16,  7,  3, 2 },
        {19,  4,  2, 3 },
        { 8, 12,  3, 6 },
        {13, 12,  3, 6 }
    }
}

local function add_icon(parent, kind, y)
    local elements = {}
    local function rect(params)
        elements[#elements + 1] = parent:rect(params)
    end
    local shapes = ICONS[kind == "spawn" and "enemy" or
                         kind == "civil_spawn" and "free" or kind]
    local icon_color = kind == "spawn" and Color.red or
                       kind == "civil_spawn" and Color.yellow or Color.white
    for _, shape in ipairs(shapes) do
        rect({
            x = CONFIG.icon_offset + shape[1],
            y = y + shape[2],
            w = shape[3],
            h = shape[4],
            layer = 1,
            color = icon_color
        })
    end
    -- The extra '+' repeats the existing enemy/civilian convention.
    -- Both silhouette and '+' have the row's color (red or yellow).
    if kind == "spawn" or kind == "civil_spawn" then
        rect({ x = CONFIG.icon_offset + 18, y = y + 2, w = 5, h = 1, layer = 2, color = icon_color })
        rect({ x = CONFIG.icon_offset + 20, y = y, w = 1, h = 5, layer = 2, color = icon_color })
    end
    return elements
end

local COLOR_ROWS = {
    map_enemies = "enemy", spawned_enemies = "spawn", cuffed_enemies = "enemies_cuffed",
    map_civilians = "free", spawned_civilians = "civil_spawn", cuffed_civilians = "tied"
}

local function apply_colors(state, category)
    if not alive(state.panel) or not Color then return end
    local shared = _G.FluoriteHUDSettings
    local values = type(shared) == "table" and shared.values
    local colors = type(values) == "table" and values.colors
    if type(colors) ~= "table" then return end
    for name, row in pairs(COLOR_ROWS) do
        if not category or name == category then
            local rgb = colors[name]
            local valid = type(rgb) == "table"
            for _, key in ipairs({ "r", "g", "b" }) do
                local value = valid and rgb[key]
                if type(value) ~= "number" or value ~= value or value < 0 or value > 255 then valid = false end
            end
            if valid then
                local last = state.color_cache[name]
                if not last or last.r ~= rgb.r or last.g ~= rgb.g or last.b ~= rgb.b then
                    local color = Color(1, rgb.r / 255, rgb.g / 255, rgb.b / 255)
                    state.labels[row]:set_color(color)
                    for _, element in ipairs(state.icons[row]) do
                        if alive(element) then element:set_color(color) end
                    end
                    state.color_cache[name] = { r = rgb.r, g = rgb.g, b = rgb.b }
                end
            end
        end
    end
end

local function refresh_colors(state, category)
    -- Isolate Lua presentation failures from counting. Not a native-crash guard.
    local ok, err = pcall(apply_colors, state, category)
    if not ok then warn_once("colors", "Color update failed: " .. tostring(err)) end
end

local function sync_colors(state)
    local shared = _G.FluoriteHUDSettings
    if type(shared) == "table" and type(shared.add_listener) == "function" and state.color_service ~= shared then
        shared:add_listener("FluoriteHUD_HUDColors", function(kind, category)
            if kind == "color" then refresh_colors(state, category) end
        end)
        state.color_service = shared
    end
    refresh_colors(state)
end

local apply_counts

local function create_ui(hud_manager)
    local hud_id = PlayerBase and PlayerBase.PLAYER_INFO_HUD_PD2
    if not hud_id or not hud_manager:alive(hud_id) then
        return
    end

    local script = hud_manager:script(hud_id)
    local parent = script and script.panel
    if not parent or not alive(parent) then
        return
    end

    local prior = parent:child(PANEL_NAME)
    local old_state = hud_manager._fluorite_hud
    local old_panel = old_state and old_state.panel
    local target = should_hide_for_stats_screen(hud_manager) and 0 or 1
    local progress = target
    if alive(old_panel) and not old_state.fade_disabled and
        valid_progress(old_state.fade_progress) and
        (old_state.fade_target == 0 or old_state.fade_target == 1) then
        progress = old_state.fade_progress
    end
    local visible = progress > 0 or target == 1
    if alive(old_panel) and old_panel ~= prior and alive(old_panel:parent()) then
        old_panel:parent():remove(old_panel)
    end
    if prior then
        parent:remove(prior)
    end

    local width = CONFIG.width or 66
    local gap = CONFIG.row_gap or 29
    local ui = parent:panel({
        name = PANEL_NAME,
        x = math.max(0, parent:w() - width - CONFIG.right_margin),
        y = CONFIG.top,
        w = width,
        h = 5 * gap + 24,
        layer = 100,
        alpha = CONFIG.alpha * progress,
        visible = visible
    })

    local rows = {
        { key = "enemy",       kind = "enemy" },
        { key = "spawn",       kind = "spawn" },
        { key = "enemies_cuffed", kind = "enemies_cuffed" },
        { key = "free",        kind = "free" },
        { key = "civil_spawn", kind = "civil_spawn" },
        { key = "tied",        kind = "tied" }
    }
    local labels, row_panels, icons = {}, {}, {}

    for i, row in ipairs(rows) do
        local row_panel = ui:panel({
            name = "row_" .. row.key,
            x = 0,
            y = (i - 1) * gap,
            w = width,
            h = 24,
            visible = row.key == "free" or row.key == "tied"
        })
        icons[row.key] = add_icon(row_panel, row.kind, 0)
        labels[row.key] = row_panel:text({
            name = "count_" .. row.key,
            text = "-",
            x = CONFIG.number_offset,
            y = -1,
            w = math.max(1, width - CONFIG.number_offset),
            h = 24,
            align = "right",
            vertical = "center",
            font = tweak_data.menu.pd2_medium_font,
            font_size = CONFIG.font_size,
            color = row.kind == "spawn" and Color.red or
                    row.kind == "civil_spawn" and Color.yellow or Color.white,
            layer = 2
        })
        row_panels[row.key] = row_panel
    end

    hud_manager._fluorite_hud = {
        panel = ui,
        labels = labels,
        rows = row_panels,
        icons = icons,
        color_cache = {},
        last = {},
        mission = get_mission(),
        currently_visible = visible,
        fade_progress = progress,
        fade_target = target,
        applied_alpha = CONFIG.alpha * progress,
        showing_initials = false,
        showing_spawns = false,
        showing_enemies_cuffed = false,
        showing_free = true,
        showing_civil_spawns = false,
        showing_tied = true
    }
    -- Until the first count, civilian indicators keep the previous default visibility.
    row_panels.free:set_y(0)
    row_panels.tied:set_y(gap)
    ui:set_h(gap + 24)
    local state = hud_manager._fluorite_hud
    sync_colors(state)
    if state.mission then
        -- Preserve the existing explicit setup recovery after a Lua read error.
        state.mission.counting_disabled = nil
        apply_counts(state, state.mission.counts)
    end
    update_panel_visibility(hud_manager, 0)
    if state.mission then
        state.mission.capture_ready = true
    end
    trace("HUD panel created")
end

-- Every counter row disappears independently at zero; remaining rows occupy no empty slots.
local function set_row_visibility(state, show_initial, show_spawns, show_free, show_civil_spawns, show_tied, show_cuffed)
    if state.showing_initials == show_initial and
       state.showing_spawns == show_spawns and
       state.showing_enemies_cuffed == show_cuffed and
       state.showing_free == show_free and
       state.showing_civil_spawns == show_civil_spawns and
       state.showing_tied == show_tied then
        return
    end

    state.showing_initials = show_initial
    state.showing_spawns = show_spawns
    state.showing_enemies_cuffed = show_cuffed
    state.showing_free = show_free
    state.showing_civil_spawns = show_civil_spawns
    state.showing_tied = show_tied

    local gap = CONFIG.row_gap or 29
    local visible_rows = 0
    local visibility = {
        enemy = show_initial,
        spawn = show_spawns,
        enemies_cuffed = show_cuffed,
        free = show_free,
        civil_spawn = show_civil_spawns,
        tied = show_tied
    }
    for _, key in ipairs({ "enemy", "spawn", "enemies_cuffed", "free", "civil_spawn", "tied" }) do
        local row = state.rows[key]
        local show = visibility[key]
        row:set_visible(show)
        if show then
            row:set_y(visible_rows * gap)
            visible_rows = visible_rows + 1
        end
    end

    state.panel:set_h(visible_rows > 0 and ((visible_rows - 1) * gap + 24) or 0)
end

apply_counts = function(state, counts)
    if not counts then
        return
    end
    for key, amount in pairs(counts) do
        if state.last[key] ~= amount then
            state.labels[key]:set_text(tostring(amount))
            state.last[key] = amount
        end
    end
    set_row_visibility(state, counts.enemy > 0, counts.spawn > 0, counts.free > 0,
        counts.civil_spawn > 0, counts.tied > 0, counts.enemies_cuffed > 0)
end

local function read_due_counts(current, dt)
    -- Match the original first-panel prerequisite, then keep tracking even
    -- after visual objects disappear. This permission is mission-local.
    if not current.capture_ready then
        return
    end
    if not current.tracking.initialized then
        local player_mgr = managers and managers.player
        local unit = player_mgr and player_mgr.player_unit and player_mgr:player_unit()
        if not unit or not alive(unit) then
            current.capture_elapsed = 0
            return
        end
        current.capture_elapsed = math.min(CONFIG.initial_capture_delay_seconds,
            current.capture_elapsed + dt)
        if current.capture_elapsed < CONFIG.initial_capture_delay_seconds then return end
        -- The first read bypasses the normal cadence. Only read_counts seals
        -- cohorts; there are no registry queries or remembered spawns above.
    else
        current.elapsed = current.elapsed + dt
        if current.elapsed < CONFIG.refresh_seconds then return end
    end
    current.elapsed = 0
    return read_counts(current.tracking)
end

local function update_counts(current, dt)
    if current.counting_disabled then
        return
    end
    local ok, enemy, spawned, free, spawned_civil, tied, cuffed = pcall(read_due_counts, current, dt)
    if not ok then
        current.counting_disabled = true
        if not current.tracking.initialized then current.capture_elapsed = 0 end
        warn_once("count", "Counter read failed; further reads disabled for this HUD: " .. tostring(enemy))
        return
    end
    if enemy == nil then
        return
    end

    warn_once("first_counts", "Counters active (enemy initial/new/cuffed; civilian initial/new/tied): " .. tostring(enemy) .. "/" .. tostring(spawned) .. "/" .. tostring(cuffed) .. "; " .. tostring(free) .. "/" .. tostring(spawned_civil) .. "/" .. tostring(tied))
    current.counts = { enemy = enemy, spawn = spawned, enemies_cuffed = cuffed, free = free, civil_spawn = spawned_civil, tied = tied }
end

local function update_ui(hud_manager, dt)
    local current = get_mission()
    if not current then
        return
    end
    local state = hud_manager._fluorite_hud
    local has_panel = state and alive(state.panel)
    if has_panel then
        sync_colors(state)
        if state.mission ~= current then
            -- A surviving HUD must not display values from the previous mission.
            state.mission = current
            state.last = {}
            for _, label in pairs(state.labels) do
                label:set_text("-")
            end
            set_row_visibility(state, false, false, true, false, true, false)
        end
        -- A valid panel may survive replacement of EnemyManager.
        current.capture_ready = true
    end
    update_counts(current, dt)
    if has_panel then
        apply_counts(state, current.counts)
    end
end

Hooks:PostHook(HUDManager, "_setup_player_info_hud_pd2", "FluoriteHUD_setup", function(self)
    trace("HUD setup hook called")
    update_disabled = false
    native_hide_disabled = false
    local ok, err = pcall(create_ui, self)
    if not ok then
        warn_once("setup", "Failed to create display: " .. tostring(err))
    end
end)

Hooks:PostHook(HUDManager, "update", "FluoriteHUD_update", function(self, t, dt)
    local delta = frame_delta(dt)
    -- Runs even without EnemyManager or after the count/UI guards have tripped.
    update_panel_visibility(self, delta)
    if not update_disabled then
        local ok, err = pcall(update_ui, self, delta)
        if not ok then
            update_disabled = true
            warn_once("ui", "Overlay update disabled after first error: " .. tostring(err))
        end
    end

    if not native_hide_disabled and not update_disabled then
        local hide_ok, hide_err = pcall(hide_native_hostage_counter, self)
        if not hide_ok then
            native_hide_disabled = true
            warn_once("native", "Native-counter hiding disabled after first error: " .. tostring(hide_err))
        end
    end
end)

Hooks:PostHook(HUDManager, "resolution_changed", "FluoriteHUD_resolution", function(self)
    local ok, err = pcall(function()
        local state = self._fluorite_hud
        if state and alive(state.panel) then
            state.panel:set_x(math.max(0, state.panel:parent():w() - (CONFIG.width or 66) - CONFIG.right_margin))
        end
    end)
    if not ok then
        warn_once("resolution", "Failed to realign display: " .. tostring(err))
    end
end)

if HUDManager.show_stats_screen then
    Hooks:PostHook(HUDManager, "show_stats_screen", "FluoriteHUD_show_stats", function(self)
        self._fluorite_hud_force_hidden = true
        update_panel_visibility(self, 0)
    end)
end

if HUDManager.hide_stats_screen then
    Hooks:PostHook(HUDManager, "hide_stats_screen", "FluoriteHUD_hide_stats", function(self)
        self._fluorite_hud_force_hidden = false
        update_panel_visibility(self, 0)
    end)
end

if not config_ok then
    warn_once("config_error", "config.lua could not be loaded; built-in defaults active: " .. tostring(config_result))
elseif not custom_config then
    warn_once("config_missing", "config.lua supplied no config table; built-in defaults active")
else
    trace("Configuration loaded (defaults + validated overrides)")
end
trace("HUD hooks registered")
