-- @description Ostertoaster Timeline Looper
-- @author Ostertoaster
-- @version 1.0
-- @provides
--   [effect] Ostertoaster/Timeline Looper.jsfx
--   [effect] Ostertoaster/Timeline Looper Sum.jsfx
-- @about
--   Timeline looper for REAPER. Place red "rec" and green "play" MIDI items
--   on a track to define recording and playback regions. The companion JSFX plugin
--   handles real-time audio capture and playback with crossfading.
--
-- Scans tracks for rec/play MIDI items, writes current group to gmem per track.
-- Exports buffer before advancing to the next group on the same track.

local reaper = reaper
local SCRIPT_NAME = "Ostertoaster Timeline Looper"
local _, _, _, SCRIPT_CMD_ID = reaper.get_action_context()

reaper.gmem_attach("timeline_looper")

-- ─── Startup persistence ────────────────────────────────────────────────────

local STARTUP_BEGIN = "-- [Timeline Looper auto-start] --"
local STARTUP_END   = "-- [/Timeline Looper auto-start] --"

local function get_startup_path()
  return reaper.GetResourcePath() .. "/Scripts/__startup.lua"
end

local function install_startup()
  local cmd_str = reaper.ReverseNamedCommandLookup(SCRIPT_CMD_ID)
  if not cmd_str then return end

  -- Flag this project for auto-start (saved in .rpp)
  reaper.SetProjExtState(0, "TimelineLooper", "autostart", "1")

  -- Store command ID persistently so __startup.lua can find us
  reaper.SetExtState("TimelineLooper", "cmd_id", cmd_str, true)

  -- Add loader block to __startup.lua if not already present
  local path = get_startup_path()
  local f = io.open(path, "r")
  local content = f and f:read("*a") or ""
  if f then f:close() end

  if content:find(STARTUP_BEGIN, 1, true) then return end

  local block = "\n" .. STARTUP_BEGIN .. "\n"
    .. "reaper.defer(function()\n"
    .. "  local retval, val = reaper.GetProjExtState(0, 'TimelineLooper', 'autostart')\n"
    .. "  if retval > 0 and val == '1' then\n"
    .. "    local cs = reaper.GetExtState('TimelineLooper', 'cmd_id')\n"
    .. "    if cs and cs ~= '' then\n"
    .. "      local cmd = reaper.NamedCommandLookup('_' .. cs)\n"
    .. "      if cmd > 0 then reaper.Main_OnCommand(cmd, 0) end\n"
    .. "    end\n"
    .. "  end\n"
    .. "end)\n"
    .. STARTUP_END .. "\n"

  f = io.open(path, "a")
  if f then
    f:write(block)
    f:close()
  end
end

local function uninstall_startup()
  -- Clear the per-project autostart flag
  reaper.SetProjExtState(0, "TimelineLooper", "autostart", "")
end

-- ─── State ───────────────────────────────────────────────────────────────────

local script_running = true
local last_scan_time = 0
local SCAN_INTERVAL = 1.0
local PRE_ROLL = 0.05
local POST_ROLL = 0.05
local last_play_state = reaper.GetPlayState()
local was_recording = false
local export_enabled = true
local was_mouse_down = false

-- Per-track data: keyed by track pointer
--   .groups = ordered list of { rec_item, play_items={}, track }
--   .current = index into .groups (the group currently written to gmem)
--   .exported = true if current group's buffer was already exported
--   .cleared  = true if current group's old audio was already cleared
local track_data = {}

-- ─── Item helpers ────────────────────────────────────────────────────────────

local function get_item_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return name:lower()
end

local function is_item_muted(item)
  return reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1
end

local function is_track_silenced(track)
  if reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1 then return true end
  -- Check if any track is soloed; if so, non-soloed tracks are silenced
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0 then
      return reaper.GetMediaTrackInfo_Value(track, "I_SOLO") == 0
    end
  end
  return false
end

local function get_item_pos(item)
  return reaper.GetMediaItemInfo_Value(item, "D_POSITION")
end

local function get_item_len(item)
  return reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
end

local EXTSTATE_SECTION = "ScheduledLooper"

local function set_track_xfade(track)
  local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
  local xf = reaper.gmem_read(200 + idx)
  if xf > 0 then
    PRE_ROLL = xf; POST_ROLL = xf
    reaper.SetProjExtState(0, EXTSTATE_SECTION, "xfade_" .. idx, tostring(xf))
  else
    local _, val = reaper.GetProjExtState(0, EXTSTATE_SECTION, "xfade_" .. idx)
    xf = tonumber(val)
    if xf and xf > 0 then PRE_ROLL = xf; POST_ROLL = xf end
  end
end

-- ─── Track scanning ─────────────────────────────────────────────────────────

local function scan_track(track)
  local num_items = reaper.CountTrackMediaItems(track)
  local entries = {}
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local name = get_item_name(item)
    if name == "rec" then
      entries[#entries + 1] = { type = "rec", item = item }
    elseif name:find("play") then
      entries[#entries + 1] = { type = "play", item = item }
    end
  end

  local track_groups = {}
  local current_group = nil
  for _, entry in ipairs(entries) do
    if entry.type == "rec" then
      current_group = { rec_item = entry.item, play_items = {}, track = track }
      track_groups[#track_groups + 1] = current_group
    elseif entry.type == "play" and current_group then
      current_group.play_items[#current_group.play_items + 1] = entry.item
    end
  end
  return track_groups
end

local function scan_all_tracks()
  local new_data = {}
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    local groups = scan_track(track)
    if #groups > 0 then
      -- Preserve current index if track already had data
      local old = track_data[track]
      new_data[track] = {
        groups = groups,
        current = old and old.current or 1,
        play_current = old and old.play_current or 1,
        rec_buf = old and old.rec_buf or 0,
        play_buf = old and old.play_buf or 0,
        exported = old and old.exported or false,
        cleared = old and old.cleared or false,
        rec_exported = old and old.rec_exported or false,
        group_exports = old and old.group_exports or {},
      }
    end
  end
  track_data = new_data
end

-- ─── JSFX management ───────────────────────────────────────────────────────

-- Auto-sync JSFX from script directory to Effects folder so there's one source of truth
do
  local info = debug.getinfo(1, "S")
  local script_dir = info.source:match("@?(.*[\\/])")
  local dst_dir = reaper.GetResourcePath() .. "/Effects/Ostertoaster"
  reaper.RecursiveCreateDirectory(dst_dir, 0)
  for _, name in ipairs({"Timeline Looper.jsfx", "Timeline Looper Input.jsfx", "Timeline Looper Sum.jsfx"}) do
    local f_in = io.open(script_dir .. name, "rb")
    if f_in then
      local content = f_in:read("*a")
      f_in:close()
      local f_out = io.open(dst_dir .. "/" .. name, "wb")
      if f_out then f_out:write(content); f_out:close() end
    end
  end
end

local JSFX_ADD_NAME = "JS:Ostertoaster/Timeline Looper"
local INPUT_JSFX_NAME = "JS:Ostertoaster/Timeline Looper Input"
local SUM_JSFX_NAME = "JS:Ostertoaster/Timeline Looper Sum"
local MAX_FX_SLOTS = 8 -- max per-clip FX channel pairs (matches JSFX spl0-spl15)
local FX_BYPASS_MARGIN = 0.5 -- enable FX this many seconds before clip starts / after clip ends
local jsfx_managed = {}
local mic_track = nil -- single mic track for input capture
-- Per-track FX container state: keyed by track pointer
--   .container_idx = FX index of container on track (-1 if none)
--   .chain_fingerprints = { [slot] = "fp_string" } -- what's currently mirrored
--   .chain_enabled = { [slot] = bool } -- bypass state
local fx_container_state = {}

local function find_input_jsfx(track)
  -- Search regular FX chain
  local count = reaper.TrackFX_GetCount(track)
  for i = 0, count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:lower():find("timeline looper input") then return i end
  end
  -- Migrate from input FX chain if found there (old installs)
  local rec_count = reaper.TrackFX_GetRecCount(track)
  for i = 0, rec_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, 0x1000000 + i, "")
    if name and name:lower():find("timeline looper input") then
      reaper.TrackFX_Delete(track, 0x1000000 + i)
      local fx_idx = reaper.TrackFX_AddByName(track, INPUT_JSFX_NAME, false, -1)
      return fx_idx
    end
  end
  return -1
end

local function find_mic_track_by_guid()
  local _, guid = reaper.GetProjExtState(0, EXTSTATE_SECTION, "mic_track_guid")
  if not guid or guid == "" then return nil end
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    local tguid = reaper.GetTrackGUID(track)
    if tguid == guid then return track end
  end
  return nil
end

local function save_mic_track_guid(track)
  local guid = reaper.GetTrackGUID(track)
  reaper.SetProjExtState(0, EXTSTATE_SECTION, "mic_track_guid", guid)
end

local function ensure_mic_track()
  -- Find existing mic track by saved GUID first, then fall back to JSFX detection
  mic_track = find_mic_track_by_guid()
  if not mic_track then
    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
      local track = reaper.GetTrack(0, t)
      if find_input_jsfx(track) >= 0 then
        mic_track = track
        break
      end
    end
  end

  if mic_track then
    -- Ensure Input JSFX is on the track (may have been removed on cleanup)
    if find_input_jsfx(mic_track) < 0 then
      reaper.TrackFX_AddByName(mic_track, INPUT_JSFX_NAME, false, -1)
    end
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECARM", 1)
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMON", 1)
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMODE", 2)
    reaper.SetMediaTrackInfo_Value(mic_track, "B_MAINSEND", 0)
    save_mic_track_guid(mic_track)
    return mic_track
  end

  -- Create mic track at position 0
  reaper.PreventUIRefresh(1)
  reaper.InsertTrackAtIndex(0, false)
  mic_track = reaper.GetTrack(0, 0)
  reaper.GetSetMediaTrackInfo_String(mic_track, "P_NAME", "Mic", true)
  reaper.SetMediaTrackInfo_Value(mic_track, "I_CUSTOMCOLOR", reaper.ColorToNative(0xDE, 0x83, 0x83) | 0x1000000)
  local fx_idx = reaper.TrackFX_AddByName(mic_track, INPUT_JSFX_NAME, false, -1)
  if fx_idx < 0 then
    reaper.ShowMessageBox("Could not add Timeline Looper Input JSFX", SCRIPT_NAME, 0)
  end
  reaper.SetMediaTrackInfo_Value(mic_track, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMON", 1)
  reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMODE", 2)
  local cur_input = reaper.GetMediaTrackInfo_Value(mic_track, "I_RECINPUT")
  if cur_input < 0 or cur_input >= 4096 then
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECINPUT", 1024)
  end
  reaper.SetMediaTrackInfo_Value(mic_track, "B_MAINSEND", 0)
  save_mic_track_guid(mic_track)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return mic_track
end

local function cleanup_mic_track()
  if mic_track and reaper.ValidatePtr(mic_track, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECARM", 0)
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMON", 0)
    -- Remove the Input JSFX
    local fx = find_input_jsfx(mic_track)
    if fx >= 0 then
      reaper.TrackFX_Delete(mic_track, fx)
    end
  end
  mic_track = nil
end

-- Remove all mirrored FX from a track (everything after the JSFX at index 0)
local function remove_mirrored_fx(track)
  for i = reaper.TrackFX_GetCount(track) - 1, 1, -1 do
    reaper.TrackFX_Delete(track, i)
  end
  fx_container_state[track] = nil
end

local function restore_track_state()
  cleanup_mic_track()
  -- Remove mirrored FX from all JSFX tracks and reset channel counts
  reaper.PreventUIRefresh(1)
  for track in pairs(fx_container_state) do
    if reaper.ValidatePtr(track, "MediaTrack*") then
      remove_mirrored_fx(track)
      reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 2)
    end
  end
  fx_container_state = {}
  reaper.PreventUIRefresh(-1)
end

local function find_jsfx(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:lower():find("timeline looper")
      and not name:lower():find("timeline looper input") then
      return i
    end
  end
  return -1
end

-- ─── Item FX mirroring (per-clip FX on track chain with pin routing) ──────

-- Build a fingerprint of FX names only (structural changes trigger rebuild)
local function get_item_fx_fingerprint(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil end
  local count = reaper.TakeFX_GetCount(take)
  if count == 0 then return nil end
  local parts = {}
  for i = 0, count - 1 do
    local _, name = reaper.TakeFX_GetFXName(take, i, "")
    parts[#parts + 1] = name or "?"
  end
  return table.concat(parts, "|")
end

-- Sync parameter values and envelopes from take FX to mirrored track FX
-- Hash envelope points into a compact string for change detection
local function hash_envelope(env, n_pts)
  if n_pts == 0 then return "" end
  local parts = {}
  for i = 0, n_pts - 1 do
    local _, t, v, sh, tn = reaper.GetEnvelopePoint(env, i)
    parts[#parts + 1] = string.format("%.6f:%.6f:%d:%.4f", t, v, sh, tn)
  end
  return table.concat(parts, ",")
end

local function sync_fx_params(track, play_items)
  local state = fx_container_state[track]
  if not state or not state.slot_fx_indices then return end
  if not state.env_hashes then state.env_hashes = {} end

  -- Defer sync while left mouse button is held (user dragging envelope/slider)
  if reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) ~= 0 then return end

  for slot, info in pairs(state.slot_fx_indices) do
    local item = play_items[slot + 1]
    if not item then goto next_slot end
    local take = reaper.GetActiveTake(item)
    if not take then goto next_slot end

    local play_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local play_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if playrate <= 0 then playrate = 1.0 end

    local take_fx_count = reaper.TakeFX_GetCount(take)
    for fi = 0, take_fx_count - 1 do
      local track_fx_idx = info.first + fi
      if track_fx_idx >= reaper.TrackFX_GetCount(track) then break end

      -- Sync static parameter values (skip params with take envelopes and
      -- skip the Bypass param — bypass is managed by update_fx_bypass)
      local np = reaper.TakeFX_GetNumParams(take, fi)
      for p = 0, np - 1 do
        local _, pname = reaper.TakeFX_GetParamName(take, fi, p, "")
        if pname ~= "Bypass" then
          local take_env = reaper.TakeFX_GetEnvelope(take, fi, p, false)
          if not take_env or reaper.CountEnvelopePoints(take_env) == 0 then
            local tv = reaper.TakeFX_GetParam(take, fi, p)
            local fv = reaper.TrackFX_GetParam(track, track_fx_idx, p)
            if math.abs(tv - fv) > 0.0001 then
              reaper.TrackFX_SetParam(track, track_fx_idx, p, tv)
            end
          end
        end
      end

      -- Sync take FX parameter envelopes (only when changed)
      local hash_key = slot .. ":" .. fi
      if not state.env_hashes[hash_key] then state.env_hashes[hash_key] = {} end

      for p = 0, np - 1 do
        local take_env = reaper.TakeFX_GetEnvelope(take, fi, p, false)
        local take_pts = take_env and reaper.CountEnvelopePoints(take_env) or 0
        local new_hash = take_env and hash_envelope(take_env, take_pts) or ""

        if new_hash ~= (state.env_hashes[hash_key][p] or "") then
          state.env_hashes[hash_key][p] = new_hash

          if take_pts > 0 then
            local track_env = reaper.GetFXEnvelope(track, track_fx_idx, p, true)
            if track_env then
              -- Hide the track envelope lane (active but invisible)
              local _, echunk = reaper.GetEnvelopeStateChunk(track_env, "", false)
              if echunk:find("VIS 1") then
                echunk = echunk:gsub("VIS 1", "VIS 0")
                reaper.SetEnvelopeStateChunk(track_env, echunk, false)
              end
              local env_start = play_start - 0.01
              local env_end = play_start + play_len + 0.01
              reaper.DeleteEnvelopePointRange(track_env, env_start, env_end)
              for pt = 0, take_pts - 1 do
                local _, pt_time, pt_val, pt_shape, pt_tension = reaper.GetEnvelopePoint(take_env, pt)
                local proj_time = play_start + pt_time / playrate
                if proj_time <= play_start + play_len then
                  reaper.InsertEnvelopePoint(track_env, proj_time, pt_val, pt_shape, pt_tension, false, true)
                end
              end
              reaper.Envelope_SortPoints(track_env)
            end
          else
            local track_env = reaper.GetFXEnvelope(track, track_fx_idx, p, false)
            if track_env then
              local env_start = play_start - 0.01
              local env_end = play_start + play_len + 0.01
              reaper.DeleteEnvelopePointRange(track_env, env_start, env_end)
            end
          end
        end
      end
    end
    ::next_slot::
  end
end

local function remove_all_jsfx()
  reaper.PreventUIRefresh(1)
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    for i = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
      local _, name = reaper.TrackFX_GetFXName(track, i, "")
      if name and name:lower():find("timeline looper")
        and not name:lower():find("timeline looper input") then
        -- Delete this and everything after it (mirrored FX)
        for j = reaper.TrackFX_GetCount(track) - 1, i, -1 do
          reaper.TrackFX_Delete(track, j)
        end
        break
      end
    end
    -- Reset channel count
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 2)
  end
  jsfx_managed = {}
  fx_container_state = {}
  reaper.PreventUIRefresh(-1)
end

-- Set pin mappings on a track FX so it reads from and outputs to a specific
-- stereo channel pair (keeps each clip's audio on its own pair)
local function set_fx_pin_mappings(track, fx_idx, clip_slot)
  local ch = clip_slot * 2 -- channel pair (0-based)
  reaper.TrackFX_SetPinMappings(track, fx_idx, 0, 0, 1 << ch, 0)       -- in L
  reaper.TrackFX_SetPinMappings(track, fx_idx, 0, 1, 1 << (ch + 1), 0) -- in R
  reaper.TrackFX_SetPinMappings(track, fx_idx, 1, 0, 1 << ch, 0)       -- out L
  reaper.TrackFX_SetPinMappings(track, fx_idx, 1, 1, 1 << (ch + 1), 0) -- out R
end

-- Sync mirrored FX on a track based on its current play clips.
-- Places take FX copies as individual track FX after the JSFX, each with
-- pin mappings to process only its clip's stereo channel pair.
-- Called during scan (every ~1s), not every tick.
local function sync_fx_container(track, play_items)
  local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
  if not play_items or #play_items == 0 then
    remove_mirrored_fx(track)
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 2)
    reaper.gmem_write(950 + track_idx, 0)
    return
  end

  -- Check if any play item has take FX
  local any_fx = false
  for _, item in ipairs(play_items) do
    if get_item_fx_fingerprint(item) then any_fx = true; break end
  end

  if not any_fx then
    remove_mirrored_fx(track)
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 2)
    reaper.gmem_write(950 + track_idx, 0)
    return
  end

  -- Build the new fingerprint map
  local new_fps = {}
  local max_slots = math.min(#play_items, MAX_FX_SLOTS)
  for slot = 0, max_slots - 1 do
    new_fps[slot] = get_item_fx_fingerprint(play_items[slot + 1])
  end

  -- Check if anything changed
  local state = fx_container_state[track]
  if state then
    local changed = false
    for slot = 0, max_slots - 1 do
      if state.chain_fingerprints[slot] ~= new_fps[slot] then changed = true; break end
    end
    -- Also check if slot count changed
    if not changed then
      for slot in pairs(state.chain_fingerprints) do
        if slot >= max_slots then changed = true; break end
      end
    end
    if not changed then
      -- No FX changes, just ensure multichan mode
      reaper.gmem_write(950 + track_idx, 1)
      return
    end
  end

  -- Rebuild: remove old mirrored FX, re-add
  reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 16)
  remove_mirrored_fx(track)

  state = { chain_fingerprints = {}, chain_enabled = {}, slot_fx_indices = {}, needs_sync = true }
  fx_container_state[track] = state

  -- For each clip slot with take FX, copy the FX to the track chain
  for slot = 0, max_slots - 1 do
    local item = play_items[slot + 1]
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeFX_GetCount(take) > 0 then
      local fx_count = reaper.TakeFX_GetCount(take)
      local first_fx_idx = reaper.TrackFX_GetCount(track)
      -- Copy each take FX to the end of the track chain
      for fi = 0, fx_count - 1 do
        local dest = reaper.TrackFX_GetCount(track)
        reaper.TakeFX_CopyToTrack(take, fi, track, dest, false)
      end
      -- Set pin mappings on all FX in this slot to their clip's channel pair
      for fi = first_fx_idx, first_fx_idx + fx_count - 1 do
        set_fx_pin_mappings(track, fi, slot)
      end
      state.chain_fingerprints[slot] = new_fps[slot]
      state.chain_enabled[slot] = false
      state.slot_fx_indices[slot] = { first = first_fx_idx, count = fx_count }
      -- Start bypassed
      for fi = first_fx_idx, first_fx_idx + fx_count - 1 do
        reaper.TrackFX_SetEnabled(track, fi, false)
      end
    end
  end

  -- Add summing JSFX at the end (sums ch 2-15 into ch 0-1)
  local sum_idx = reaper.TrackFX_AddByName(track, SUM_JSFX_NAME, false, -1)
  if sum_idx >= 0 then
    state.sum_fx_idx = sum_idx
  end

  reaper.gmem_write(950 + track_idx, 1)
end

-- Enable/disable mirrored FX based on which clips are currently active
local function update_fx_bypass(track, active_clips)
  local state = fx_container_state[track]
  if not state then return end

  for slot = 0, MAX_FX_SLOTS - 1 do
    local slot_info = state.slot_fx_indices and state.slot_fx_indices[slot]
    if slot_info then
      local should_enable = active_clips[slot] or false
      if state.chain_enabled[slot] ~= should_enable then
        for fi = slot_info.first, slot_info.first + slot_info.count - 1 do
          reaper.TrackFX_SetEnabled(track, fi, should_enable)
        end
        state.chain_enabled[slot] = should_enable
      end
    end
  end
end

-- Find the audio sibling track (same parent folder as JSFX track, no JSFX on it)
local function find_audio_sibling(jsfx_track)
  local parent = reaper.GetParentTrack(jsfx_track)
  if not parent then return nil end
  local parent_idx = reaper.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER") - 1
  local num_tracks = reaper.CountTracks(0)
  local level = 0
  for i = parent_idx + 1, num_tracks - 1 do
    local t = reaper.GetTrack(0, i)
    local d = reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    if level == 0 and t ~= jsfx_track and find_jsfx(t) < 0 then
      return t
    end
    level = level + d
    if level < 0 then break end
  end
  return nil
end

-- Ensure JSFX track is inside a parent folder with an audio sibling:
--   Parent Track (volume/pan/effects)
--     JSFX Track (rec/play MIDI items + JSFX)
--     Audio Track (exported items)
local function ensure_track_hierarchy(jsfx_track)
  local audio = find_audio_sibling(jsfx_track)
  if audio then return audio end

  reaper.PreventUIRefresh(1)
  local jsfx_idx = reaper.GetMediaTrackInfo_Value(jsfx_track, "IP_TRACKNUMBER") - 1
  local jsfx_depth = reaper.GetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH")
  local parent = reaper.GetParentTrack(jsfx_track)

  if not parent then
    reaper.InsertTrackAtIndex(jsfx_idx, false)
    parent = reaper.GetTrack(0, jsfx_idx)
    reaper.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
    local _, jsfx_name = reaper.GetSetMediaTrackInfo_String(jsfx_track, "P_NAME", "", false)
    reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", jsfx_name or "Looper", true)
    reaper.SetMediaTrackInfo_Value(parent, "I_CUSTOMCOLOR", reaper.ColorToNative(0x83, 0xB7, 0xDE) | 0x1000000)
    reaper.GetSetMediaTrackInfo_String(jsfx_track, "P_NAME", "JSFX", true)
    jsfx_idx = reaper.GetMediaTrackInfo_Value(jsfx_track, "IP_TRACKNUMBER") - 1
    jsfx_depth = reaper.GetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH")
  end

  if jsfx_depth == 1 then
    reaper.SetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH", 0)
    audio = find_audio_sibling(jsfx_track)
    if audio then
      reaper.PreventUIRefresh(-1)
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
      return audio
    end
    jsfx_idx = reaper.GetMediaTrackInfo_Value(jsfx_track, "IP_TRACKNUMBER") - 1
    jsfx_depth = reaper.GetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH")
  end

  local audio_depth = -1
  if jsfx_depth < 0 then
    audio_depth = jsfx_depth
    reaper.SetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH", 0)
  end
  reaper.InsertTrackAtIndex(jsfx_idx + 1, false)
  audio = reaper.GetTrack(0, jsfx_idx + 1)
  reaper.SetMediaTrackInfo_Value(audio, "I_FOLDERDEPTH", audio_depth)
  reaper.GetSetMediaTrackInfo_String(audio, "P_NAME", "Audio", true)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return audio
end

local function ensure_jsfx_on_tracks()
  reaper.PreventUIRefresh(1)
  for track in pairs(track_data) do
    -- Ensure parent folder + audio sibling FIRST (may shift track indices)
    ensure_track_hierarchy(track)

    if not jsfx_managed[track] then
      -- Check if JSFX already exists (query only, don't add)
      local fx_idx = reaper.TrackFX_AddByName(track, JSFX_ADD_NAME, false, 0)
      local is_new = fx_idx < 0
      if is_new then
        fx_idx = reaper.TrackFX_AddByName(track, JSFX_ADD_NAME, false, -1)
      end
      if fx_idx >= 0 then
        if fx_idx > 0 then
          reaper.TrackFX_CopyToTrack(track, fx_idx, track, 0, true)
          fx_idx = 0
        end
        -- Get track_idx AFTER hierarchy changes (index may have shifted)
        local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
        reaper.TrackFX_SetParam(track, fx_idx, 0, track_idx)
        -- Only restore crossfade for newly added JSFX (existing ones keep REAPER-persisted value)
        if is_new then
          local _, saved_xf = reaper.GetProjExtState(0, EXTSTATE_SECTION, "xfade_" .. track_idx)
          local xf_sec = tonumber(saved_xf)
          if xf_sec and xf_sec > 0 then
            reaper.TrackFX_SetParam(track, fx_idx, 1, xf_sec * 1000)
          end
        end
        -- Show Crossfade slider (param 1) in TCP
        if reaper.SNM_AddTCPFXParm then
          reaper.SNM_AddTCPFXParm(track, fx_idx, 1)
        end
      end
      jsfx_managed[track] = true
    end
    -- Disarm JSFX tracks (mic track handles all input)
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 0)
    -- Disable anticipative FX so track processes in sync with mic track's gmem writes
    local perf = reaper.GetMediaTrackInfo_Value(track, "I_PERFFLAGS")
    reaper.SetMediaTrackInfo_Value(track, "I_PERFFLAGS", perf | 2)
  end
  reaper.PreventUIRefresh(-1)
end

-- ─── gmem sync (Lua → JSFX) ─────────────────────────────────────────────────

local function write_gmem()
  for track, td in pairs(track_data) do
    local rec_group = td.groups[td.current]
    if not rec_group then goto continue end
    local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
    local base = 1000 + track_idx * 100

    -- Write rec region from current (rec) group
    local rec_start = get_item_pos(rec_group.rec_item)
    local rec_end = rec_start + get_item_len(rec_group.rec_item)
    reaper.gmem_write(base, rec_start)
    reaper.gmem_write(base + 1, rec_end)
    reaper.gmem_write(base + 2, is_item_muted(rec_group.rec_item) and 1 or 0)

    -- Write play regions from play group (may differ from rec group)
    local play_group = td.groups[td.play_current]
    if play_group then
      local max_play = math.min(#play_group.play_items, 15)
      reaper.gmem_write(base + 3, max_play)
      for j = 1, max_play do
        local play_item = play_group.play_items[j]
        local pbase = base + 4 + (j - 1) * 4
        local ps = get_item_pos(play_item)
        reaper.gmem_write(pbase, ps)
        reaper.gmem_write(pbase + 1, ps + get_item_len(play_item))
        local flags = 0
        if is_item_muted(play_item) then flags = flags + 1 end
        if get_item_name(play_item):find("rev") then flags = flags + 2 end
        reaper.gmem_write(pbase + 2, flags)
        -- Playrate from play item's take
        local take = reaper.GetActiveTake(play_item)
        local playrate = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0
        reaper.gmem_write(pbase + 3, playrate)

        -- Write volume envelope points for this play clip
        -- ENV_BASE = 5000, per track: 5000 + track_idx * 200, per clip: j * 9
        local env_base = 5000 + track_idx * 200 + (j - 1) * 9
        local env = take and reaper.GetTakeEnvelopeByName(take, "Volume")
        if env then
          local n_pts = math.min(reaper.CountEnvelopePoints(env), 4)
          reaper.gmem_write(env_base, n_pts)
          for p = 0, n_pts - 1 do
            local _, pt_time, pt_val = reaper.GetEnvelopePoint(env, p)
            reaper.gmem_write(env_base + 1 + p * 2, pt_time)
            reaper.gmem_write(env_base + 2 + p * 2, pt_val)
          end
        else
          reaper.gmem_write(env_base, 0)
        end
        -- Write pan envelope points for this play clip
        -- PAN_ENV_BASE = 7000, per track: 7000 + track_idx * 200, per clip: j * 9
        local pan_env_base = 7000 + track_idx * 200 + (j - 1) * 9
        local pan_env = take and reaper.GetTakeEnvelopeByName(take, "Pan")
        if pan_env then
          local n_pts = math.min(reaper.CountEnvelopePoints(pan_env), 4)
          reaper.gmem_write(pan_env_base, n_pts)
          for p = 0, n_pts - 1 do
            local _, pt_time, pt_val = reaper.GetEnvelopePoint(pan_env, p)
            reaper.gmem_write(pan_env_base + 1 + p * 2, pt_time)
            reaper.gmem_write(pan_env_base + 2 + p * 2, pt_val)
          end
        else
          reaper.gmem_write(pan_env_base, 0)
        end
      end
    else
      reaper.gmem_write(base + 3, 0)
    end

    -- Write buffer assignments
    reaper.gmem_write(400 + track_idx, td.rec_buf)
    reaper.gmem_write(500 + track_idx, td.play_buf)
    ::continue::
  end
end

-- ─── Export logic ─────────────────────────────────────────────────────────────

local pending_export = nil
local export_queue = {}
local saved_edit_cursor = nil



local function get_pdc_samples(track)
  local total_pdc = 0
  -- Sum PDC from FX after the JSFX on this track
  local fx_count = reaper.TrackFX_GetCount(track)
  local jsfx_idx = -1
  for i = 0, fx_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i)
    if name and name:lower():find("timeline looper") then
      jsfx_idx = i
      break
    end
  end
  if jsfx_idx >= 0 then
    for i = jsfx_idx + 1, fx_count - 1 do
      local ok, val = reaper.TrackFX_GetNamedConfigParm(track, i, "pdc")
      if ok then total_pdc = total_pdc + (tonumber(val) or 0) end
    end
  end
  -- Walk up parent chain and sum all FX PDC on each parent track
  local parent = reaper.GetParentTrack(track)
  while parent do
    local pfx_count = reaper.TrackFX_GetCount(parent)
    for i = 0, pfx_count - 1 do
      local ok, val = reaper.TrackFX_GetNamedConfigParm(parent, i, "pdc")
      if ok then total_pdc = total_pdc + (tonumber(val) or 0) end
    end
    parent = reaper.GetParentTrack(parent)
  end
  return total_pdc
end

local function clear_group_audio(group)
  local audio_track = find_audio_sibling(group.track)
  if not audio_track then return end
  local ranges = {}
  local rs = get_item_pos(group.rec_item)
  ranges[#ranges + 1] = { rs - PRE_ROLL, rs + get_item_len(group.rec_item) + POST_ROLL }
  for _, play_item in ipairs(group.play_items) do
    local ps = get_item_pos(play_item)
    ranges[#ranges + 1] = { ps - PRE_ROLL, ps + get_item_len(play_item) + POST_ROLL }
  end
  local changed = false
  reaper.PreventUIRefresh(1)
  for i = reaper.CountTrackMediaItems(audio_track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(audio_track, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      for _, r in ipairs(ranges) do
        if ipos >= r[1] and ipos < r[2] then
          reaper.DeleteTrackMediaItem(audio_track, item)
          changed = true
          break
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  if changed then reaper.UpdateArrange() end
end


local function compute_export_params(src_filename, rec_len, saved_prl)
  local srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if srate == 0 then srate = 44100 end
  local prl_frames = saved_prl or 0
  local actual_pre = prl_frames > 0 and (prl_frames / srate) or 0
  local probe_src = reaper.PCM_Source_CreateFromFile(src_filename)
  local src_len = 0
  if probe_src then
    src_len = reaper.GetMediaSourceLength(probe_src)
    reaper.PCM_Source_Destroy(probe_src)
  end
  local actual_post = src_len > 0 and math.max(0, src_len - rec_len - actual_pre) or POST_ROLL
  -- Halve extensions so overlap = crossfade param, not 2x
  return {
    file = src_filename, rec_len = rec_len,
    actual_pre = actual_pre / 2, actual_post = actual_post / 2,
    src_offset = actual_pre / 2,
    src_len = src_len,
  }
end

-- Linearly interpolate envelope value between two points at a given time
local function lerp_env_value(t, pts)
  if #pts == 0 then return 1.0 end
  if t <= pts[1].t then return pts[1].v end
  if t >= pts[#pts].t then return pts[#pts].v end
  for i = 2, #pts do
    if t <= pts[i].t then
      local p0, p1 = pts[i-1], pts[i]
      local frac = (p1.t == p0.t) and 0 or (t - p0.t) / (p1.t - p0.t)
      return p0.v + frac * (p1.v - p0.v)
    end
  end
  return pts[#pts].v
end

-- Copy item envelopes from source to destination, slicing to the copy's time window.
-- src_time_offset = time in source item that maps to destination item start (can be negative).
-- dst_length = destination item's timeline length.
-- Interpolates boundary values so envelope ramps are preserved across loop copies.
local function copy_item_envelopes(src_item, dst_item, src_time_offset, dst_length)
  local _, src_chunk = reaper.GetItemStateChunk(src_item, "", false)
  local _, dst_chunk = reaper.GetItemStateChunk(dst_item, "", false)

  -- Extract envelope blocks from source (top-level blocks in ITEM chunk)
  local env_blocks = {}
  local lines = {}
  for line in src_chunk:gmatch("[^\r\n]+") do lines[#lines + 1] = line end

  local i = 1
  while i <= #lines do
    if lines[i]:match("^<[A-Z_]*ENV") then
      local block = { lines[i] }
      local depth = 1
      i = i + 1
      while i <= #lines and depth > 0 do
        block[#block + 1] = lines[i]
        if lines[i]:match("^%s*<") then depth = depth + 1 end
        if lines[i]:match("^%s*>%s*$") then depth = depth - 1 end
        i = i + 1
      end
      env_blocks[#env_blocks + 1] = block
    else
      i = i + 1
    end
  end

  if #env_blocks == 0 then return end

  local win_start = src_time_offset
  local win_end = src_time_offset + dst_length

  -- Slice each envelope block to the copy's time window with interpolated boundaries
  local adjusted_blocks = {}
  for _, block in ipairs(env_blocks) do
    -- Collect all PT entries with their original data
    local pts = {}
    local header_lines = {}
    local closing = nil
    for _, line in ipairs(block) do
      local time_str, val_str, rest = line:match("^PT ([%d%.%-e]+) ([%d%.%-e]+) (.*)")
      if time_str then
        pts[#pts + 1] = { t = tonumber(time_str), v = tonumber(val_str), rest = rest, line = line }
      elseif line:match("^%s*>%s*$") then
        closing = line
      else
        header_lines[#header_lines + 1] = line
      end
    end

    if #pts == 0 then goto next_block end

    -- Build sliced points for this copy
    local new_pts = {}

    -- Add interpolated boundary point at window start if needed
    local first_in = nil
    for _, p in ipairs(pts) do
      if p.t >= win_start then first_in = p; break end
    end
    if first_in and first_in.t > win_start + 0.001 then
      local v = lerp_env_value(win_start, pts)
      new_pts[#new_pts + 1] = { t = 0, v = v, rest = "0" }
    end

    -- Add original points that fall within window (shifted to dst time)
    for _, p in ipairs(pts) do
      if p.t >= win_start - 0.001 and p.t <= win_end + 0.001 then
        new_pts[#new_pts + 1] = {
          t = math.max(0, p.t - win_start),
          v = p.v,
          rest = p.rest,
        }
      end
    end

    -- Add interpolated boundary point at window end if needed
    local last_in = nil
    for j = #pts, 1, -1 do
      if pts[j].t <= win_end then last_in = pts[j]; break end
    end
    if last_in and last_in.t < win_end - 0.001 then
      local v = lerp_env_value(win_end, pts)
      new_pts[#new_pts + 1] = { t = dst_length, v = v, rest = "0" }
    end

    if #new_pts == 0 then goto next_block end

    -- Rebuild the envelope block
    local adj = {}
    for _, hl in ipairs(header_lines) do adj[#adj + 1] = hl end
    for _, np in ipairs(new_pts) do
      adj[#adj + 1] = string.format("PT %.10f %.10f %s", np.t, np.v, np.rest)
    end
    adj[#adj + 1] = closing or ">"
    adjusted_blocks[#adjusted_blocks + 1] = table.concat(adj, "\n")
    ::next_block::
  end

  if #adjusted_blocks == 0 then return end

  -- Insert adjusted envelope blocks before the final > of the destination item chunk
  local insert_text = table.concat(adjusted_blocks, "\n") .. "\n"
  dst_chunk = dst_chunk:gsub("\n>%s*$", "\n" .. insert_text .. ">")
  reaper.SetItemStateChunk(dst_item, dst_chunk, false)
end

local function place_single_item(audio_track, position, length, ep, is_reverse, playrate)
  playrate = playrate or 1.0
  local new_item = reaper.AddMediaItemToTrack(audio_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  local new_source = reaper.PCM_Source_CreateFromFile(ep.file)
  reaper.SetMediaItemTake_Source(new_take, new_source)
  reaper.SetMediaItemInfo_Value(new_item, "B_LOOPSRC", 0)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", ep.src_offset or 0)
  -- Playrate (no preserve pitch — JSFX can't pitch-stretch live playback)
  if playrate ~= 1.0 then
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", playrate)
  end
  reaper.SetMediaItemTakeInfo_Value(new_take, "B_PPITCH", 0)
  -- Crossfade and snap offset scaled to timeline time
  local eff_pre = ep.actual_pre / playrate
  local eff_post = ep.actual_post / playrate
  local xfade = eff_pre + eff_post
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", xfade)
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", xfade)
  reaper.SetMediaItemInfo_Value(new_item, "D_SNAPOFFSET", eff_pre)
  if is_reverse then
    reaper.SetMediaItemSelected(new_item, true)
    reaper.Main_OnCommand(41051, 0) -- Toggle take reverse
    reaper.SetMediaItemSelected(new_item, false)
  end
  return new_item
end

local function place_rec_audio(group, audio_track, ep)
  if is_item_muted(group.rec_item) then return end
  local rec_pos = get_item_pos(group.rec_item)
  local length = ep.rec_len + ep.actual_pre + ep.actual_post
  local item = place_single_item(audio_track, rec_pos - ep.actual_pre, length, ep, false)
  -- Rec is the first item — fade-in only covers the pre-roll, not full crossfade
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", ep.actual_pre)
end

local function place_play_item_audio(audio_track, play_item, ep)
  if is_item_muted(play_item) then return end
  local play_pos = get_item_pos(play_item)
  local play_len = get_item_len(play_item)
  local play_end = play_pos + play_len
  local is_reverse = get_item_name(play_item):find("rev") ~= nil

  -- Read playrate from play item's take
  local take = reaper.GetActiveTake(play_item)
  local playrate = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0

  -- Effective dimensions in timeline time (scaled by playrate)
  local eff_rec = ep.rec_len / playrate
  local eff_pre = ep.actual_pre / playrate
  local eff_post = ep.actual_post / playrate

  local ratio = play_len / eff_rec
  local n_copies = math.ceil(ratio - 1e-9)
  local items = {}
  for c = 0, n_copies - 1 do
    local grid_pos = play_pos + c * eff_rec
    local remaining = play_end - grid_pos
    local copy_main = math.min(eff_rec, remaining)
    local item_pos = grid_pos - eff_pre
    local item_len = copy_main + eff_pre + eff_post
    local item
    if is_reverse and copy_main < eff_rec then
      -- Create at full length so reverse operates on full source, then trim
      local full_len = eff_rec + eff_pre + eff_post
      item = place_single_item(audio_track, item_pos, full_len, ep, true, playrate)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_len)
    else
      item = place_single_item(audio_track, item_pos, item_len, ep, is_reverse, playrate)
    end
    -- Last copy has nothing after it — fade-out only covers the post-roll
    if c == n_copies - 1 then
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", eff_post)
    end
    items[#items + 1] = item
  end
  if #items > 1 then
    -- Find highest existing group ID and use next one
    local max_id = 0
    for i = 0, reaper.CountMediaItems(0) - 1 do
      local gi = reaper.GetMediaItemInfo_Value(reaper.GetMediaItem(0, i), "I_GROUPID")
      if gi > max_id then max_id = gi end
    end
    local group_id = max_id + 1
    for _, item in ipairs(items) do
      reaper.SetMediaItemInfo_Value(item, "I_GROUPID", group_id)
    end
  end
  -- Copy item envelopes and take FX from play clip to exported audio items
  local src_take = reaper.GetActiveTake(play_item)
  local src_fx_count = src_take and reaper.TakeFX_GetCount(src_take) or 0
  for ci, item in ipairs(items) do
    local src_offset = (ci - 1) * eff_rec - eff_pre
    local dst_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    copy_item_envelopes(play_item, item, src_offset, dst_length)
    -- Copy take FX chain and their parameter envelopes (sliced per loop copy)
    if src_fx_count > 0 then
      local dst_take = reaper.GetActiveTake(item)
      if dst_take then
        for fi = 0, src_fx_count - 1 do
          reaper.TakeFX_CopyToTake(src_take, fi, dst_take, fi, false)
          -- Slice FX parameter envelopes to this copy's time window
          local np = reaper.TakeFX_GetNumParams(src_take, fi)
          for p = 0, np - 1 do
            local src_env = reaper.TakeFX_GetEnvelope(src_take, fi, p, false)
            if src_env and reaper.CountEnvelopePoints(src_env) > 0 then
              -- Collect source points
              local pts = {}
              for pt = 0, reaper.CountEnvelopePoints(src_env) - 1 do
                local _, pt_t, pt_v, pt_sh, pt_tn, pt_sel = reaper.GetEnvelopePoint(src_env, pt)
                pts[#pts + 1] = { t = pt_t, v = pt_v, sh = pt_sh, tn = pt_tn, sel = pt_sel }
              end
              -- Time window in source time for this loop copy
              local win_start = src_offset * playrate
              local win_end = win_start + dst_length * playrate
              -- Build sliced points
              local dst_env = reaper.TakeFX_GetEnvelope(dst_take, fi, p, true)
              if dst_env then
                -- Interpolated boundary at window start
                if #pts > 0 and pts[1].t < win_start then
                  local v = lerp_env_value(win_start, pts)
                  reaper.InsertEnvelopePoint(dst_env, 0, v, 0, 0, false, true)
                end
                -- Points within window, shifted to dst time
                for _, pt in ipairs(pts) do
                  if pt.t >= win_start - 0.001 and pt.t <= win_end + 0.001 then
                    local dst_t = math.max(0, (pt.t - win_start) / playrate)
                    reaper.InsertEnvelopePoint(dst_env, dst_t, pt.v, pt.sh, pt.tn, pt.sel, true)
                  end
                end
                -- Interpolated boundary at window end
                if #pts > 0 and pts[#pts].t > win_end then
                  local v = lerp_env_value(win_end, pts)
                  reaper.InsertEnvelopePoint(dst_env, dst_length, v, 0, 0, false, true)
                end
                reaper.Envelope_SortPoints(dst_env)
              end
            end
          end
        end
      end
    end
  end
end

local function queue_export(group, track, group_idx, export_buf, force)
  if not force and not export_enabled then return end
  local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
  local rec_buf_gmem = reaper.gmem_read(400 + track_idx)
  local prl = reaper.gmem_read(export_buf == rec_buf_gmem and (300 + track_idx) or (800 + track_idx))
  export_queue[#export_queue + 1] = {
    group = group,
    track_idx = track_idx,
    rec_start = get_item_pos(group.rec_item),
    prl_frames = prl,
    group_idx = group_idx,
    track = track,
    export_buf = export_buf,
  }
end


local function process_export()
  if not pending_export and #export_queue > 0 then
    local next_exp = table.remove(export_queue, 1)
    if not saved_edit_cursor then
      saved_edit_cursor = reaper.GetCursorPosition()
    end
    set_track_xfade(next_exp.group.track)
    reaper.Undo_BeginBlock()
    clear_group_audio(next_exp.group)
    -- Clean up leftover JSFX export items in this group's range on the control track
    local cleanup_start = next_exp.rec_start - PRE_ROLL
    local cleanup_end = next_exp.rec_start + get_item_len(next_exp.group.rec_item) + POST_ROLL
    for i = reaper.CountTrackMediaItems(next_exp.group.track) - 1, 0, -1 do
      local it = reaper.GetTrackMediaItem(next_exp.group.track, i)
      local take = reaper.GetActiveTake(it)
      if take and not reaper.TakeIsMIDI(take) then
        local it_pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if it_pos >= cleanup_start and it_pos < cleanup_end then
          reaper.DeleteTrackMediaItem(next_exp.group.track, it)
        end
      end
    end
    reaper.Undo_EndBlock("Timeline Looper: clear audio", -1)
    local audio_track = find_audio_sibling(next_exp.group.track)
    reaper.SetEditCurPos(next_exp.rec_start, false, false)
    reaper.gmem_write(600 + next_exp.track_idx, next_exp.export_buf)
    reaper.gmem_write(1, next_exp.track_idx + 1)
    reaper.gmem_write(0, next_exp.track_idx + 1) -- trigger = track_idx + 1
    pending_export = {
      group = next_exp.group, phase = "wait", tick = 0,
      audio_track = audio_track,
      prl_frames = next_exp.prl_frames,
      group_idx = next_exp.group_idx,
      track = next_exp.track,
    }
  end

  if not pending_export then return end
  local pe = pending_export

  if pe.phase == "wait" then
    pe.tick = pe.tick + 1
    if reaper.gmem_read(0) == 0 then
      pe.phase = "place"
    elseif pe.tick > 60 then
      pending_export = nil
      if #export_queue == 0 and saved_edit_cursor then
        reaper.SetEditCurPos(saved_edit_cursor, false, false)
        saved_edit_cursor = nil
      end
    end

  elseif pe.phase == "place" then
    set_track_xfade(pe.group.track)
    -- Re-check for audio track (JSFX export may have created it)
    if not pe.audio_track then
      pe.audio_track = find_audio_sibling(pe.group.track)
    end
    if pe.audio_track then
      local rec_len = get_item_len(pe.group.rec_item)
      -- Find the exported audio item near rec position (check both JSFX and audio track)
      local rec_start = get_item_pos(pe.group.rec_item)
      local rec_end = rec_start + rec_len
      local item, item_track
      local search_tracks = { pe.group.track, pe.audio_track }
      for _, st in ipairs(search_tracks) do
        for i = 0, reaper.CountTrackMediaItems(st) - 1 do
          local it = reaper.GetTrackMediaItem(st, i)
          local take = reaper.GetActiveTake(it)
          if take and not reaper.TakeIsMIDI(take) then
            local it_pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            if it_pos >= rec_start - PRE_ROLL and it_pos < rec_end + POST_ROLL then
              item = it
              item_track = st
              break
            end
          end
        end
        if item then break end
      end
      if item then
        local take = reaper.GetActiveTake(item)
        local source = take and reaper.GetMediaItemTake_Source(take)
        local src_filename = source and reaper.GetMediaSourceFileName(source, "")
        reaper.DeleteTrackMediaItem(item_track, item)
        if src_filename and src_filename ~= "" then
          -- Save export params for incremental placement
          local td = track_data[pe.track or pe.group.track]
          if td and pe.group_idx then
            local ep = compute_export_params(src_filename, rec_len, pe.prl_frames)
            td.group_exports[pe.group_idx] = {
              ep = ep,
              audio_track = pe.audio_track,
              rec_placed = false,
              plays_placed = {},
            }
          end
        end
      end
    end
    pending_export = nil
    if #export_queue == 0 and saved_edit_cursor then
      reaper.SetEditCurPos(saved_edit_cursor, false, false)
      saved_edit_cursor = nil
    end
  end
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local function looper_tick()
  if not script_running then return end

  -- Detect record mode transitions
  local is_recording = (reaper.GetPlayState() & 4) ~= 0
  if is_recording and not was_recording then
    last_play_state = 0  -- trigger play-start group reset on next tick
  end
  was_recording = is_recording

  -- Periodic rescan
  local now = reaper.time_precise()
  local needs_rescan = now - last_scan_time >= SCAN_INTERVAL
  if not needs_rescan then
    for _, td in pairs(track_data) do
      for _, g in ipairs(td.groups) do
        if not reaper.ValidatePtr(g.rec_item, "MediaItem*") then
          needs_rescan = true
          break
        end
        for _, pi in ipairs(g.play_items) do
          if not reaper.ValidatePtr(pi, "MediaItem*") then
            needs_rescan = true
            break
          end
        end
        if needs_rescan then break end
      end
      if needs_rescan then break end
    end
  end
  if needs_rescan then
    scan_all_tracks()
    -- Persist crossfade slider values to project data (read from gmem, always in seconds)
    for track in pairs(jsfx_managed) do
      if reaper.ValidatePtr(track, "MediaTrack*") then
        local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
        local xf = reaper.gmem_read(200 + idx)
        if xf > 0 then
          reaper.SetProjExtState(0, EXTSTATE_SECTION, "xfade_" .. idx, tostring(xf))
        end
        reaper.gmem_write(900 + idx, get_pdc_samples(track))
        -- Sync item FX for ALL play clips across ALL groups on this track
        local td = track_data[track]
        if td then
          local all_play_items = {}
          for _, g in ipairs(td.groups) do
            for _, pi in ipairs(g.play_items) do
              all_play_items[#all_play_items + 1] = pi
            end
          end
          reaper.PreventUIRefresh(1)
          sync_fx_container(track, all_play_items)
          sync_fx_params(track, all_play_items)
          reaper.PreventUIRefresh(-1)
        end
      end
    end
    last_scan_time = now
  end

  -- Detect mouse-up → force immediate param sync (outside normal scan interval)
  local mouse_down = reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) ~= 0
  if was_mouse_down and not mouse_down then
    reaper.PreventUIRefresh(1)
    for track in pairs(jsfx_managed) do
      if reaper.ValidatePtr(track, "MediaTrack*") then
        local td = track_data[track]
        if td then
          local all_play_items = {}
          for _, g in ipairs(td.groups) do
            for _, pi in ipairs(g.play_items) do
              all_play_items[#all_play_items + 1] = pi
            end
          end
          sync_fx_params(track, all_play_items)
        end
      end
    end
    reaper.PreventUIRefresh(-1)
  end
  was_mouse_down = mouse_down

  process_export()

  -- Update FX bypass based on cursor/play position (works when stopped, playing, or recording)
  if not is_recording then
    local pos
    local cur_play_state = reaper.GetPlayState()
    if cur_play_state > 0 then
      pos = reaper.GetPlayPosition()
    else
      pos = reaper.GetCursorPosition()
    end
    for track, td in pairs(track_data) do
      if fx_container_state[track] then
        local active_clips = {}
        local slot = 0
        for _, g in ipairs(td.groups) do
          for _, pi in ipairs(g.play_items) do
            if slot < MAX_FX_SLOTS and not is_item_muted(pi) then
              local ps = get_item_pos(pi)
              local pe = ps + get_item_len(pi)
              if pos >= ps - PRE_ROLL - FX_BYPASS_MARGIN and pos < pe + POST_ROLL + FX_BYPASS_MARGIN then
                active_clips[slot] = true
              end
            end
            slot = slot + 1
          end
        end
        update_fx_bypass(track, active_clips)
      end
    end
    reaper.defer(looper_tick)
    return
  end

  local play_state = reaper.GetPlayState()

  -- On play start: pick the right starting group for each track
  if last_play_state == 0 and play_state > 0 then
    local pos = reaper.GetPlayPosition()
    for track, td in pairs(track_data) do
      set_track_xfade(track)
      -- Find which group the playhead is in or approaching
      td.current = 1
      td.play_current = 1
      td.rec_buf = 0
      td.play_buf = 0
      td.exported = false
      td.cleared = false
      td.rec_exported = false
      td.rec_complete = false
      td.group_exports = {}
      for i, g in ipairs(td.groups) do
        local rec_end = get_item_pos(g.rec_item) + get_item_len(g.rec_item)
        if pos < rec_end + POST_ROLL then
          td.current = i
          td.play_current = i
          -- If playhead started well past the rec clip's start, skip this partial recording
          -- Use PRE_ROLL as tolerance so starting at/near the beginning still records
          local rec_start = get_item_pos(g.rec_item)
          if pos > rec_start + PRE_ROLL then
            td.rec_exported = true
            td.cleared = true
          end
          break
        end
        -- Past this group entirely — mark it as already done
        if i == #td.groups then
          td.current = i
          td.play_current = i
          td.exported = true
          td.rec_exported = true
          td.cleared = true
        end
      end
    end
  end

  -- During playback: advance groups and trigger exports
  if play_state > 0 then
    local pos = reaper.GetPlayPosition()
    reaper.Undo_BeginBlock()
    for track, td in pairs(track_data) do
      if is_track_silenced(track) then goto next_track end
      set_track_xfade(track)

      local group = td.groups[td.current]
      if not group then goto next_track end

      -- Clear old audio before playhead reaches rec region pre-roll
      -- Extra 0.2s margin ensures items are gone before the audio engine renders them
      -- Skip if rec item is muted (no new recording will replace old audio)
      if not td.cleared then
        local rec_start = get_item_pos(group.rec_item)
        if pos >= rec_start - PRE_ROLL - 0.2 then
          local rec_end = rec_start + get_item_len(group.rec_item)
          if pos < rec_end + POST_ROLL and not is_item_muted(group.rec_item) then
            clear_group_audio(group)
          end
          td.cleared = true
        end
      end

      -- Export recording early (after rec region + full buffer length has passed)
      -- The JSFX records using rpos = pos - pdc_sec, so we must wait an extra
      -- pdc_sec for the JSFX to finish writing the post-roll into the buffer
      if not td.rec_exported then
        local rec_start = get_item_pos(group.rec_item)
        local rec_end = rec_start + get_item_len(group.rec_item)
        if pos >= rec_end then td.rec_complete = true end
        local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
        local pdc_smp = reaper.gmem_read(900 + track_idx)
        local srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
        if srate == 0 then srate = 44100 end
        local pdc_sec = pdc_smp / srate
        if pos >= rec_end + PRE_ROLL + POST_ROLL + pdc_sec then
          if not is_item_muted(group.rec_item) then
            local buf_len = reaper.gmem_read(100 + track_idx)
            if buf_len > 0 then
              queue_export(group, track, td.current, td.rec_buf)
            end
          end
          td.rec_exported = true
        end
      end

      -- Advance rec group when playhead reaches next rec region
      -- Swap rec buffer so new recording doesn't overwrite play buffer
      local next_group = td.groups[td.current + 1]
      if next_group then
        local next_rec_start = get_item_pos(next_group.rec_item)
        if pos >= next_rec_start - PRE_ROLL - 0.1 then
          td.rec_buf = 1 - td.rec_buf  -- swap recording buffer
          td.current = td.current + 1
          td.cleared = false
          td.rec_exported = false
          -- Clear the new group's old audio (only if its rec is active)
          if not is_item_muted(next_group.rec_item) then
            clear_group_audio(next_group)
          end
          td.cleared = true
        end
      end

      -- Switch play group buffer when old play clips are done
      if td.play_current < td.current then
        local play_group = td.groups[td.play_current]
        local all_done = true
        if play_group then
          for _, pi in ipairs(play_group.play_items) do
            if not is_item_muted(pi) then
              local pe = get_item_pos(pi) + get_item_len(pi)
              if pos < pe + POST_ROLL then
                all_done = false
                break
              end
            end
          end
        end
        if all_done then
          td.play_current = td.current
          td.play_buf = td.rec_buf
        end
      end

      -- Incrementally place exported audio as playhead passes items
      -- Use actual_post * 2 margin to ensure playhead is well past
      -- the placed item's fade-out tail (accounts for audio buffer latency)
      local any_placed = false
      for gi, ge in pairs(td.group_exports) do
        local g = td.groups[gi]
        if g and ge.ep and ge.audio_track then
          local margin = ge.ep.actual_post * 2
          if not ge.rec_placed then
            local rec_end_pos = get_item_pos(g.rec_item) + get_item_len(g.rec_item)
            if pos >= rec_end_pos + margin then
              if not any_placed then reaper.PreventUIRefresh(1); any_placed = true end
              place_rec_audio(g, ge.audio_track, ge.ep)
              ge.rec_placed = true
            end
          end
          for pi, play_item in ipairs(g.play_items) do
            if not ge.plays_placed[pi] then
              local play_end = get_item_pos(play_item) + get_item_len(play_item)
              if pos >= play_end + margin then
                if not any_placed then reaper.PreventUIRefresh(1); any_placed = true end
                place_play_item_audio(ge.audio_track, play_item, ge.ep)
                ge.plays_placed[pi] = true
              end
            end
          end
        end
      end
      if any_placed then
        reaper.PreventUIRefresh(-1)
        reaper.UpdateArrange()
      end

      -- Update FX container bypass based on which play clips are active now
      if fx_container_state[track] then
        local active_clips = {}
        local slot = 0
        for _, g in ipairs(td.groups) do
          for _, pi in ipairs(g.play_items) do
            if slot < MAX_FX_SLOTS and not is_item_muted(pi) then
              local ps = get_item_pos(pi)
              local pe = ps + get_item_len(pi)
              if pos >= ps - PRE_ROLL - FX_BYPASS_MARGIN and pos < pe + POST_ROLL + FX_BYPASS_MARGIN then
                active_clips[slot] = true
              end
            end
            slot = slot + 1
          end
        end
        update_fx_bypass(track, active_clips)
      end

      ::next_track::
    end
    reaper.Undo_EndBlock("Timeline Looper: clear audio", -1)
  end

  -- Auto-export when transport stops
  if last_play_state > 0 and play_state == 0 then
    for track, td in pairs(track_data) do
      if is_track_silenced(track) then goto skip end
      set_track_xfade(track)
      local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1

      -- Sync play group state
      if td.play_current < td.current then
        td.play_current = td.current
        td.play_buf = td.rec_buf
      end

      -- Export current rec group if not already exported and rec is active
      local group = td.groups[td.current]
      if group and td.rec_complete and not td.rec_exported and not td.group_exports[td.current] and not is_item_muted(group.rec_item) then
        local buf_len = reaper.gmem_read(100 + track_idx)
        if buf_len > 0 then
          queue_export(group, track, td.current, td.rec_buf)
        end
      end
      ::skip::
    end
  end

  last_play_state = play_state

  write_gmem()

  -- Place all remaining exported items when stopped
  if play_state == 0 then
    local any_placed = false
    for track, td in pairs(track_data) do
      for gi, ge in pairs(td.group_exports) do
        local g = td.groups[gi]
        if g and ge.ep and ge.audio_track then
          if not ge.rec_placed then
            if not any_placed then reaper.PreventUIRefresh(1); any_placed = true end
            place_rec_audio(g, ge.audio_track, ge.ep)
            ge.rec_placed = true
          end
          for pi, play_item in ipairs(g.play_items) do
            if not ge.plays_placed[pi] then
              if not any_placed then reaper.PreventUIRefresh(1); any_placed = true end
              place_play_item_audio(ge.audio_track, play_item, ge.ep)
              ge.plays_placed[pi] = true
            end
          end
        end
      end
    end
    if any_placed then
      reaper.PreventUIRefresh(-1)
      reaper.UpdateArrange()
    end
  end

  reaper.defer(looper_tick)
end

-- ─── Actions ─────────────────────────────────────────────────────────────────

local function get_one_measure_seconds()
  local _, bpi = reaper.GetProjectTimeSignature2(0)
  local tempo = reaper.Master_GetTempo()
  return (60 / tempo) * bpi
end

local function create_midi_item(track, position, length, name, color)
  local item = reaper.CreateNewMIDIItemInProj(track, position, position + length)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  end
  local native = reaper.ColorToNative(
    (color >> 16) & 0xFF,
    (color >> 8) & 0xFF,
    color & 0xFF
  )
  reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", native | 0x01000000)
  reaper.UpdateArrange()
  return item
end

-- ─── ImGui interface ─────────────────────────────────────────────────────────

local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)

local function imgui_loop()
  -- Recreate context if it expired
  if not reaper.ImGui_ValidatePtr(ctx, 'ImGui_Context*') then
    ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
    font = reaper.ImGui_CreateFont("sans-serif", 14)
    reaper.ImGui_Attach(ctx, font)
  end

  reaper.ImGui_PushFont(ctx, font)
  reaper.ImGui_SetNextWindowSize(ctx, 280, 75, reaper.ImGui_Cond_Always())
  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true,
    reaper.ImGui_WindowFlags_NoFocusOnAppearing() | reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_NoNav())

  if visible then
    -- Status line
    local is_rec = (reaper.GetPlayState() & 4) ~= 0
    if is_rec then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF4444FF)
      reaper.ImGui_Text(ctx, "RECORDING")
      reaper.ImGui_PopStyleColor(ctx)
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
      reaper.ImGui_Text(ctx, "Idle - hit Record to start")
      reaper.ImGui_PopStyleColor(ctx)
    end

    -- Refresh + Export audio
    if reaper.ImGui_Button(ctx, "Refresh", 60, 0) then
      restore_track_state()
      remove_all_jsfx()
      scan_all_tracks()
      ensure_jsfx_on_tracks()
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Click this after adding rec/play clips to new tracks")
    end
    reaper.ImGui_SameLine(ctx)
    local changed, val = reaper.ImGui_Checkbox(ctx, "Export audio", export_enabled)
    if changed then export_enabled = val end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "This will put audio items onto the track below, so you can rearrange them after recording")
    end

    -- Forward keyboard shortcuts to REAPER when window has focus
    if not reaper.ImGui_IsAnyItemActive(ctx) then
      local mods = reaper.ImGui_GetKeyMods(ctx)
      local none = mods == reaper.ImGui_Mod_None()
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false) and none then
        reaper.Main_OnCommand(40044, 0) -- Transport: Play/stop
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) and none then
        reaper.Main_OnCommand(40044, 0) -- Transport: Play/stop
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Home(), false) and none then
        reaper.Main_OnCommand(40042, 0) -- Transport: Go to start
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_End(), false) and none then
        reaper.Main_OnCommand(40043, 0) -- Transport: Go to end
      end
    end

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopFont(ctx)

  if open then
    reaper.defer(imgui_loop)
  else
    script_running = false
    uninstall_startup()
    restore_track_state()
    remove_all_jsfx()
  end
end

-- ─── Start ───────────────────────────────────────────────────────────────────

reaper.atexit(function()
  uninstall_startup()
  restore_track_state()
  remove_all_jsfx()
end)

reaper.PreventUIRefresh(1)
remove_all_jsfx()
scan_all_tracks()

-- Auto-create starter clips if no rec/play clips found on any track
if not next(track_data) then
  local track = reaper.GetSelectedTrack(0, 0)
  if track then
    local cursor = reaper.GetCursorPosition()
    local measure_len = get_one_measure_seconds()
    create_midi_item(track, cursor, measure_len, "rec", 0x996666)
    create_midi_item(track, cursor + measure_len, measure_len, "play", 0x6e9966)
    scan_all_tracks()
  end
end

reaper.Main_OnCommand(40252, 0) -- Record mode: normal
ensure_mic_track()
ensure_jsfx_on_tracks()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
install_startup()
reaper.defer(looper_tick)
reaper.defer(imgui_loop)
