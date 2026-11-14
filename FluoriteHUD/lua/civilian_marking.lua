-- FluoriteHUD: civilian spotting in stealth
-- Independent implementation, inspired by Civilian Marking / Spotting in Stealth.
-- No game source replacement, no NPC intimidation, no automatic scan or extra keybind.
-- Limited to offline/single-player mode by default; contours are local (not network-synced).

if _G.IS_VR or not Hooks then
    return
end

local TAG = "[FluoriteHUD: civilian marking] "
local installed = _G.FluoriteHUDCivilianMarkingHooks or {}
_G.FluoriteHUDCivilianMarkingHooks = installed

local SETTINGS = {
    civilian_marking_enabled = true,
    civilian_marking_offline_only = true,
    civilian_marking_requires_chameleon = true
}

-- The in-game dofile may discard the return value; config.lua exports its table globally.
local user_config = type(_G.FluoriteHUDConfig) == "table" and _G.FluoriteHUDConfig or nil
if not user_config and ModPath then
    pcall(dofile, ModPath .. "config.lua")
    user_config = type(_G.FluoriteHUDConfig) == "table" and _G.FluoriteHUDConfig or nil
end
if user_config then
    for k, default in pairs(SETTINGS) do
        if type(user_config[k]) == type(default) then
            SETTINGS[k] = user_config[k]
        end
    end
end

local failures = {}
local function warn_once(key, err)
    if not failures[key] then
        failures[key] = true
        if log then
            log(TAG .. tostring(err))
        end
    end
end

local function may_mark()
    if not SETTINGS.civilian_marking_enabled then
        return false
    end
    -- Read the shared preference on every attempt; legacy restrictions still apply.
    local shared = _G.FluoriteHUDSettings
    local values = type(shared) == "table" and shared.values
    if type(values) ~= "table" or values.spotting_enabled ~= true then
        return false
    end
    if SETTINGS.civilian_marking_offline_only then
        if not Global or not Global.game_settings or Global.game_settings.single_player ~= true then
            return false
        end
    end
    local group = managers and managers.groupai and managers.groupai:state()
    if not group or not group.whisper_mode or not group:whisper_mode() then
        return false
    end
    if SETTINGS.civilian_marking_requires_chameleon then
        local pm = managers and managers.player
        -- Chameleon basic grants this vanilla casing-mode spotting upgrade.
        if not pm or not pm.has_category_upgrade or
           not pm:has_category_upgrade("player", "special_enemy_highlight_mask_off") then
            return false
        end
    end
    return true
end

local function find_calm_civilian(state)
    local enemy_mgr = managers and managers.enemy
    if not enemy_mgr or not enemy_mgr.all_civilians or
       not state or not state._ext_camera or not state._ext_movement or
       not state._add_unit_to_char_table or not state._get_interaction_target then
        return nil
    end

    local cam_forward = state._ext_camera:forward()
    local head_pos = state._ext_movement:m_head_pos()
    local td = tweak_data and tweak_data.player and tweak_data.player.long_dis_interaction
    if not cam_forward or not head_pos or not td or not td.highlight_range then
        return nil
    end
    local pm = managers.player
    local spotting_mul = pm:upgrade_value("player", "marked_distance_mul", 1)
    local range_mul = pm:upgrade_value("player", "intimidate_range_mul", 1) *
                      pm:upgrade_value("player", "passive_intimidate_range_mul", 1)
    -- Restore the same civilian-marking range used by v0.1.10.
    -- Do not cap it to ordinary-guard intimidation distance (v0.1.12/0.1.13).
    -- Native guard/camera/turret ranges and marking rules remain unmodified.
    local limit = td.highlight_range * spotting_mul * range_mul
    local candidates = {}

    for _, data in pairs(enemy_mgr:all_civilians() or {}) do
        local unit = data and data.unit
        if unit and alive(unit) and unit.movement and unit.brain and unit.contour and
           unit:in_slot(21) then
            local movement = unit:movement()
            local brain = unit:brain()
            local dmg = unit:character_damage()
            local anim = unit:anim_data()
            local logic = brain and brain._logic_data
            local is_escort = data.char_tweak and data.char_tweak.is_escort
            if movement and movement.cool and movement:cool() and
               not (dmg and dmg.dead and dmg:dead()) and
               not (logic and logic.is_tied) and
               not (anim and anim.long_dis_interact_disabled) and
               not is_escort and not (unit:unit_data() and unit:unit_data().disable_shout) then
                -- Preserve the original v0.1.10 aim cone and native visibility checks.
                local pos = movement:m_head_pos() + math.UP * 30
                local delta = pos - head_pos
                if delta:angle(cam_forward) <= 12 then
                    state:_add_unit_to_char_table(
                        candidates, unit, 1, limit,
                        false, true, 0.01, head_pos, cam_forward
                    )
                end
            end
        end
    end

    local target = state:_get_interaction_target(candidates, head_pos, cam_forward)
    return target and target.unit or nil
end

-- Use the same native, read-only enemy/camera/turret selection to find the
-- competing target. Unlike v0.1.12, it does NOT automatically win.
-- Whoever is nearer along the aim ray wins, within the existing eligibility,
-- distance, 12-degree aim cone, and native line-of-sight checks.
local function get_vanilla_mark_target(state)
    if not state or not state._get_unit_intimidation_action then
        return nil, true -- Unknown native selection: preserve vanilla behavior.
    end

    local _, _, target = state:_get_unit_intimidation_action(
        true, false, false, false, false, nil, nil, true
    )
    if not target then
        return nil, false
    end
    if target.unit and alive(target.unit) and
       (target.unit_type == 0 or target.unit_type == 3 or target.unit_type == 4) then
        return target, false
    end
    return nil, true -- Unexpected target: don't override native selection.
end

local function get_mark_position(unit, kind)
    -- Never call SecurityCamera:get_mark_check_position() from this mod.
    -- Its native implementation dereferences CameraLens/g_lamp without a nil
    -- check; calling it again while selecting a civilian caused a game-level
    -- access violation in v0.1.14 (not catchable by Lua pcall).
    -- For a camera, use only the valid unit's safe world origin as an
    -- approximate depth anchor. If it is unavailable, the caller leaves
    -- the native marking decision untouched. No new camera-object queries.
    if kind == 3 then
        if unit.position then
            return unit:position()
        end
        return nil
    end
    if unit.movement then
        local movement = unit:movement()
        if movement and movement.m_head_pos then
            return movement:m_head_pos() + math.UP * 30
        end
    end
    -- Some turret units have no character movement extension.
    if unit.position then
        return unit:position()
    end
    return nil
end

local function native_target_is_first(state, native_target, civilian)
    if not native_target then
        return false
    end
    local camera = state._ext_camera
    local movement = state._ext_movement
    if not camera or not movement then
        return true
    end

    local eye = movement:m_head_pos()
    local look = camera:forward()
    local native_pos = get_mark_position(native_target.unit, native_target.unit_type)
    local civilian_pos = get_mark_position(civilian, 1)
    if not eye or not look or not native_pos or not civilian_pos then
        return true -- Cannot establish depth: let vanilla retain control.
    end

    -- Do not let a native target outside the same 12-degree aiming cone
    -- steal a civilian mark merely because it happens to be closer off-axis.
    local native_delta = native_pos - eye
    local civilian_delta = civilian_pos - eye
    if native_delta:angle(look) > 12 then
        return false
    end

    -- Projection along the view direction, not distance to NPC origin.
    -- For two eligible targets aligned with the crosshair, the smaller
    -- positive depth is visually in front. Give ties to vanilla.
    local native_depth = native_delta:dot(look)
    local civilian_depth = civilian_delta:dot(look)
    if not native_depth or not civilian_depth or native_depth <= 0 or civilian_depth <= 0 then
        return true
    end
    return native_depth <= civilian_depth
end

local function try_spot_civilian(state, t, casing_mark_call)
    if not may_mark() or not t or not state then
        return false
    end
    -- PlayerMaskOff:_check_action_interact already enforces the cooldown, then
    -- sets _intimidate_t = t BEFORE calling mark_units("f11", t, true).
    -- Do not reject that same approved action as if it were a second press.
    -- Retain cooldown checking for masked mode and any other casing invocation.
    if state._intimidate_t and tweak_data and tweak_data.player and
       tweak_data.player.movement_state and
       t - state._intimidate_t < tweak_data.player.movement_state.interaction_delay then
        if not (casing_mark_call and state._intimidate_t == t) then
            return false
        end
    end
    local unit = find_calm_civilian(state)
    if not unit then
        return false
    end
    -- Respect the physical order of targets in the player's aim, rather
    -- than assigning a fixed advantage to civilians or guards.
    local native_target, uncertain = get_vanilla_mark_target(state)
    if uncertain or native_target_is_first(state, native_target, unit) then
        return false
    end
    local contour = unit:contour()
    if not contour or not contour.add then
        return false
    end
    -- Use the same timed mark outline preset as vanilla enemy marking.
    -- Local-only: do not send spot_enemy or any custom network message.
    local multiplier = managers.player:upgrade_value("player", "mark_enemy_time_multiplier", 1)
    contour:add("mark_enemy", false, multiplier)
    state._intimidate_t = t
    return true
end

-- Only the local visual part of PlayerStandard's distance interaction.
-- The native helper sends a network message BEFORE checking animation gates.
local function try_point_locally(state, t)
    if type(t) ~= "number" or t ~= t or t == math.huge or t == -math.huge or t < 0 then
        return
    end
    if type(state._state_data) ~= "table" then return end
    local idstring_type = type(Idstring)
    -- Native constructors may be callable tables/userdata. Do not inspect
    -- their metatables or probe them; the one real construction below remains
    -- inside the wrapper's existing Lua error boundary if __call is absent.
    if idstring_type ~= "function" and idstring_type ~= "table" and idstring_type ~= "userdata" then
        return
    end
    local camera = state._ext_camera
    local weapon = state._equipped_unit
    if not camera then return end
    if type(camera.play_redirect) ~= "function" then return end
    if type(alive) ~= "function" then return end
    if not alive(camera._camera_unit) then return end
    if not weapon then return end
    if not alive(weapon) then return end
    if type(weapon.base) ~= "function" then return end
    if state._state_data.in_steelsight then return end
    if state._shooting then return end
    if state._use_item_expire_t then return end
    if state._running then return end
    -- Missing state queries are not evidence that an animation is allowed.
    -- Check ALL query APIs before calling any, preserving the original order.
    if type(state._is_reloading) ~= "function" then return end
    if type(state._changing_weapon) ~= "function" then return end
    if type(state._is_meleeing) ~= "function" then return end
    if type(state._is_using_bipod) ~= "function" then return end
    if state:_is_reloading() then return end
    if state:_changing_weapon() then return end
    if state:_is_meleeing() then return end
    if state:_is_using_bipod() then return end
    local base = weapon:base()
    if not base then return end
    if type(base.start_shooting_allowed) ~= "function" then return end
    if not base:start_shooting_allowed() then return end
    local redirect = Idstring("cmd_point")
    if not redirect then return end
    local result = camera:play_redirect(redirect)
    if result then
        -- Same native interruption window, not a new marking cooldown.
        -- Do not install a timer when the redirect fails or raises a Lua error.
        state._state_data.interact_redirect_t = t + 1
    end
end

if PlayerStandard and PlayerStandard._start_action_intimidate and not installed.standard then
    local previous = PlayerStandard._start_action_intimidate
    PlayerStandard._start_action_intimidate = function(self, t, secondary, ...)
        -- Never override a long-press command or a civilian who's already alerted.
        if not secondary then
            local ok, marked = pcall(try_spot_civilian, self, t)
            if ok and marked then
                -- The mark has already succeeded. A gesture error must never
                -- retry marking or fall through to intimidation/voice/network.
                -- pcall handles Lua errors only, not native access violations.
                local gesture_ok, err = pcall(try_point_locally, self, t)
                if not gesture_ok then
                    warn_once("point", "Local pointing failed; civilian mark preserved: " .. tostring(err))
                end
                warn_once("first_masked_mark", "First masked-stealth civilian mark applied")
                return
            end
            if not ok then
                warn_once("masked", "Masked spotting failed; vanilla behavior preserved: " .. tostring(marked))
            end
        end
        return previous(self, t, secondary, ...)
    end
    installed.standard = true
    if log then log(TAG .. "Masked-stealth hook installed") end
end

if PlayerMaskOff and PlayerMaskOff.mark_units and not installed.maskoff then
    local previous = PlayerMaskOff.mark_units
    PlayerMaskOff.mark_units = function(self, line, t, no_gesture, skip_alert, ...)
        -- Only intercept the normal casing mark command, not arbitrary calls
        -- that other mods might make to mark_units.
        if line == "f11" and no_gesture == true then
            local ok, marked = pcall(try_spot_civilian, self, t, true)
            if ok and marked then
                warn_once("first_casing_mark", "First casing-mode civilian mark applied")
                return true
            end
            if not ok then
                warn_once("maskoff", "Casing-mode spotting failed; vanilla behavior preserved: " .. tostring(marked))
            end
        end
        return previous(self, line, t, no_gesture, skip_alert, ...)
    end
    installed.maskoff = true
    if log then log(TAG .. "Casing-mode hook installed") end
end
