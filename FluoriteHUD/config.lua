-- NOTE: PAYDAY 2 dofile may discard returned values; export this table globally.
-- FluoriteHUD: customization without changing gameplay code.
-- Units are in PAYDAY 2 safe-HUD coordinates (usually 1280x720).
-- HUD reloads clear the legacy export; the settings owner retains its identity.
local shared = _G.FluoriteHUDSettings
if type(shared) == "table" and type(shared.legacy) == "table" then
    _G.FluoriteHUDConfig = shared.legacy
    if type(shared.initialize) == "function" then shared:initialize() end
    return shared.legacy
end
_G.FluoriteHUDConfig = _G.FluoriteHUDConfig or {
    hide_vanilla_hostage_counter = true,
    top = 140,
    right_margin = 38,
    row_gap = 29,         -- spacing; new enemy/civilian rows appear only when positive
    font_size = 24,
    alpha = 0.95,
    refresh_seconds = 0.25,
    initial_capture_delay_seconds = 1.0, -- valid HUD/player time before the first snapshot
    width = 66,
    icon_offset = 0,
    number_offset = 24,
    civilian_marking_enabled = true,
    civilian_marking_offline_only = true, -- do not activate in online sessions
    civilian_marking_requires_chameleon = true -- require the basic Chameleon skill
}

-- Load once, including when the game's dofile discards return values.
-- Settings initializes preferences once, before HUD/menu consume them.
if not shared and type(ModPath) == "string" then
    local ok, err = pcall(dofile, ModPath .. "lua/settings.lua")
    if not ok and log then log("[FluoriteHUD] Settings initialization failed: " .. tostring(err)) end
    shared = _G.FluoriteHUDSettings
end
if type(shared) == "table" then
    shared.legacy = _G.FluoriteHUDConfig
    if type(shared.initialize) == "function" then shared:initialize() end
end
return _G.FluoriteHUDConfig
