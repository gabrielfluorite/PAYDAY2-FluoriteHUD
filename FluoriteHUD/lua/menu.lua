-- FluoriteHUD SuperBLT menus. Save pending preferences only when leaving ROOT.
if _G.IS_VR or not Hooks or type(Hooks.Add) ~= "function" then return end
if _G.FluoriteHUDMenuHooks == Hooks then return end

if not _G.FluoriteHUDSettings and type(ModPath) == "string" then
    pcall(dofile, ModPath .. "config.lua")
end

local ROOT = "fluoritehud_options"
local CATEGORIES = { "map_enemies", "spawned_enemies", "cuffed_enemies",
    "map_civilians", "spawned_civilians", "cuffed_civilians" }
local CHANNELS = { { "r", "red" }, { "g", "green" }, { "b", "blue" } }
local cycles = setmetatable({}, { __mode = "k" })

local function settings()
    local shared = _G.FluoriteHUDSettings
    if type(shared) ~= "table" or type(shared.values) ~= "table" or
        type(shared.values.colors) ~= "table" or type(shared.set_color) ~= "function" or
        type(shared.set_spotting) ~= "function" then return end
    -- Retry a deferred bootstrap before building controls; initialized sessions
    -- return immediately, and pending edits are never discarded by a late load.
    if type(shared.initialize) == "function" then shared:initialize() end
    for _, name in ipairs(CATEGORIES) do
        local color = shared.values.colors[name]
        if type(color) ~= "table" then return end
        for _, channel in ipairs(CHANNELS) do
            if type(color[channel[1]]) ~= "number" then return end
        end
    end
    return shared
end

local function ready(nodes)
    if type(nodes) ~= "table" or type(nodes.blt_options) ~= "table" or
        type(MenuHelper) ~= "table" or type(MenuCallbackHandler) ~= "table" then return false end
    for _, method in ipairs({ "NewMenu", "AddMenuItem", "BuildMenu", "AddSlider", "AddToggle" }) do
        if type(MenuHelper[method]) ~= "function" then return false end
    end
    return settings() ~= nil
end

local function value_of(item)
    if type(item) ~= "table" or type(item.value) ~= "function" then return end
    local ok, value = pcall(item.value, item)
    if ok then return value end
end

-- MenuRenderer resolves gui_class when opening a node. Keep the preview inside
-- that node's safe_rect_panel, so native hide/close owns its entire lifetime.
local function preview_call(gui, method)
    if gui._fluorite_preview_failed then return end
    local ok, err = pcall(gui[method], gui)
    if not ok then
        gui._fluorite_preview_failed = true
        if type(log) == "function" then log("[FluoriteHUD] Menu preview unavailable: " .. tostring(err)) end
    end
end

local function preview_class()
    if _G.FluoriteHUDColorNodeGui then return true end
    if type(class) ~= "function" or type(MenuNodeGui) ~= "table" then return false end
    for _, method in ipairs({ "init", "set_visible", "resolution_changed", "close" }) do
        if type(MenuNodeGui[method]) ~= "function" then return false end
    end
    local gui = class(MenuNodeGui)
    function gui:init(node, layer, parameters)
        gui.super.init(self, node, layer, parameters)
        self._fluorite_category = node:parameters().fluoritehud_category
        preview_call(self, "_fluorite_create_preview")
    end
    function gui:_fluorite_create_preview()
        local parent = self.safe_rect_panel
        if not alive(parent) or not managers.localization then return end
        local panel = parent:panel({ name = "fluoritehud_preview", x = 20,
            y = parent:h() * 0.3, w = 240, h = 116, layer = self.layers.items, visible = false })
        self._fluorite_preview_panel = panel
        local font = tweak_data.menu.pd2_small_font
        panel:text({ name = "label", text = managers.localization:text("fluoritehud_preview"),
            font = font, font_size = 24, color = Color.white, x = 0, y = 0, w = 240, h = 28 })
        -- A white frame keeps a black swatch distinguishable from the background.
        panel:rect({ name = "frame", x = 0, y = 32, w = 240, h = 48, color = Color.white })
        self._fluorite_swatch = panel:rect({ name = "swatch", x = 2, y = 34,
            w = 236, h = 44, layer = 1, color = Color.white })
        self._fluorite_rgb = panel:text({ name = "rgb", text = "", font = font,
            font_size = 20, color = Color.white, x = 0, y = 86, w = 240, h = 26 })
        self:_fluorite_refresh_preview()
        panel:set_visible(true)
    end
    function gui:_fluorite_refresh_preview()
        if not alive(self._fluorite_swatch) or not alive(self._fluorite_rgb) then return end
        local shared = _G.FluoriteHUDSettings
        local rgb = shared and shared.values and shared.values.colors[self._fluorite_category]
        if not rgb then return end
        self._fluorite_swatch:set_color(Color(1, rgb.r / 255, rgb.g / 255, rgb.b / 255))
        self._fluorite_rgb:set_text(managers.localization:text("fluoritehud_rgb") ..
            ": " .. rgb.r .. ", " .. rgb.g .. ", " .. rgb.b)
    end
    function gui:set_visible(visible)
        gui.super.set_visible(self, visible)
        if visible then preview_call(self, "_fluorite_refresh_preview") end
    end
    function gui:resolution_changed()
        gui.super.resolution_changed(self)
        if alive(self._fluorite_preview_panel) and alive(self.safe_rect_panel) then
            self._fluorite_preview_panel:set_y(self.safe_rect_panel:h() * 0.3)
        end
    end
    function gui:close(...)
        self._fluorite_swatch, self._fluorite_rgb, self._fluorite_preview_panel = nil, nil, nil
        return gui.super.close(self, ...)
    end
    _G.FluoriteHUDColorNodeGui = gui
    return true
end

local function slider_callback(category, channel)
    return function(_, item)
        local shared = settings()
        if not shared then return end
        local value = value_of(item)
        -- Accept finite numbers or complete decimal strings at the UI boundary.
        -- Settings itself remains strictly numeric; expressions/hex/code are rejected.
        if type(value) == "string" then
            if not value:match("^%s*[+-]?%d+%.?%d*%s*$") and
                not value:match("^%s*[+-]?%.%d+%s*$") then return end
            value = tonumber(value)
        end
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return end
        shared:set_color(category, channel, value)
        if type(item.set_value) == "function" then item:set_value(shared.values.colors[category][channel]) end
        -- CoreMenuNodeGui attaches gui_node to each visible item when opening it.
        local gui = item._parameters and item._parameters.gui_node
        if gui and gui._fluorite_category == category and
            type(gui._fluorite_refresh_preview) == "function" then
            preview_call(gui, "_fluorite_refresh_preview")
        end
    end
end

local function toggle_callback(_, item)
    local shared = settings()
    if not shared then return end
    local value = value_of(item)
    if value == "on" then value = true elseif value == "off" then value = false end
    if type(value) ~= "boolean" then return end
    shared:set_spotting(value)
    if type(item.set_value) == "function" then item:set_value(value and "on" or "off") end
end

local function activate(cycle)
    -- SuperBLT processes main/pause separately using one helper registry.
    for id, node in pairs(cycle.menus) do MenuHelper.menus[id] = node end
end

Hooks:Add("MenuManagerSetupCustomMenus", "FluoriteHUD_MenuSetup", function(_, nodes)
    if not ready(nodes) then return end
    local cycle = { helper = MenuHelper, menus = {}, controls = {} }
    local function create(id)
        local node = MenuHelper:NewMenu(id)
        if not node then return false end
        node._items_list = {} -- only our newly cloned nodes; discard inherited queued items
        -- CoreMenuNode:trigger_back iterates this table even with no callbacks.
        -- Clear deferred names too: set_callback_handler can bind them again.
        node._parameters.back_callback = {}
        node._parameters.back_callback_name = {}
        cycle.menus[id] = node
        return true
    end
    if not create(ROOT) then return end
    for _, name in ipairs(CATEGORIES) do
        if not create("fluoritehud_color_" .. name) then return end
        if preview_class() then
            local params = cycle.menus["fluoritehud_color_" .. name]._parameters
            params.gui_class = "FluoriteHUDColorNodeGui"
            params.fluoritehud_category = name
        end
    end
    cycles[nodes] = cycle
end)

Hooks:Add("MenuManagerPopulateCustomMenus", "FluoriteHUD_MenuPopulate", function(_, nodes)
    local cycle = type(nodes) == "table" and cycles[nodes]
    if not cycle or cycle.populated or not ready(nodes) or cycle.helper ~= MenuHelper then return end
    activate(cycle)
    local shared = settings()
    MenuCallbackHandler.FluoriteHUD_Spotting = toggle_callback
    MenuCallbackHandler.FluoriteHUD_SavePreferences = function()
        local current = settings()
        if current and type(current.flush) == "function" then current:flush() end
    end
    cycle.toggle = MenuHelper:AddToggle({ id = "fluoritehud_spotting", title = "fluoritehud_spotting",
        desc = "fluoritehud_spotting_desc", callback = "FluoriteHUD_Spotting", menu_id = ROOT,
        value = shared.values.spotting_enabled, priority = 100 })
    for _, name in ipairs(CATEGORIES) do
        for index, channel in ipairs(CHANNELS) do
            local callback_id = "FluoriteHUD_RGB_" .. name .. "_" .. channel[1]
            MenuCallbackHandler[callback_id] = slider_callback(name, channel[1])
            local item = MenuHelper:AddSlider({
                id = "fluoritehud_rgb_" .. name .. "_" .. channel[1],
                title = "fluoritehud_" .. channel[2], callback = callback_id,
                menu_id = "fluoritehud_color_" .. name, value = shared.values.colors[name][channel[1]],
                min = 0, max = 255, step = 1, show_value = true, display_precision = 0,
                priority = 4 - index
            })
            cycle.controls[#cycle.controls + 1] = { item = item, category = name, channel = channel[1] }
        end
    end
    cycle.populated = true
end)

Hooks:Add("MenuManagerBuildCustomMenus", "FluoriteHUD_MenuBuild", function(_, nodes)
    local cycle = type(nodes) == "table" and cycles[nodes]
    if not cycle or not cycle.populated or cycle.built or not ready(nodes) or cycle.helper ~= MenuHelper then return end
    activate(cycle)
    local shared = settings()
    -- Read current values again: they may have changed after population.
    if cycle.toggle then cycle.toggle:set_value(shared.values.spotting_enabled and "on" or "off") end
    for _, control in ipairs(cycle.controls) do
        if control.item then control.item:set_value(shared.values.colors[control.category][control.channel]) end
    end
    for id in pairs(cycle.menus) do
        local data = id == ROOT and { back_callback = "FluoriteHUD_SavePreferences" } or nil
        nodes[id] = MenuHelper:BuildMenu(id, data) -- also installs the native back button
        if not nodes[id] then return end
    end
    for index, name in ipairs(CATEGORIES) do
        MenuHelper:AddMenuItem(nodes[ROOT], "fluoritehud_color_" .. name,
            "fluoritehud_" .. name, "fluoritehud_" .. name .. "_desc", index + 1)
    end
    local linked = false
    for _, item in pairs(nodes.blt_options._items or {}) do
        if item._parameters and item._parameters.name == ROOT then linked = true end
    end
    if not linked then
        MenuHelper:AddMenuItem(nodes.blt_options, ROOT, "fluoritehud_title", "fluoritehud_menu_desc")
    end
    cycle.built = true
end)

_G.FluoriteHUDMenuHooks = Hooks
