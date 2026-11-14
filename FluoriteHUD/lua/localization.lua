-- English strings registered through SuperBLT, without localization-file IO.
if _G.IS_VR or not Hooks or type(Hooks.Add) ~= "function" then return end
if _G.FluoriteHUDLocalizationHooks == Hooks then return end

local function localize(manager)
    if not manager or type(manager.add_localized_strings) ~= "function" then return end
    manager:add_localized_strings({
        fluoritehud_title = "FluoriteHUD",
        fluoritehud_menu_desc = "Customize FluoriteHUD colors and preferences.",
        fluoritehud_spotting_desc = "Enables or disables custom spotting and marking of civilians.",
        fluoritehud_preview = "Preview", fluoritehud_rgb = "RGB",
        fluoritehud_spotting = "Enable spotting and marking civilians",
        fluoritehud_map_enemies = "Initial Enemies",
        fluoritehud_spawned_enemies = "New Enemies (+)",
        fluoritehud_cuffed_enemies = "Cuffed Enemies",
        fluoritehud_map_civilians = "Initial Civilians",
        fluoritehud_spawned_civilians = "New Civilians (+)",
        fluoritehud_cuffed_civilians = "Tied Civilians",
        fluoritehud_map_enemies_desc = "Color of hostile enemies counted in the initial group.",
        fluoritehud_spawned_enemies_desc = "Color of hostile enemies recorded after the initial group.",
        fluoritehud_cuffed_enemies_desc = "Color of enemies currently confirmed as cuffed.",
        fluoritehud_map_civilians_desc = "Color of free civilians counted in the initial group.",
        fluoritehud_spawned_civilians_desc = "Color of free civilians recorded after the initial group.",
        fluoritehud_cuffed_civilians_desc = "Color of tied civilians.",
        fluoritehud_red = "Red", fluoritehud_green = "Green", fluoritehud_blue = "Blue",
        fluoritehud_session_only = "Changes apply immediately. Pending preferences are saved when leaving FluoriteHUD; storage problems are logged."
    })
end

Hooks:Add("LocalizationManagerPostInit", "FluoriteHUD_Localization", localize)
localize(managers and managers.localization)
_G.FluoriteHUDLocalizationHooks = Hooks
