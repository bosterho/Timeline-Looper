-- @description Scheduled Looper
-- @author Ostertoaster
-- @version 1.0
-- @provides
--   [effect] Ostertoaster/scheduled_looper.jsfx
-- @about
--   Scheduled live looper for REAPER. Place red "rec" and green "play" MIDI items
--   on a track to define recording and playback regions. The companion JSFX plugin
--   handles real-time audio capture and playback with crossfading.
--
-- Scans tracks for rec/play MIDI items, writes current group to gmem per track.
-- Exports buffer before advancing to the next group on the same track.

local reaper = reaper
local SCRIPT_NAME = "Scheduled Looper (JSFX)"

reaper.gmem_attach("scheduled_looper")

-- ─── State ───────────────────────────────────────────────────────────────────

local script_running = true
local last_scan_time = 0
local SCAN_INTERVAL = 1.0
local PRE_ROLL = 0.05
local POST_ROLL = 0.05
local last_play_state = reaper.GetPlayState()

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
  local xf = reaper.gmem_read(30 + idx)
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

local JSFX_ADD_NAME = "JS:Ostertoaster/scheduled_looper"
local jsfx_managed = {}
local track_original_state = {} -- saved arm/monitor state per track

local function restore_track_state()
  for track, state in pairs(track_original_state) do
    if reaper.ValidatePtr(track, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(track, "I_RECARM", state.arm)
      reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 0)
      reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", state.input)
    end
  end
  track_original_state = {}
end

local function remove_all_jsfx()
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    for i = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
      local _, name = reaper.TrackFX_GetFXName(track, i, "")
      if name and name:lower():find("scheduled looper") then
        reaper.TrackFX_Delete(track, i)
      end
    end
  end
  jsfx_managed = {}
end

local function ensure_jsfx_on_tracks()
  local tracks_to_embed = {}
  for track in pairs(track_data) do
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
        tracks_to_embed[track] = true
      end
      if not track_original_state[track] then
        track_original_state[track] = {
          arm = reaper.GetMediaTrackInfo_Value(track, "I_RECARM"),
          mon = reaper.GetMediaTrackInfo_Value(track, "I_RECMON"),
          input = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT"),
        }
        reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
        reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)
        -- Set to stereo audio input 1/2 if currently set to MIDI or no input
        local cur_input = track_original_state[track].input
        if cur_input < 0 or cur_input >= 4096 then
          reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", 1024)
        end
      end
      jsfx_managed[track] = true
    end
  end
  if next(tracks_to_embed) then
    local saved_sel = {}
    for s = 0, reaper.CountSelectedTracks(0) - 1 do
      saved_sel[#saved_sel + 1] = reaper.GetSelectedTrack(0, s)
    end
    for s = 0, reaper.CountTracks(0) - 1 do
      reaper.SetTrackSelected(reaper.GetTrack(0, s), false)
    end
    for track in pairs(tracks_to_embed) do
      reaper.SetTrackSelected(track, true)
    end
    reaper.Main_OnCommand(42340, 0)
    for s = 0, reaper.CountTracks(0) - 1 do
      reaper.SetTrackSelected(reaper.GetTrack(0, s), false)
    end
    for _, tr in ipairs(saved_sel) do
      reaper.SetTrackSelected(tr, true)
    end
  end
end

-- ─── gmem sync (Lua → JSFX) ─────────────────────────────────────────────────

local function write_gmem()
  for track, td in pairs(track_data) do
    local rec_group = td.groups[td.current]
    if not rec_group then goto continue end
    local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
    local base = 100 + track_idx * 50

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
    reaper.gmem_write(50 + track_idx, td.rec_buf)
    reaper.gmem_write(55 + track_idx, td.play_buf)
    ::continue::
  end
end

-- ─── Export logic ─────────────────────────────────────────────────────────────

local pending_export = nil
local export_queue = {}
local saved_edit_cursor = nil

local function get_track_below(track)
  local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  if idx < reaper.CountTracks(0) then
    return reaper.GetTrack(0, idx)
  end
  return nil
end

local function clear_group_audio(group)
  local audio_track = get_track_below(group.track)
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

local function snapshot_audio_items(track)
  local snap = {}
  if track then
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      snap[reaper.GetTrackMediaItem(track, i)] = true
    end
  end
  return snap
end

local function find_new_audio_item(track, snapshot)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if not snapshot[item] then
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then
        return item
      end
    end
  end
  return nil
end

local function compute_export_params(src_filename, rec_len, saved_prl)
  local srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if srate == 0 then srate = 44100 end
  local prl_frames = saved_prl or 0
  local actual_pre = prl_frames > 0 and (prl_frames / srate) or PRE_ROLL
  local probe_src = reaper.PCM_Source_CreateFromFile(src_filename)
  local src_len = 0
  if probe_src then
    src_len = reaper.GetMediaSourceLength(probe_src)
    reaper.PCM_Source_Destroy(probe_src)
  end
  local actual_post = src_len > 0 and math.max(0, src_len - rec_len - actual_pre) or POST_ROLL
  return {
    file = src_filename, rec_len = rec_len,
    actual_pre = actual_pre, actual_post = actual_post,
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
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", ep.actual_pre)
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", ep.actual_post)
  if is_reverse then
    reaper.SetMediaItemSelected(new_item, true)
    reaper.Main_OnCommand(41051, 0) -- Toggle take reverse
    reaper.SetMediaItemSelected(new_item, false)
  end
end

local function place_rec_audio(group, audio_track, ep)
  if is_item_muted(group.rec_item) then return end
  local rec_pos = get_item_pos(group.rec_item)
  local length = ep.src_len > 0 and ep.src_len or (ep.rec_len + PRE_ROLL + POST_ROLL)
  place_single_item(audio_track, rec_pos - ep.actual_pre, length, ep, false)
end

local function place_play_item_audio(audio_track, play_item, ep)
  if is_item_muted(play_item) then return end
  local play_pos = get_item_pos(play_item)
  local play_len = get_item_len(play_item)
  local play_end = play_pos + play_len
  local is_reverse = get_item_name(play_item):find("rev") ~= nil
  local n_copies = math.ceil(play_len / ep.rec_len)
  for c = 0, n_copies - 1 do
    local grid_pos = play_pos + c * ep.rec_len
    local remaining = play_end - grid_pos
    local copy_main = math.min(ep.rec_len, remaining)
    local item_pos = grid_pos - ep.actual_pre
    local item_len = copy_main + ep.actual_pre + ep.actual_post
    place_single_item(audio_track, item_pos, item_len, ep, is_reverse)
  end
end

local function queue_export(group, track, group_idx, export_buf)
  local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
  local rec_buf_gmem = reaper.gmem_read(50 + track_idx)
  local prl = reaper.gmem_read(export_buf == rec_buf_gmem and (40 + track_idx) or (80 + track_idx))
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
    clear_group_audio(next_exp.group)
    local audio_track = get_track_below(next_exp.group.track)
    local pre_snap = snapshot_audio_items(audio_track)
    reaper.SetEditCurPos(next_exp.rec_start, false, false)
    reaper.gmem_write(60 + next_exp.track_idx, next_exp.export_buf)
    reaper.gmem_write(21, next_exp.track_idx + 1)
    reaper.gmem_write(20, next_exp.track_idx + 1) -- trigger = track_idx + 1
    pending_export = {
      group = next_exp.group, phase = "wait", tick = 0,
      audio_track = audio_track, pre_snap = pre_snap,
      prl_frames = next_exp.prl_frames,
      group_idx = next_exp.group_idx,
      track = next_exp.track,
    }
  end

  if not pending_export then return end
  local pe = pending_export

  if pe.phase == "wait" then
    pe.tick = pe.tick + 1
    if reaper.gmem_read(20) == 0 then
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
    if pe.audio_track then
      local rec_len = get_item_len(pe.group.rec_item)
      local item = find_new_audio_item(pe.audio_track, pe.pre_snap)
      if item then
        local take = reaper.GetActiveTake(item)
        local source = take and reaper.GetMediaItemTake_Source(take)
        local src_filename = source and reaper.GetMediaSourceFileName(source)
        reaper.DeleteTrackMediaItem(pe.audio_track, item)
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
      local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
      local xf = reaper.gmem_read(30 + idx)
      if xf > 0 then
        reaper.SetProjExtState(0, EXTSTATE_SECTION, "xfade_" .. idx, tostring(xf))
      end
    end
    last_scan_time = now
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
      td.group_exports = {}
      for i, g in ipairs(td.groups) do
        local rec_end = get_item_pos(g.rec_item) + get_item_len(g.rec_item)
        if pos < rec_end + POST_ROLL then
          td.current = i
          td.play_current = i
          break
        end
        -- Past this group entirely — mark it as already done
        if i == #td.groups then
          td.current = i
          td.play_current = i
          td.exported = true
        end
      end
    end
  end

  -- During playback: advance groups and trigger exports
  if play_state > 0 then
    local pos = reaper.GetPlayPosition()
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
      -- The JSFX temp item spans rec_start to rec_end + PRE_ROLL + POST_ROLL,
      -- so the playhead must be past that to avoid the temp item causing clicks
      if not td.rec_exported then
        local rec_start = get_item_pos(group.rec_item)
        local rec_end = rec_start + get_item_len(group.rec_item)
        if pos >= rec_end + PRE_ROLL + POST_ROLL then
          if not is_item_muted(group.rec_item) then
            local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
            local buf_len = reaper.gmem_read(10 + track_idx)
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
      if group and not td.group_exports[td.current] and not is_item_muted(group.rec_item) then
        local buf_len = reaper.gmem_read(10 + track_idx)
        if buf_len > 0 then
          queue_export(group, track, td.current, td.rec_buf)
        end
      end
      ::skip::
    end
  end

  last_play_state = play_state

  write_gmem()
  process_export()

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

local function action_add_rec()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first.", SCRIPT_NAME, 0)
    return
  end
  create_midi_item(track, reaper.GetCursorPosition(), get_one_measure_seconds(), "rec", 0xFF0000)
  scan_all_tracks()
end

local function action_add_play()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first.", SCRIPT_NAME, 0)
    return
  end
  create_midi_item(track, reaper.GetCursorPosition(), get_one_measure_seconds(), "play", 0x00FF00)
  scan_all_tracks()
end

-- ─── ImGui interface ─────────────────────────────────────────────────────────

local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)

local function imgui_loop()
  reaper.ImGui_PushFont(ctx, font)
  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true, reaper.ImGui_WindowFlags_NoFocusOnAppearing())

  if visible then
    if reaper.ImGui_Button(ctx, "Add Rec Clip") then
      action_add_rec()
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Add Play Clip") then
      action_add_play()
    end

    local has_tracks = false
    for _ in pairs(track_data) do has_tracks = true; break end

    if has_tracks then
      reaper.ImGui_Separator(ctx)

      for track, td in pairs(track_data) do
        local _, track_name = reaper.GetTrackName(track)
        local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
        local buf_frames = reaper.gmem_read(10 + track_idx)
        local srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
        if srate == 0 then srate = 44100 end

        local group = td.groups[td.current]
        if group then
          if buf_frames > 0 then
            reaper.ImGui_Text(ctx, string.format("%s [%d/%d]: %.1fs",
              track_name, td.current, #td.groups, buf_frames / srate))
          else
            reaper.ImGui_TextDisabled(ctx, string.format("%s [%d/%d]: empty",
              track_name, td.current, #td.groups))
          end
        end
      end
    end

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopFont(ctx)

  if open then
    reaper.defer(imgui_loop)
  else
    script_running = false
    restore_track_state()
    remove_all_jsfx()
  end
end

-- ─── Start ───────────────────────────────────────────────────────────────────

reaper.atexit(function()
  restore_track_state()
  remove_all_jsfx()
end)

remove_all_jsfx()
scan_all_tracks()
ensure_jsfx_on_tracks()
reaper.defer(looper_tick)
reaper.defer(imgui_loop)
