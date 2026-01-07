-- Pool items that are exactly the same
-- Analyzes selected items; items with identical MIDI/take content are pooled
-- Author: Bryan + Assistant

local r = reaper

local function showMessage(msg)
	r.ShowConsoleMsg(tostring(msg) .. "\n")
end

local function getActiveMidiTake(item)
	local take = r.GetActiveTake(item)
	if take and r.TakeIsMIDI(take) then return take end
	return nil
end

-- Return a stable signature for a MIDI take's content and key properties
local function buildTakeSignature(take)
	-- Gather take-level properties that affect playback
	local src = r.GetMediaItemTake_Source(take)
	local sig = {}
	-- MIDI events
	local ok, midi = r.MIDI_GetAllEvts(take, "")
	if not ok then return nil end
	-- Normalize line endings and remove selection flags that shouldn't affect sound
	-- We keep the exact bytes; MIDI_GetAllEvts returns a packed binary string already deterministic
	table.insert(sig, midi)
	-- Source length/PPQ base
	local qnlen = r.BR_GetMidiSourceLenPPQ(take)
	table.insert(sig, string.format("PPQLEN:%0.0f", qnlen or 0))
	-- Take playrate, pitch, start offset
	table.insert(sig, string.format("RATE:%f", r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0))
	table.insert(sig, string.format("PITCH:%f", r.GetMediaItemTakeInfo_Value(take, "D_PITCH") or 0))
	table.insert(sig, string.format("STARTOFFS:%f", r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0))
	-- Item length also influences truncation; include item length
	local item = r.GetMediaItemTake_Item(take)
	table.insert(sig, string.format("ITEMLEN:%f", r.GetMediaItemInfo_Value(item, "D_LENGTH") or 0))
	-- Loop source flag
	table.insert(sig, string.format("LOOP:%d", r.GetMediaItemTakeInfo_Value(take, "B_LOOPSRC") or 0))
	return table.concat(sig, "|")
end

local function hashString(str)
	-- simple FNV-1a 32-bit
	local hash = 2166136261
	for i = 1, #str do
		hash = hash ~ string.byte(str, i)
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash)
end

local function collectSelectedMidiTakes()
	local groups = {}
	local order = {}
	local count = r.CountSelectedMediaItems(0)
	for i = 0, count-1 do
		local item = r.GetSelectedMediaItem(0, i)
		local take = getActiveMidiTake(item)
		if take then
			local sig = buildTakeSignature(take)
			if sig then
				local key = hashString(sig)
				if not groups[key] then
					groups[key] = { sig = sig, key = key, takes = {}, items = {} }
					table.insert(order, key)
				end
				table.insert(groups[key].takes, take)
				table.insert(groups[key].items, item)
			end
		end
	end
	return groups, order
end

-- Create/assign pooled MIDI GUID to a set of takes by editing state chunks
local function poolTakesViaChunk(takes)
	if #takes < 2 then return 0 end
	-- Acquire first take's pooled GUID if exists; otherwise create new
	local pooled_guid = nil
	-- Build a new GUID like {XXXXXXXXXXXXXXXX-...}
	local function new_guid()
		return r.genGuid("")
	end
	-- Helper to set POOLEDEVTS GUID inside SOURCE MIDI block
	local function set_take_pooled_guid(take, guid)
		local retval, chunk = r.GetItemStateChunk(r.GetMediaItemTake_Item(take), "", false)
		if not retval then return false end
		-- Replace the take's SOURCE MIDI block POOLEDEVTS line
		-- Locate the current take chunk. We rely on unique take GUID to target the section
		local take_guid = r.BR_GetMediaItemTakeGUID(take)
		local start_pos = chunk:find(take_guid, 1, true)
		if not start_pos then return false end
		-- Find SOURCE MIDI following this take
		local source_pos = chunk:find("SOURCE MIDI", start_pos, true)
		if not source_pos then return false end
		local next_section = chunk:find("SOURCE ", source_pos + 1, true) or chunk:find("TAKE", source_pos + 1, true) or #chunk + 1
		local section = chunk:sub(source_pos, next_section - 1)
		-- Ensure POOLEDEVTS line exists or insert one
		if not section:find("POOLEDEVTS", 1, true) then
			section = section .. "\nPOOLEDEVTS " .. guid .. "\n"
		else
			section = section:gsub("POOLEDEVTS%s+[%{%}%-%w]+", "POOLEDEVTS " .. guid, 1)
		end
		local new_chunk = chunk:sub(1, source_pos - 1) .. section .. chunk:sub(next_section)
		return r.SetItemStateChunk(r.GetMediaItemTake_Item(take), new_chunk, false)
	end
	-- Determine pooled GUID: if any take already has one, reuse
	for _, take in ipairs(takes) do
		local retval, chunk = r.GetItemStateChunk(r.GetMediaItemTake_Item(take), "", false)
		if retval then
			local take_guid = r.BR_GetMediaItemTakeGUID(take)
			local start_pos = chunk:find(take_guid, 1, true)
			if start_pos then
				local source_pos = chunk:find("SOURCE MIDI", start_pos, true)
				if source_pos then
					local next_section = chunk:find("SOURCE ", source_pos + 1, true) or chunk:find("TAKE", source_pos + 1, true) or #chunk + 1
					local section = chunk:sub(source_pos, next_section - 1)
					local g = section:match("POOLEDEVTS%s+([%{%}%-%w]+)")
					if g then pooled_guid = g break end
				end
			end
		end
	end
	if not pooled_guid then pooled_guid = new_guid() end
	local pooled = 0
	for _, take in ipairs(takes) do
		if set_take_pooled_guid(take, pooled_guid) then
			pooled = pooled + 1
		end
	end
	return pooled
end

local function main()
	local sel = r.CountSelectedMediaItems(0)
	if sel == 0 then return end
	r.Undo_BeginBlock2(0)
	r.PreventUIRefresh(1)
	local groups, order = collectSelectedMidiTakes()
	local total_groups, total_pooled = 0, 0
	for _, key in ipairs(order) do
		local g = groups[key]
		if #g.takes >= 2 then
			total_groups = total_groups + 1
			total_pooled = total_pooled + poolTakesViaChunk(g.takes)
		end
	end
	r.PreventUIRefresh(-1)
	r.UpdateArrange()
	r.Undo_EndBlock2(0, string.format("Pool identical items: %d groups, %d takes", total_groups, total_pooled), -1)
end

main()
