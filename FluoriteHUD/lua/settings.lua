-- FluoriteHUD shared preferences, Lua 5.1. Subscribers apply presentation changes.
-- One automatic read per Lua session; explicit save uses verified staging/backup.
if type(_G.FluoriteHUDSettings) == "table" then
    if type(_G.FluoriteHUDSettings.initialize) == "function" then
        _G.FluoriteHUDSettings:initialize()
    end
    return _G.FluoriteHUDSettings
end

local SCHEMA_VERSION = 1
local DEFAULT_COLORS = {
    map_enemies = { r = 255, g = 255, b = 255 },
    spawned_enemies = { r = 255, g = 0, b = 0 },
    cuffed_enemies = { r = 255, g = 255, b = 255 },
    map_civilians = { r = 255, g = 255, b = 255 },
    spawned_civilians = { r = 255, g = 255, b = 0 },
    cuffed_civilians = { r = 255, g = 255, b = 255 }
}

local function channel(value, default)
    if type(value) ~= "number" or value ~= value or
        value == math.huge or value == -math.huge then
        return default
    end
    -- Round halves up after clamping; no numeric-string coercion.
    return math.floor(math.max(0, math.min(255, value)) + 0.5)
end

local function normalize(input)
    input = type(input) == "table" and input or {}
    local colors = type(input.colors) == "table" and input.colors or {}
    local result = { colors = {}, spotting_enabled = true }
    for name, defaults in pairs(DEFAULT_COLORS) do
        local supplied = type(colors[name]) == "table" and colors[name] or {}
        local color = {}
        for key, default in pairs(defaults) do color[key] = channel(supplied[key], default) end
        result.colors[name] = color
    end
    if type(input.spotting_enabled) == "boolean" then
        result.spotting_enabled = input.spotting_enabled
    end
    return result
end

local Settings = { values = normalize(), legacy = _G.FluoriteHUDConfig }
local listeners = {}

function Settings:add_listener(id, callback)
    if type(id) ~= "string" or type(callback) ~= "function" then return false end
    listeners[id] = callback
    return true
end

function Settings:remove_listener(id)
    listeners[id] = nil
end

local function notify(kind, category)
    for id, callback in pairs(listeners) do
        local ok, err = pcall(callback, kind, category)
        if not ok and log then
            log("[FluoriteHUD] Settings listener failed (" .. id .. "): " .. tostring(err))
        end
    end
end

function Settings:defaults()
    return normalize()
end

-- Update in place so consumers can retain the values/colors/category references.
-- This replaces preferences, not legacy config or any mission state.
function Settings:replace(input)
    local validated = normalize(input)
    local changed = {}
    for name, color in pairs(validated.colors) do
        for key, value in pairs(color) do
            if self.values.colors[name][key] ~= value then changed[name] = true end
            self.values.colors[name][key] = value
        end
    end
    local spotting_changed = self.values.spotting_enabled ~= validated.spotting_enabled
    self.values.spotting_enabled = validated.spotting_enabled
    for name in pairs(changed) do notify("color", name) end
    if spotting_changed then notify("spotting") end
    return self.values
end

function Settings:set_color(name, key, value)
    local defaults = DEFAULT_COLORS[name]
    if not defaults or defaults[key] == nil then return false, "unknown_field" end
    local validated = channel(value, defaults[key])
    if self.values.colors[name][key] ~= validated then
        self.values.colors[name][key] = validated
        notify("color", name)
    end
    return true
end

function Settings:set_spotting(value)
    local validated = type(value) ~= "boolean" or value
    if self.values.spotting_enabled ~= validated then
        self.values.spotting_enabled = validated
        notify("spotting")
    end
    return true
end

-- Only whitelisted preferences are serialized; never export this service or legacy config.
function Settings:snapshot()
    local document = normalize(self.values)
    document.schema_version = SCHEMA_VERSION
    return document
end

local function storage(options)
    if options == nil then options = {} end
    if type(options) ~= "table" then return nil, "invalid_storage" end
    local path = options.path
    if path == nil and type(SavePath) == "string" and SavePath ~= "" then
        path = SavePath .. "fluoritehud.json"
    end
    local open = options.open or (io and io.open)
    local codec = options.json or json
    if type(path) ~= "string" or path == "" or type(open) ~= "function" or
        type(codec) ~= "table" then
        return nil, "storage_unavailable"
    end
    return { path = path, open = open, json = codec,
        rename = options.rename or (os and os.rename), remove = options.remove or (os and os.remove) }
end

local function read_file(target, path)
    local ok, handle, message, code = pcall(target.open, path or target.path, "rb")
    if not ok then return nil, "read_open_failed" end
    if not handle then
        -- Lua io.open reports ENOENT as 2; all ambiguous failures block saving.
        return nil, code == 2 and "missing" or "read_open_failed"
    end
    local read_ok, data = pcall(function() return handle:read("*a") end)
    local close_ok, closed = pcall(function() return handle:close() end)
    if not read_ok or type(data) ~= "string" then return nil, "read_failed" end
    if not close_ok or not closed then return nil, "read_close_failed" end
    return data
end

-- Structural boundary only, not a second JSON parser. In particular, a stray
-- closing bracket must not terminate the array envelope ahead of trailing data.
local function complete_object(data)
    if not data:match("^%s*{") then return false end
    local stack, quoted, escaped = {}, false, false
    for index = 1, #data do
        local char = data:sub(index, index)
        if quoted then
            if escaped then escaped = false
            elseif char == "\\" then escaped = true
            elseif char == '"' then quoted = false end
        elseif char == '"' then quoted = true
        elseif char == "{" or char == "[" then stack[#stack + 1] = char
        elseif char == "}" or char == "]" then
            local expected = char == "}" and "{" or "["
            if stack[#stack] ~= expected then return false end
            stack[#stack] = nil
            if #stack == 0 then return data:sub(index + 1):match("^%s*$") ~= nil end
        end
    end
    return false
end

local function decode_document(target, data)
    if data:match("^%s*$") then return nil, "empty" end
    if not complete_object(data) then return nil, "invalid_structure" end
    if type(target.json.decode) ~= "function" then return nil, "decoder_unavailable" end
    -- SuperBLT json.decode drops the parser's end position. An array envelope
    -- makes the parser consume the following delimiter rather than accept a
    -- valid object prefix and silently ignore an appended second document.
    local ok, envelope = pcall(target.json.decode, "[" .. data .. "]")
    if not ok or type(envelope) ~= "table" then return nil, "decode_failed" end
    for key in pairs(envelope) do
        if key ~= 1 then return nil, "invalid_structure" end
    end
    local document = envelope[1]
    if type(document) ~= "table" then return nil, "invalid_structure" end
    if document.schema_version ~= SCHEMA_VERSION then return nil, "unsupported_schema" end
    return document
end

-- Compare decoded values, not codec key ordering. Snapshots contain no cycles.
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local saved = Settings:snapshot()
local initialized, automatic_options, automatic_block = false, nil, nil
local diagnostics = {}
local function diagnose(code)
    if code and code ~= "missing" and not diagnostics[code] then
        diagnostics[code] = true
        if log then
            log("[FluoriteHUD] Preferences persistence blocked or failed: " .. code ..
                "; uncertain files are preserved for manual review.")
        end
    end
end

function Settings:is_dirty()
    return not equal(self:snapshot(), saved)
end

-- Explicit reload keeps its original contract: errors restore defaults in place.
-- Automatic initialization additionally inspects recovery files below.
function Settings:load(options)
    local target, err = storage(options)
    local document
    if target then
        local data
        data, err = read_file(target)
        if data then document, err = decode_document(target, data) end
    end
    self:replace(document)
    saved = self:snapshot()
    if automatic_options and target and target.path == automatic_options.path then
        automatic_block = not document and err ~= "missing" and err or nil
    end
    if not document then return false, err end
    return true
end

local function inspect(target, path)
    local bytes, err = read_file(target, path)
    if not bytes then return { error = err } end
    local document, decode_error = decode_document(target, bytes)
    return { bytes = bytes, document = document, error = decode_error }
end

local function operation(fn, ...)
    local ok, result = pcall(fn, ...)
    return ok and result and true or false
end

local function matches(target, path, expected)
    local data, err = read_file(target, path)
    if expected == nil then return data == nil and err == "missing" end
    return data == expected
end

-- Only discard this attempt's fully verified staging file, with an unchanged
-- final destination. Interrupted/partial/foreign staging files are never deleted.
local function discard_stage(target, temporary, encoded, previous)
    if matches(target, target.path, previous) and matches(target, temporary, encoded) then
        return operation(target.remove, temporary)
    end
    return false
end

function Settings:save(options)
    if type(options) ~= "table" or options.write_enabled ~= true then
        return false, "write_disabled"
    end
    local target, err = storage(options)
    if not target then return false, err end
    if type(target.json.encode) ~= "function" then return false, "encoder_unavailable" end
    local snapshot = self:snapshot()
    local encoded_ok, encoded = pcall(target.json.encode, snapshot)
    if not encoded_ok or type(encoded) ~= "string" or not encoded:match("^%s*{") then
        return false, "encode_failed"
    end
    local decoded = decode_document(target, encoded)
    if not decoded or not equal(decoded, snapshot) then return false, "encode_verification_failed" end
    if type(target.rename) ~= "function" or type(target.remove) ~= "function" then
        return false, "replacement_unavailable"
    end

    local temporary, backup = target.path .. ".tmp", target.path .. ".bak"
    local prior = inspect(target, target.path)
    if not prior.document and prior.error ~= "missing" then return false, prior.error end
    local stage = inspect(target, temporary)
    if stage.error ~= "missing" then return false, "temporary_requires_review" end
    local recovery = inspect(target, backup)
    if not recovery.document and recovery.error ~= "missing" then return false, "backup_requires_review" end
    if not prior.document and recovery.document then return false, "recovery_required" end

    -- No overwrite of a previous staging artifact, even if it looks valid.
    if not matches(target, temporary, nil) then return false, "temporary_requires_review" end
    local opened, handle = pcall(target.open, temporary, "wb")
    if not opened or not handle then return false, "write_open_failed" end
    local wrote, result = pcall(function() return handle:write(encoded) end)
    local flushed, flush_result = true, true
    if wrote and result then
        flushed, flush_result = pcall(function() return handle:flush() end)
    end
    local closed, close_result = pcall(function() return handle:close() end)
    -- Keep failed/uncertain writes for review. Never claim that close/flush is fsync.
    if not wrote or not result then return false, "write_failed" end
    if not flushed or not flush_result then return false, "flush_failed" end
    if not closed or not close_result then return false, "write_close_failed" end
    local verified = inspect(target, temporary)
    if verified.bytes ~= encoded or not verified.document or not equal(verified.document, snapshot) then
        return false, "temporary_verification_failed"
    end

    -- Recheck bytes before changing any recovery artifact. No cross-process lock:
    -- external concurrent writers remain unsupported, including on POSIX.
    if not matches(target, target.path, prior.bytes) or not matches(target, backup, recovery.bytes) then
        return false, "files_changed"
    end
    if recovery.document then
        -- Both current final and new staging are already valid. The old backup
        -- can now be rotated; never remove the final to make room for rename.
        if not operation(target.remove, backup) then
            discard_stage(target, temporary, encoded, prior.bytes)
            return false, "backup_remove_failed"
        end
        if not matches(target, backup, nil) then return false, "backup_remove_failed" end
    end
    if prior.document then
        if not operation(target.rename, target.path, backup) then
            discard_stage(target, temporary, encoded, prior.bytes)
            return false, "backup_move_failed"
        end
        if not matches(target, backup, prior.bytes) or not matches(target, target.path, nil) then
            return false, "backup_verification_failed"
        end
    end
    -- Windows CRT rename does not replace an existing destination.
    if not matches(target, target.path, nil) then return false, "destination_changed" end
    if not operation(target.rename, temporary, target.path) then
        if prior.document then
            if not matches(target, target.path, nil) or not matches(target, backup, prior.bytes) or
                not operation(target.rename, backup, target.path) or
                not matches(target, target.path, prior.bytes) then
                return false, "rollback_failed"
            end
        end
        if not discard_stage(target, temporary, encoded, prior.bytes) then
            return false, "promotion_failed_cleanup_required"
        end
        return false, "promotion_failed"
    end
    if not matches(target, target.path, encoded) then return false, "final_verification_failed" end
    -- Keep the preceding document in .bak. It is validated before the next rotation.
    saved = snapshot
    return true
end

function Settings:initialize(options)
    if initialized then return true end
    local target = storage(options)
    -- Defer when the runtime is incomplete. No test flag or second settings owner.
    if _G.IS_VR or not target or type(target.json.decode) ~= "function" or
        type(target.json.encode) ~= "function" or type(target.rename) ~= "function" or
        type(target.remove) ~= "function" then return false, "storage_unavailable" end
    -- Never discard edits made while the runtime APIs were unavailable.
    if self:is_dirty() then return false, "initialization_pending_edits" end
    initialized = true
    automatic_options = { path = target.path, open = target.open, json = target.json,
        rename = target.rename, remove = target.remove, write_enabled = true }
    local final = inspect(target, target.path)
    local stage = inspect(target, target.path .. ".tmp")
    local backup = inspect(target, target.path .. ".bak")
    local document, code = final.document, final.error
    if final.error == "missing" and backup.document then
        -- Recovery is memory-only. Leave all artifacts for deliberate repair.
        document, code = backup.document, "recovery_required"
    end
    -- A transient read failure must not later overwrite unseen preferences with
    -- defaults. Clearing this latch requires a deliberate successful explicit load.
    automatic_block = code ~= "missing" and code or nil
    self:replace(document)
    saved = self:snapshot()
    diagnose(code)
    if stage.error ~= "missing" then diagnose("temporary_requires_review") end
    if not backup.document and backup.error ~= "missing" then diagnose("backup_requires_review") end
    return true
end

function Settings:flush()
    if not initialized then
        diagnose("not_initialized")
        return false, "not_initialized"
    end
    if not self:is_dirty() then return true, "unchanged" end
    if automatic_block then
        diagnose(automatic_block)
        return false, automatic_block
    end
    local ok, err = self:save(automatic_options)
    if not ok then diagnose(err) end
    return ok, err
end

_G.FluoriteHUDSettings = Settings
Settings:initialize()
return Settings
