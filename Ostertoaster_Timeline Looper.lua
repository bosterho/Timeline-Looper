-- @description Ostertoaster Timeline Looper
-- @author Ostertoaster
-- @version 1.0
-- @provides
--   [effect] Ostertoaster/Timeline Looper.jsfx
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
  for _, name in ipairs({"Timeline Looper.jsfx", "Timeline Looper Input.jsfx"}) do
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
local jsfx_managed = {}
local mic_track = nil -- single mic track for input capture

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

local function ensure_mic_track()
  -- Find existing mic track (has input JSFX on regular FX chain)
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    if find_input_jsfx(track) >= 0 then
      mic_track = track
      -- Re-arm and monitor in case cleanup disabled them
      reaper.SetMediaTrackInfo_Value(mic_track, "I_RECARM", 1)
      reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMON", 1)
      reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMODE", 2) -- disable recording, monitor only
      reaper.SetMediaTrackInfo_Value(mic_track, "B_MAINSEND", 0)
      return mic_track
    end
  end
  -- Create mic track at position 0
  reaper.InsertTrackAtIndex(0, false)
  mic_track = reaper.GetTrack(0, 0)
  reaper.GetSetMediaTrackInfo_String(mic_track, "P_NAME", "Mic", true)
  reaper.SetMediaTrackInfo_Value(mic_track, "I_CUSTOMCOLOR", reaper.ColorToNative(0xDE, 0x83, 0x83) | 0x1000000)
  -- Add input JSFX to regular FX chain (unmuting the track feeds audio to master)
  local fx_idx = reaper.TrackFX_AddByName(mic_track, INPUT_JSFX_NAME, false, -1)
  if fx_idx < 0 then
    reaper.ShowMessageBox("Could not add Timeline Looper Input JSFX", SCRIPT_NAME, 0)
  end
  -- Arm + monitor so input signal flows through the FX chain, but don't record to disk
  reaper.SetMediaTrackInfo_Value(mic_track, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMON", 1)
  reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMODE", 2) -- disable recording, monitor only
  -- Set to stereo audio input 1/2 if no input set
  local cur_input = reaper.GetMediaTrackInfo_Value(mic_track, "I_RECINPUT")
  if cur_input < 0 or cur_input >= 4096 then
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECINPUT", 1024)
  end
  -- Disable master send so it doesn't output to master (enable to hear input)
  reaper.SetMediaTrackInfo_Value(mic_track, "B_MAINSEND", 0)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return mic_track
end

local function cleanup_mic_track()
  if mic_track and reaper.ValidatePtr(mic_track, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECARM", 0)
    reaper.SetMediaTrackInfo_Value(mic_track, "I_RECMON", 0)
  end
  mic_track = nil
end

local function restore_track_state()
  cleanup_mic_track()
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

local function remove_all_jsfx()
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    for i = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
      local _, name = reaper.TrackFX_GetFXName(track, i, "")
      if name and name:lower():find("timeline looper")
        and not name:lower():find("timeline looper input") then
        reaper.TrackFX_Delete(track, i)
      end
    end
  end
  jsfx_managed = {}
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

  local jsfx_idx = reaper.GetMediaTrackInfo_Value(jsfx_track, "IP_TRACKNUMBER") - 1
  local jsfx_depth = reaper.GetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH")
  local parent = reaper.GetParentTrack(jsfx_track)

  if not parent then
    -- Create parent folder above the JSFX track
    reaper.InsertTrackAtIndex(jsfx_idx, false)
    parent = reaper.GetTrack(0, jsfx_idx)
    reaper.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
    local _, jsfx_name = reaper.GetSetMediaTrackInfo_String(jsfx_track, "P_NAME", "", false)
    reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", jsfx_name or "Looper", true)
    reaper.SetMediaTrackInfo_Value(parent, "I_CUSTOMCOLOR", reaper.ColorToNative(0x83, 0xB7, 0xDE) | 0x1000000)
    reaper.GetSetMediaTrackInfo_String(jsfx_track, "P_NAME", "JSFX", true)
    -- Refresh after insertion
    jsfx_idx = reaper.GetMediaTrackInfo_Value(jsfx_track, "IP_TRACKNUMBER") - 1
    jsfx_depth = reaper.GetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH")
  end

  -- If JSFX track was a folder parent (old setup), flatten to regular child
  if jsfx_depth == 1 then
    reaper.SetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH", 0)
    audio = find_audio_sibling(jsfx_track)
    if audio then
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
      return audio
    end
    jsfx_idx = reaper.GetMediaTrackInfo_Value(jsfx_track, "IP_TRACKNUMBER") - 1
    jsfx_depth = reaper.GetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH")
  end

  -- Insert audio sibling after the JSFX track
  -- Transfer any folder-closing depth from JSFX to the new audio track
  local audio_depth = -1
  if jsfx_depth < 0 then
    audio_depth = jsfx_depth
    reaper.SetMediaTrackInfo_Value(jsfx_track, "I_FOLDERDEPTH", 0)
  end
  reaper.InsertTrackAtIndex(jsfx_idx + 1, false)
  audio = reaper.GetTrack(0, jsfx_idx + 1)
  reaper.SetMediaTrackInfo_Value(audio, "I_FOLDERDEPTH", audio_depth)
  reaper.GetSetMediaTrackInfo_String(audio, "P_NAME", "Audio", true)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return audio
end

local function ensure_jsfx_on_tracks()
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
end

-- ─── gmem sync (Lua → JSFX) ─────────────────────────────────────────────────

local function write_gmem()
  for track, td in pairs(track_data) do
    local rec_group = td.groups[td.current]
    if not rec_group then goto continue end
    local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
    local base = 1000 + track_idx * 50

    -- Write rec region from current (rec) group
    local rec_start = get_item_pos(rec_group.rec_item)
    local rec_end = rec_start + get_item_len(rec_group.rec_item)
    reaper.gmem_write(base, rec_start)
    reaper.gmem_write(base + 1, rec_end)
    reaper.gmem_write(base + 2, is_item_muted(rec_group.rec_item) and 1 or 0)

    -- Write play regions from play group (may differ from rec group)
    local play_group = td.groups[td.play_current]
    if play_group then
      reaper.gmem_write(base + 3, #play_group.play_items)
      for j, play_item in ipairs(play_group.play_items) do
        local pbase = base + 4 + (j - 1) * 3
        local ps = get_item_pos(play_item)
        reaper.gmem_write(pbase, ps)
        reaper.gmem_write(pbase + 1, ps + get_item_len(play_item))
        local flags = 0
        if is_item_muted(play_item) then flags = flags + 1 end
        if get_item_name(play_item):find("rev") then flags = flags + 2 end
        reaper.gmem_write(pbase + 2, flags)
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

local function place_single_item(audio_track, position, length, ep, is_reverse)
  local new_item = reaper.AddMediaItemToTrack(audio_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  local new_source = reaper.PCM_Source_CreateFromFile(ep.file)
  reaper.SetMediaItemTake_Source(new_take, new_source)
  reaper.SetMediaItemInfo_Value(new_item, "B_LOOPSRC", 0)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", ep.src_offset or 0)
  local xfade = ep.actual_pre + ep.actual_post
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", xfade)
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", xfade)
  reaper.SetMediaItemInfo_Value(new_item, "D_SNAPOFFSET", ep.actual_pre)
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
  local ratio = play_len / ep.rec_len
  local n_copies = math.ceil(ratio - 1e-9)
  local items = {}
  for c = 0, n_copies - 1 do
    local grid_pos = play_pos + c * ep.rec_len
    local remaining = play_end - grid_pos
    local copy_main = math.min(ep.rec_len, remaining)
    local item_pos = grid_pos - ep.actual_pre
    local item_len = copy_main + ep.actual_pre + ep.actual_post
    local item
    if is_reverse and copy_main < ep.rec_len then
      -- Create at full length so reverse operates on full source, then trim
      local full_len = ep.rec_len + ep.actual_pre + ep.actual_post
      item = place_single_item(audio_track, item_pos, full_len, ep, true)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_len)
    else
      item = place_single_item(audio_track, item_pos, item_len, ep, is_reverse)
    end
    -- Last copy has nothing after it — fade-out only covers the post-roll
    if c == n_copies - 1 then
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", ep.actual_post)
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
      end
    end
    last_scan_time = now
  end

  process_export()

  if not is_recording then
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

remove_all_jsfx()
scan_all_tracks()

-- Auto-create starter clips if no rec/play clips found on any track
if not next(track_data) then
  local track = reaper.GetSelectedTrack(0, 0)
  if track then
    local cursor = reaper.GetCursorPosition()
    local measure_len = get_one_measure_seconds()
    create_midi_item(track, cursor, measure_len, "rec", 0xFF0000)
    create_midi_item(track, cursor + measure_len, measure_len, "play", 0x00FF00)
    scan_all_tracks()
  end
end

reaper.Main_OnCommand(40252, 0) -- Record mode: normal
ensure_mic_track()
ensure_jsfx_on_tracks()
install_startup()
reaper.defer(looper_tick)
reaper.defer(imgui_loop)
