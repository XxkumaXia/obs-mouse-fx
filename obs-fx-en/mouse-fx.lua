--[[
mouse-fx.lua — OBS mouse highlight overlay (filter / standalone source)
================================================================
Usage: load this file from the OBS menu "Tools → Scripts → +".
      Then right-click a Display / Window / Game Capture source → Filters → Add
      "Mouse Highlight Overlay"; or add a "Mouse Highlight Layer" source to the scene.

How it works: LuaJIT's ffi calls Win32 directly for cursor position and buttons,
      then mouse-fx.effect draws the highlight ring / click ripples / trail / self-drawn cursor.
      No external service, browser source or Python environment required.

Note: mouse-fx.effect and blank.png must sit in the same folder as this file.
]]

obs = obslua
bit = bit or require("bit")

local LOG_INFO  = obs.LOG_INFO  or 300
local LOG_ERROR = obs.LOG_ERROR or 100

-- Script settings table: must be declared before any function that reads it!
-- In Lua a local only becomes visible at its declaration point, so a function defined
-- above it compiles S into a global → nil at runtime → every frame raises
-- "attempt to index global 'S'". (Bitten by this twice. Keep S at the top of the file.)
local S = {}

-- Counter behind the "Regrab cursor" button: each click bumps it and the value goes into
-- cursor_update's key, so every instance runs a "clear + resample". Declared at the top of
-- the file so the properties callback closure and cursor_update both see it.
local REGRAB = 0

-- Report each distinct error once (a failing theme switch would otherwise flood the log)
local CUR_ERR_SEEN = {}

-- Version string, printed in the load log: when troubleshooting, confirm which build OBS
-- actually loaded. (Shipped a fix once while OBS kept running the old file.)
local SCRIPT_VERSION = "1.1.1"

-- Logging is off by default so the OBS script log stays quiet. Turn on "Output log" to debug.
-- Level policy (changed in v1.1.1, see DEVELOPMENT.md pitfall 10):
--   the OBS frontend auto-opens and raises the script log window for anything at or above
--   LOG_WARNING (obs-studio/plugins/frontend-tools/scripts.cpp, log callback),
--   i.e. ERROR and WARNING pop a window, INFO does not.
--   So: log() = INFO, follows the "Output log" switch, never pops — every hint goes here;
--   logerr() = ERROR, pops unconditionally, reserved for genuinely fatal failures (effect / blank.png
--   failing to load means nothing can be drawn at all — the user has to know).
local function log(msg)
	if S.log_on then
		obs.script_log(LOG_INFO, "[Mouse FX] " .. msg)
	end
end
-- Errors always print (rare, and they flag real configuration problems)
local function logerr(msg)
	obs.script_log(LOG_ERROR, "[Mouse FX] " .. msg)
end

-- ---------------------------------------------------------------- FFI
local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then
	logerr("This OBS build has no ffi in its Lua environment, so the mouse position can't be read. Loading stopped.")
	return
end

ffi.cdef([[
	typedef struct { long x; long y; } POINT;
	typedef struct { long left; long top; long right; long bottom; } RECT;
	typedef struct {
		unsigned long cbSize; RECT rcMonitor; RECT rcWork;
		unsigned long dwFlags; char szDevice[32];
	} MONITORINFOEXA;
	typedef struct {
		unsigned long cb; char DeviceName[32]; char DeviceString[128];
		unsigned long StateFlags; char DeviceID[128]; char DeviceKey[128];
	} DISPLAY_DEVICEA;
	int   GetCursorPos(POINT *lpPoint);
	int   GetSystemMetrics(int nIndex);
	short GetAsyncKeyState(int vKey);
	int   EnumDisplayMonitors(void *hdc, void *clip, void *fn, long long data);
	int   GetMonitorInfoA(void *hMonitor, MONITORINFOEXA *lpmi);
	int   EnumDisplayDevicesA(const char *dev, unsigned long i,
	                          DISPLAY_DEVICEA *dd, unsigned long flags);
	unsigned long long GetTickCount64(void);
]])

local user32   = ffi.load("user32")
local kernel32 = ffi.load("kernel32")
local cursor_pt = ffi.new("POINT")

local SM_CXSCREEN        = 0
local SM_CYSCREEN        = 1
local SM_XVIRTUALSCREEN  = 76
local SM_YVIRTUALSCREEN  = 77
local SM_CXVIRTUALSCREEN = 78
local SM_CYVIRTUALSCREEN = 79

local VK_LBUTTON = 0x01
local VK_RBUTTON = 0x02
local VK_MBUTTON = 0x04

local EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001

local MAX_RINGS = 8
local MAX_DOTS  = 12

local function sm(i)
	local v = tonumber(user32.GetSystemMetrics(i))
	if v == nil then
		return 0
	end
	return v
end

-- Enumerate all monitors: returns a list of {left, top, w, h, id} (id = device interface path)
local function enum_monitors()
	local list = {}
	local mi = ffi.new("MONITORINFOEXA")
	local dd = ffi.new("DISPLAY_DEVICEA")
	local ok, cb = pcall(ffi.cast, "int (*)(void *, void *, RECT *, long long)",
		function(hmon, hdc, rc, lp)
			mi.cbSize = ffi.sizeof(mi)
			if user32.GetMonitorInfoA(hmon, mi) ~= 0 then
				dd.cb = ffi.sizeof(dd)
				local id = ""
				if user32.EnumDisplayDevicesA(mi.szDevice, 0, dd,
					EDD_GET_DEVICE_INTERFACE_NAME) ~= 0 then
					id = ffi.string(dd.DeviceID)
				end
				list[#list + 1] = {
					left = tonumber(mi.rcMonitor.left),
					top = tonumber(mi.rcMonitor.top),
					w = tonumber(mi.rcMonitor.right - mi.rcMonitor.left),
					h = tonumber(mi.rcMonitor.bottom - mi.rcMonitor.top),
					id = id,
					name = ffi.string(dd.DeviceString),
				}
			end
			return 1
		end)
	if not ok then
		return list
	end
	user32.EnumDisplayMonitors(nil, nil, cb, 0)
	cb:free()
	return list
end

-- Find the monitor rect matching an OBS monitor_id (auto mode)
local function find_monitor(monitor_id)
	if monitor_id == nil or monitor_id == "" then
		return nil
	end
	local list = enum_monitors()
	if #list == 1 then
		return list[1]
	end
	for _, m in ipairs(list) do
		if m.id ~= "" then
			if m.id == monitor_id
				or string.find(monitor_id, m.id, 1, true) ~= nil
				or string.find(m.id, monitor_id, 1, true) ~= nil then
				return m
			end
		end
	end
	return nil
end

local auto_diag_done = false

-- Filter: read the display-capture settings of the target source and derive the mapping region
local function detect_source_region(source)
	local target = obs.obs_filter_get_target(source)
	if target == nil then
		return nil
	end
	if obs.obs_source_get_id(target) ~= "monitor_capture" then
		return nil
	end
	local settings = obs.obs_source_get_settings(target)
	if settings == nil then
		return nil
	end
	local mid = obs.obs_data_get_string(settings, "monitor_id")
	obs.obs_data_release(settings)

	local m = find_monitor(mid)
	if m == nil then
		return nil
	end
	return { m.left, m.top, m.w, m.h }
end

-- Standalone source: read the monitor rect it captures, by source name (auto mode).
-- The filter can call obs_filter_get_target and get its target directly; a standalone source is
-- a detached layer, so it can only look the source up by name. This is the multi-monitor trick:
local function detect_named_source_region(name)
	if name == nil or name == "" then
		return nil
	end
	local ok, src = pcall(obs.obs_get_source_by_name, name)
	if not ok or src == nil then
		return nil
	end
	local r = nil
	local ok2, res = pcall(function()
		if obs.obs_source_get_id(src) ~= "monitor_capture" then
			return nil
		end
		local st = obs.obs_source_get_settings(src)
		if st == nil then
			return nil
		end
		local mid = obs.obs_data_get_string(st, "monitor_id")
		obs.obs_data_release(st)
		local m = find_monitor(mid)
		if m == nil then
			return nil
		end
		return { m.left, m.top, m.w, m.h }
	end)
	if ok2 then
		r = res
	end
	obs.obs_source_release(src)
	return r
end

-- ---------------------------------------------------------------- zoom link
-- Used together with obs-zoom-to-mouse.lua: it zooms by shrinking the source's output with a
-- crop filter and stretching the scene item back to full size, leaving the item transform alone.
-- A standalone layer (Mouse Highlight Layer) is a separate layer that never sees that transform,
-- so here we read the live crop rect off the linked source and remap cursor coordinates into the
-- zoomed frame. Fixed filter name used by obs-zoom-to-mouse (BlankSourceCode); only that exact
local ZOOM_CROP_NAME = "obs-zoom-to-mouse-crop"
-- Resolve the crop filter name on the linked source. ★ Take it live, release it right away, never hold a source ref across frames ★
-- (Once cached the source ref in d.cap long-term: at OBS shutdown that ref kept the source alive,
--  obs_source_destroy_defer then released in the wrong order → unhandled c0000005 → crash / recovery prompt on every launch.)
local function follow_find_crop_name()
	local fn = obs.obs_get_source_by_name
	if fn == nil then
		return nil
	end
	local ok, src = pcall(fn, S.follow_source)
	if not ok or src == nil then
		return nil
	end
	local sid = obs.obs_source_get_id(src)
	if sid ~= "monitor_capture" and sid ~= "window_capture" and sid ~= "game_capture" then
		obs.obs_source_release(src)
		return nil
	end

	-- Find the crop filter: only the exact obs-zoom-to-mouse name counts.
	-- It used to be "any name containing zoom, else fall back to any enabled crop_filter". Two pitfalls:
	--   ① the zoom script converts a scene item's own transform crop into a temporary filter
	--      named temp_obs-zoom-to-mouse-crop — contains "zoom", but it holds the user's static
	--      crop, not the per-frame animation rect, so trusting it skews the factor and offsets the overlay;
	--   ② a Crop/Pad filter the user added on the zoom script's advice gets taken as the link rect,
	--      the coordinate frames don't match, and with a failed cursor takeover you get two cursors on screen.
	-- Now: no match returns nil (the caller treats it as unzoomed and logs a warning). Never a substitute.
	local name = nil
	local ok2, filters = pcall(obs.obs_source_enum_filters, src)
	if ok2 and filters ~= nil then
		for _, f in pairs(filters) do
			if f ~= nil and obs.obs_source_enabled(f) and
				obs.obs_source_get_id(f) == "crop_filter" then
				local nm = obs.obs_source_get_name(f) or ""
				if nm == ZOOM_CROP_NAME then
					name = nm
					break
				end
			end
		end
		local release = obs.obs_source_list_release or obs.source_list_release
		if release ~= nil then
			pcall(release, filters)
		end
	end
	obs.obs_source_release(src)
	return name
end

-- Returns the current crop rect cl, ct, cw, ch (in the linked source's space); nil when unlinked/unreadable
local function follow_crop(d)
	if S.follow_source == "" then
		return nil
	end
	-- Invalidated on source change; otherwise the filter name is re-resolved every 2 s (either can be renamed)
	if d.follow_name ~= S.follow_source then
		d.follow_name = S.follow_source
		d.follow_t = nil
		d.crop_name = nil
		d.follow_logged = false
		d.follow_warned = false
		d.follow_miss = 0
	end
	if d.follow_t == nil or (d.clock - d.follow_t) >= 2.0 then
		d.follow_t = d.clock
		d.crop_name = follow_find_crop_name()
		if d.crop_name == nil then
			-- Warn only after a few consecutive misses: the zoom script creates its crop filter
			-- lazily, a few seconds after load or a scene switch — can't shout on the first miss.
			d.follow_miss = (d.follow_miss or 0) + 1
			if d.follow_miss >= 3 and not d.follow_warned then
				d.follow_warned = true
				log("Zoom link: source '" .. tostring(S.follow_source) ..
					"' has no zoom crop filter (" .. ZOOM_CROP_NAME .. ") — treating the view as unzoomed for now. " ..
					"Other Crop/Pad filters on that source are never used as a stand-in; it reconnects once the zoom script creates the filter")
			end
		else
			d.follow_miss = 0
		end
	end
	if d.crop_name == nil then
		return nil
	end

	local fn_src = obs.obs_get_source_by_name
	local fn_fil = obs.obs_source_get_filter_by_name
	if fn_src == nil or fn_fil == nil then
		return nil
	end
	local ok_s, src = pcall(fn_src, S.follow_source)
	if not ok_s or src == nil then
		return nil
	end

	local res = nil
	local ok_f, f = pcall(fn_fil, src, d.crop_name)
	if ok_f and f ~= nil then
		local ok_st, st = pcall(obs.obs_source_get_settings, f)
		obs.obs_source_release(f)
		if ok_st and st ~= nil then
			local cl = obs.obs_data_get_int(st, "left")
			local ct = obs.obs_data_get_int(st, "top")
			local cw = obs.obs_data_get_int(st, "cx")
			local ch = obs.obs_data_get_int(st, "cy")
			obs.obs_data_release(st)
			if cw > 0 and ch > 0 then
				res = { cl, ct, cw, ch }
			end
		end
	end
	obs.obs_source_release(src)
	if res == nil then
		return nil
	end
	return res[1], res[2], res[3], res[4]
end

-- ---------------------------------------------------------------- settings

-- OBS's obs_properties_add_color returns 0xAABBGGRR (the low byte is R!)
-- Parsed it as 0xAARRGGBB once: red↔blue and cyan↔yellow swapped. Don't change it back.
local function argb(v, mul)
	v = math.floor(tonumber(v) or 0) % 4294967296
	local r = v % 256
	local g = math.floor(v / 256) % 256
	local b = math.floor(v / 65536) % 256
	local a = math.floor(v / 16777216) % 256
	return r / 255, g / 255, b / 255, (a / 255) * (mul or 1.0)
end

-- Build an OBS color int from (r,g,b,a), each 0–255. No hand-written literals.
local function rgb2int(r, g, b, a)
	a = a or 255
	return ((a % 256) * 16777216) + ((b % 256) * 65536) + ((g % 256) * 256) + (r % 256)
end

local C_YELLOW = rgb2int(255, 214, 0)
local C_RED    = rgb2int(255, 59, 48)
local C_GREEN  = rgb2int(52, 199, 89)
local C_WHITE  = rgb2int(255, 255, 255)
local C_BLACK  = rgb2int(0, 0, 0)

local DEF = {
	region_mode   = 0,      -- 0 auto / 1 primary / 2 virtual desktop / 3 custom / 4 specific monitor
	monitor_sel   = "",     -- specific monitor: the monitor's DeviceID (used when region = 4)
	follow_source = "",     -- zoom link source: source name zoomed by obs-zoom-to-mouse (standalone only)
	custom_left   = 0,
	custom_top    = 0,
	custom_width  = 1920,
	custom_height = 1080,
	offset_x      = 0,
	offset_y      = 0,
	zoom          = 1.0,

	hl_on         = true,
	hl_mode       = 0,      -- 0 ring+fill / 1 ring only / 2 fill only
	hl_radius     = 32.0,
	hl_thickness  = 4.0,
	hl_color      = C_YELLOW,
	hl_opacity    = 0.9,
	hl_fill_opacity = 0.38,
	fx_offset_y   = 0.0,    -- circle center shift down for fill/glow (keeps it off the system cursor)
	glow_on       = true,
	glow_radius   = 70.0,
	glow_opacity  = 0.18,

	click_on      = true,
	click_duration= 0.55,
	start_radius  = 6.0,
	end_radius    = 46.0,
	ring_thickness= 5.0,
	ripple_count  = 2,
	ripple_delay  = 0.09,
	fill_opacity  = 0.25,
	click_opacity = 1.0,
	color_left    = C_YELLOW,
	color_right   = C_RED,
	color_middle  = C_GREEN,

	trail_on      = false,
	trail_count   = 8,
	trail_radius  = 9.0,
	trail_step    = 0.02,
	trail_color   = C_YELLOW,
	trail_opacity = 0.4,

	smooth        = 1.0,
	-- Self-drawn cursor: drawn last = topmost, so the persistent ring always sits *under* it
	cur_on        = true,
	cur_auto      = true,   -- read the live system cursor (theme / shape changes follow automatically)
	cur_img       = "cursor.png", -- image used when auto fails (relative to script dir; frames tiled horizontally; repo ships a 32x32 neutral arrow)
	cur_frames    = 0,      -- 0 = derive frame count from width/height
	cur_fps       = 10.0,   -- playback rate for multi-frame cursors
	cur_hot_x     = 1,      -- hotspot (relative to one frame's top-left, pixels)
	cur_hot_y     = 1,
	cur_scale     = 1.0,
	cur_fill      = C_WHITE,
	cur_line      = C_BLACK,
	take_cursor   = true,   -- cursor takeover: turn off "Capture cursor" on the capture source
	take_src      = "",     -- capture source name for takeover (standalone only; empty = use zoom link source)

	canvas_w      = 1920,
	canvas_h      = 1080,
	log_on        = false,  -- output log: off by default, keeps the OBS script log quiet
}

-- 0 auto (follow the captured monitor) / 1 primary / 2 virtual desktop / 3 custom / 4 specific monitor
local function get_region()
	if S.region_mode == 1 then
		return 0, 0, sm(SM_CXSCREEN), sm(SM_CYSCREEN)
	elseif S.region_mode == 2 then
		return sm(SM_XVIRTUALSCREEN), sm(SM_YVIRTUALSCREEN),
		       sm(SM_CXVIRTUALSCREEN), sm(SM_CYVIRTUALSCREEN)
	elseif S.region_mode == 3 then
		return S.custom_left, S.custom_top, S.custom_width, S.custom_height
	elseif S.region_mode == 4 then
		local m = find_monitor(S.monitor_sel)
		if m ~= nil then
			return m.left, m.top, m.w, m.h
		end
		return 0, 0, sm(SM_CXSCREEN), sm(SM_CYSCREEN)
	end
	return 0, 0, sm(SM_CXSCREEN), sm(SM_CYSCREEN)
end

-- Settings that must be stored as double (all other numeric ones are int)
local FLOAT_KEYS = {
	zoom = true, smooth = true,
	hl_radius = true, hl_thickness = true, hl_opacity = true,
	hl_fill_opacity = true, fx_offset_y = true,
	glow_radius = true, glow_opacity = true,
	click_duration = true, start_radius = true, end_radius = true,
	ring_thickness = true, ripple_delay = true,
	fill_opacity = true, click_opacity = true,
	trail_radius = true, trail_step = true, trail_opacity = true,
	cur_scale = true, cur_fps = true,
}

function script_defaults(settings)
	for k, v in pairs(DEF) do
		if type(v) == "boolean" then
			obs.obs_data_set_default_bool(settings, k, v)
		elseif type(v) == "number" then
			if FLOAT_KEYS[k] then
				obs.obs_data_set_default_double(settings, k, v)
			else
				obs.obs_data_set_default_int(settings, k, v)
			end
		end
	end
end

function script_update(settings)
	S.region_mode    = obs.obs_data_get_int(settings, "region_mode")
	S.monitor_sel    = obs.obs_data_get_string(settings, "monitor_sel")
	S.follow_source  = obs.obs_data_get_string(settings, "follow_source")
	S.custom_left    = obs.obs_data_get_int(settings, "custom_left")
	S.custom_top     = obs.obs_data_get_int(settings, "custom_top")
	S.custom_width   = obs.obs_data_get_int(settings, "custom_width")
	S.custom_height  = obs.obs_data_get_int(settings, "custom_height")
	S.offset_x       = obs.obs_data_get_int(settings, "offset_x")
	S.offset_y       = obs.obs_data_get_int(settings, "offset_y")
	S.zoom           = obs.obs_data_get_double(settings, "zoom")

	S.hl_on          = obs.obs_data_get_bool(settings, "hl_on")
	S.hl_mode        = obs.obs_data_get_int(settings, "hl_mode")
	S.hl_radius      = obs.obs_data_get_double(settings, "hl_radius")
	S.hl_thickness   = obs.obs_data_get_double(settings, "hl_thickness")
	S.hl_color       = obs.obs_data_get_int(settings, "hl_color")
	S.hl_opacity     = obs.obs_data_get_double(settings, "hl_opacity")
	S.hl_fill_opacity= obs.obs_data_get_double(settings, "hl_fill_opacity")
	S.fx_offset_y    = obs.obs_data_get_double(settings, "fx_offset_y")
	S.glow_on        = obs.obs_data_get_bool(settings, "glow_on")
	S.glow_radius    = obs.obs_data_get_double(settings, "glow_radius")
	S.glow_opacity   = obs.obs_data_get_double(settings, "glow_opacity")

	S.click_on       = obs.obs_data_get_bool(settings, "click_on")
	S.click_duration = obs.obs_data_get_double(settings, "click_duration")
	S.start_radius   = obs.obs_data_get_double(settings, "start_radius")
	S.end_radius     = obs.obs_data_get_double(settings, "end_radius")
	S.ring_thickness = obs.obs_data_get_double(settings, "ring_thickness")
	S.ripple_count   = obs.obs_data_get_int(settings, "ripple_count")
	S.ripple_delay   = obs.obs_data_get_double(settings, "ripple_delay")
	S.fill_opacity   = obs.obs_data_get_double(settings, "fill_opacity")
	S.click_opacity  = obs.obs_data_get_double(settings, "click_opacity")
	S.color_left     = obs.obs_data_get_int(settings, "color_left")
	S.color_right    = obs.obs_data_get_int(settings, "color_right")
	S.color_middle   = obs.obs_data_get_int(settings, "color_middle")

	S.trail_on       = obs.obs_data_get_bool(settings, "trail_on")
	S.trail_count    = obs.obs_data_get_int(settings, "trail_count")
	S.trail_radius   = obs.obs_data_get_double(settings, "trail_radius")
	S.trail_step     = obs.obs_data_get_double(settings, "trail_step")
	S.trail_color    = obs.obs_data_get_int(settings, "trail_color")
	S.trail_opacity  = obs.obs_data_get_double(settings, "trail_opacity")

	S.smooth         = obs.obs_data_get_double(settings, "smooth")
	S.cur_on         = obs.obs_data_get_bool(settings, "cur_on")
	S.cur_auto       = obs.obs_data_get_bool(settings, "cur_auto")
	S.cur_img        = obs.obs_data_get_string(settings, "cur_img")
	S.cur_frames     = obs.obs_data_get_int(settings, "cur_frames")
	S.cur_fps        = obs.obs_data_get_double(settings, "cur_fps")
	S.cur_hot_x      = obs.obs_data_get_int(settings, "cur_hot_x")
	S.cur_hot_y      = obs.obs_data_get_int(settings, "cur_hot_y")
	S.cur_scale      = obs.obs_data_get_double(settings, "cur_scale")
	S.cur_fill       = obs.obs_data_get_int(settings, "cur_fill")
	S.cur_line       = obs.obs_data_get_int(settings, "cur_line")
	S.take_cursor    = obs.obs_data_get_bool(settings, "take_cursor")
	S.take_src       = obs.obs_data_get_string(settings, "take_src")

	S.canvas_w       = obs.obs_data_get_int(settings, "canvas_w")
	S.canvas_h       = obs.obs_data_get_int(settings, "canvas_h")
	S.log_on         = obs.obs_data_get_bool(settings, "log_on")

	if S.click_duration  < 0.05 then S.click_duration  = 0.05 end
	if S.ripple_count    < 1    then S.ripple_count    = 1    end
	if S.ripple_count    > 3    then S.ripple_count    = 3    end
	if S.trail_count     < 1    then S.trail_count     = 1    end
	if S.trail_count     > MAX_DOTS then S.trail_count = MAX_DOTS end
	if S.trail_step      < 0.005 then S.trail_step     = 0.005 end
	if S.smooth          < 0.02 then S.smooth          = 0.02 end
	if S.smooth          > 1    then S.smooth          = 1    end
	if S.canvas_w        < 16   then S.canvas_w        = 16   end
	if S.canvas_h        < 16   then S.canvas_h        = 16   end
	if S.hl_fill_opacity < 0    then S.hl_fill_opacity = 0    end
	if S.hl_fill_opacity > 1    then S.hl_fill_opacity = 1    end
	if S.hl_mode         < 0    then S.hl_mode         = 0    end
	if S.hl_mode         > 2    then S.hl_mode         = 2    end

	S.hl_ring_on = (S.hl_mode == 0 or S.hl_mode == 1) and 1.0 or 0.0
	S.hl_fill_on = (S.hl_mode == 0 or S.hl_mode == 2) and 1.0 or 0.0

	S.region_left, S.region_top, S.region_w, S.region_h = get_region()
	if S.region_w <= 0 then S.region_w = sm(SM_CXSCREEN) end
	if S.region_h <= 0 then S.region_h = sm(SM_CYSCREEN) end
	if S.region_w <= 0 then S.region_w = 1920 end
	if S.region_h <= 0 then S.region_h = 1080 end

	S.hl_r,   S.hl_g,   S.hl_b,   S.hl_a   = argb(S.hl_color, S.hl_opacity)
	S.dot_r,  S.dot_g,  S.dot_b,  S.dot_a  = argb(S.trail_color, S.trail_opacity)
	S.clk_r,  S.clk_g,  S.clk_b,  S.clk_a  = argb(S.color_left, S.click_opacity)
	S.cr_r,   S.cr_g,   S.cr_b,   S.cr_a   = argb(S.color_right, S.click_opacity)
	S.cm_r,   S.cm_g,   S.cm_b,   S.cm_a   = argb(S.color_middle, S.click_opacity)
	S.cf_r,   S.cf_g,   S.cf_b,   S.cf_a   = argb(S.cur_fill)
	S.cl_r,   S.cl_g,   S.cl_b,   S.cl_a   = argb(S.cur_line)
end

-- ---------------------------------------------------------------- cursor grab
-- Read the "current cursor" bitmap (hotspot included) straight from Windows at runtime:
--   GetCursorInfo → GetIconInfo → GetDIBits → encode to PNG ourselves → hand it to OBS as a texture.
-- So cursor theme changes, shape changes (arrow↔text↔hand) and .ani animations all follow along.
ffi.cdef([[
	typedef struct { unsigned long cbSize; unsigned long flags; void *hCursor; long x; long y; } CURINFO;
	typedef struct {
		int fIcon; unsigned long xHotspot; unsigned long yHotspot;
		void *hbmMask; void *hbmColor;
	} ICONINFOX;
	typedef struct {
		unsigned long biSize; long biWidth; long biHeight;
		unsigned short biPlanes; unsigned short biBitCount;
		unsigned long biCompression; unsigned long biSizeImage;
		long biXPelsPerMeter; long biYPelsPerMeter;
		unsigned long biClrUsed; unsigned long biClrImportant;
	} FXBMIH;
	typedef struct { FXBMIH bmiHeader; unsigned long bmiColors[3]; } FXBMIX;
	typedef struct {
		long bmType; long bmWidth; long bmHeight; long bmWidthBytes;
		unsigned short bmPlanes; unsigned short bmBitsPixel; void *bmBits;
	} FXBITMAP;
	int  GetCursorInfo(CURINFO *pci);
	int  GetIconInfo(void *hIcon, ICONINFOX *pii);
	int  GetObjectA(void *h, int c, void *pv);
	void *CreateCompatibleDC(void *hdc);
	int  DeleteDC(void *hdc);
	int  DeleteObject(void *h);
	int  GetDIBits(void *hdc, void *hbm, unsigned int start, unsigned int lines,
	               void *bits, FXBMIX *bmi, unsigned int usage);
	unsigned long GetTempPathA(unsigned long n, char *buf);
	int  DeleteFileA(const char *name);
]])
local gdi32 = ffi.load("gdi32")

-- ---- minimal PNG encoder (RGBA8 + stored/uncompressed deflate) — no external library ----
local crc_tbl = nil
local function crc32(s)
	if crc_tbl == nil then
		crc_tbl = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if bit.band(c, 1) == 1 then
					c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
				else
					c = bit.rshift(c, 1)
				end
			end
			crc_tbl[i] = c
		end
	end
	local c = -1 -- 0xFFFFFFFF
	for i = 1, #s do
		c = bit.bxor(crc_tbl[bit.band(bit.bxor(c, string.byte(s, i)), 0xFF)],
			bit.rshift(c, 8))
	end
	return bit.bnot(c)
end

local function u32be(v)
	return string.char(
		bit.band(bit.rshift(v, 24), 0xFF),
		bit.band(bit.rshift(v, 16), 0xFF),
		bit.band(bit.rshift(v, 8), 0xFF),
		bit.band(v, 0xFF))
end

local function adler32(s)
	local a, b = 1, 0
	for i = 1, #s do
		a = (a + string.byte(s, i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

-- zlib stream: all stored (uncompressed) blocks — simplest, and hardest to get wrong
local function zlib_store(raw)
	local out = { string.char(0x78, 0x01) }
	local i, n = 1, #raw
	repeat
		local len  = math.min(65535, n - i + 1)
		local last = (i + len - 1 >= n) and 1 or 0
		local nl   = bit.bnot(len)
		out[#out + 1] = string.char(last,
			bit.band(len, 0xFF), bit.band(bit.rshift(len, 8), 0xFF),
			bit.band(nl, 0xFF),  bit.band(bit.rshift(nl, 8), 0xFF))
		out[#out + 1] = string.sub(raw, i, i + len - 1)
		i = i + len
	until i > n
	out[#out + 1] = u32be(adler32(raw))
	return table.concat(out)
end

local function png_chunk(typ, data)
	return u32be(#data) .. typ .. data .. u32be(crc32(typ .. data))
end

-- rgba must be top-down, 4 bytes per pixel
local function png_encode(w, h, rgba)
	local rows = {}
	for y = 0, h - 1 do
		rows[#rows + 1] = "\0" .. string.sub(rgba, y * w * 4 + 1, (y + 1) * w * 4)
	end
	local ihdr = u32be(w) .. u32be(h) .. string.char(8, 6, 0, 0, 0)
	return "\137PNG\r\n\26\n" .. png_chunk("IHDR", ihdr) ..
		png_chunk("IDAT", zlib_store(table.concat(rows))) .. png_chunk("IEND", "")
end

local function write_file(path, data)
	local ok, f = pcall(io.open, path, "wb")
	if not ok or f == nil then
		return false
	end
	f:write(data)
	f:close()
	return true
end

local TMP_DIR = nil
local function tmp_dir()
	if TMP_DIR == nil then
		local buf = ffi.new("char[?]", 520)
		local n = tonumber(kernel32.GetTempPathA(520, buf))
		TMP_DIR = (n ~= nil and n > 0) and ffi.string(buf, n) or ""
	end
	return TMP_DIR
end

local cursor_ci = ffi.new("CURINFO")

-- Grab the current system cursor once; returns w, h, hotx, hoty, rgba (top-down)
local function grab_cursor()
	cursor_ci.cbSize = ffi.sizeof(cursor_ci)
	if user32.GetCursorInfo(cursor_ci) == 0 then
		return nil
	end
	local hcur = cursor_ci.hCursor
	if hcur == nil then
		return nil
	end
	local ii = ffi.new("ICONINFOX")
	if user32.GetIconInfo(hcur, ii) == 0 then
		return nil
	end

	local w, h = 0, 0
	local bmp = ffi.new("FXBITMAP")
	local hb = ii.hbmColor
	if hb == nil then
		hb = ii.hbmMask
	end
	-- Note: GetObjectA lives in gdi32, not user32! Getting this wrong throws
	-- "cannot resolve symbol 'GetObjectA'" and silently kills the whole grab path.
	if hb ~= nil and gdi32.GetObjectA(hb, ffi.sizeof(bmp), bmp) ~= 0 then
		w = tonumber(bmp.bmWidth) or 0
		h = tonumber(bmp.bmHeight) or 0
	end
	local hotx = tonumber(ii.xHotspot) or 0
	local hoty = tonumber(ii.yHotspot) or 0

	local rgba = nil
	if w > 0 and h > 0 and w <= 512 and h <= 512 then
		local hdc = gdi32.CreateCompatibleDC(nil)
		if hdc ~= nil then
			local n = w * h

			-- ============ the mask must be read at its own bit depth ============
			-- [the real root cause of the flash-to-black bug]
			-- hbmMask is a 1bpp bitmap (bmBitsPixel=1)! Early builds passed a 32bpp
			-- BITMAPINFOHEADER to GetDIBits, and Windows can't turn a 1bpp bitmap into a
			-- 32bpp request, so the returned buffer had alpha = 0 everywhere → `mb > 127`
			-- was never true → every pixel counted as opaque, and the cursor was drawn as
			-- one solid black square. Measured: a 32×32 mask really does contain 297
			-- "transparent" pixels — exactly that number. Correct approach: request biBitCount=1 and read the bits.
			local mask = nil
			if ii.hbmMask ~= nil then
				local mrow = math.floor((w + 31) / 32) * 4 -- 1bpp rows are 4-byte aligned
				local mbuf = ffi.new("unsigned char[?]", mrow * h)
				local mbmi = ffi.new("FXBMIX")
				local mh = mbmi.bmiHeader
				mh.biSize = 40
				mh.biWidth = w
				mh.biHeight = h
				mh.biPlanes = 1
				mh.biBitCount = 1 -- key: 1bpp
				mh.biCompression = 0
				if gdi32.GetDIBits(hdc, ii.hbmMask, 0, h, mbuf, mbmi, 0) ~= 0 then
					mask = ffi.string(mbuf, mrow * h)
					mask = mask -- bytes are read below as (srow + x/8)
				end
			end

			-- ============ color bitmap: also read at its own bit depth ============
			-- 32bpp (with alpha) and 8bpp (indexed + palette) need separate branches.
			local color, pal = nil, nil
			if ii.hbmColor ~= nil then
				local cbmi = ffi.new("FXBMIX")
				local ch = cbmi.bmiHeader
				ch.biSize = 40
				ch.biWidth = w
				ch.biHeight = h
				ch.biPlanes = 1
				ch.biBitCount = 32
				ch.biCompression = 0
				local cbuf = ffi.new("unsigned char[?]", n * 4)
				if gdi32.GetDIBits(hdc, ii.hbmColor, 0, h, cbuf, cbmi, 0) ~= 0 then
					color = ffi.string(cbuf, n * 4)
				end
			end
			gdi32.DeleteDC(hdc)

			if color ~= nil or mask ~= nil then
				-- 32bpp cursors carry real alpha; old 8bpp cursors have alpha = 0 always,
				-- so use the AND mask for transparency instead (white in the mask = transparent)
				local has_alpha = false
				if color ~= nil then
					for i = 1, n do
						if color:byte(i * 4) > 0 then
							has_alpha = true
							break
						end
					end
				end

				-- no usable alpha and no mask → this grab is invalid; let the caller retry / fall back
				if color ~= nil and not has_alpha and mask == nil then
					if ii.hbmColor ~= nil then gdi32.DeleteObject(ii.hbmColor) end
					if ii.hbmMask  ~= nil then gdi32.DeleteObject(ii.hbmMask)  end
					return nil
				end

				local mrow = math.floor((w + 31) / 32) * 4
				local px = {}
				local opaque = 0
				for y = 0, h - 1 do
					local my = h - 1 - y          -- the mask is bottom-up too
					local srow = my * mrow        -- mask stride at 1bpp
					local crow = my * w * 4       -- color stride at 32bpp
					for x = 0, w - 1 do
						local b, g, r, a = 0, 0, 0, 0
						if color ~= nil then
							local co = crow + x * 4
							b, g, r, a = color:byte(co + 1, co + 4)
						end
						if not has_alpha then
							-- 1bpp: bit set = transparent (white), clear = opaque
							local bitv = 0
							if mask ~= nil then
								local byte = mask:byte(srow + math.floor(x / 8) + 1) or 0
								bitv = bit.band(byte, bit.lshift(1, 7 - (x % 8)))
							end
							a = (bitv ~= 0) and 0 or 255
						end
						if a == 0 then
							r, g, b = 0, 0, 0
						else
							opaque = opaque + 1
						end
						px[#px + 1] = string.char(r or 0, g or 0, b or 0, a)
					end
				end

				-- a frame with no opaque pixels at all = invalid (grab timing, or the cursor is hidden);
				-- keeping it only makes the animation flash empty. Drop it.
				if opaque == 0 then
					if ii.hbmColor ~= nil then gdi32.DeleteObject(ii.hbmColor) end
					if ii.hbmMask  ~= nil then gdi32.DeleteObject(ii.hbmMask)  end
					return nil
				end

				rgba = table.concat(px)
			end
		end
	end

	if ii.hbmColor ~= nil then gdi32.DeleteObject(ii.hbmColor) end
	if ii.hbmMask  ~= nil then gdi32.DeleteObject(ii.hbmMask)  end
	if rgba == nil then
		return nil
	end
	return w, h, hotx, hoty, rgba
end

local CURSOR_SAMPLES = 5      -- how many samples (to reconstruct .ani animations)
local CURSOR_SAMPLE_S  = 0.09 -- sample interval (seconds)
local CURSOR_MAX_FRAMES = 8

-- Note: the next 4 functions must all be called inside a graphics context (render_data / after enter_graphics)
local function cursor_clear(d)
	-- Each clear bumps a "sample serial": it goes into the temp PNG filename, so no regrab
	-- (shape change / theme change / button click) can ever collide with an old filename —
	-- which also sidesteps the texture-cache-by-path problem where a new cursor showed the old image.
	d.cur_seq = (d.cur_seq or 0) + 1
	for i = 1, #(d.cur_frames or {}) do
		local fr = d.cur_frames[i]
		if fr ~= nil and fr.tex ~= nil then
			obs.gs_texture_destroy(fr.tex)
		end
	end
	d.cur_frames = {}
	d.cur_now = nil
	d.cur_probe_i = nil
	d.cur_probe_t = nil
	if d.cur_png_tex ~= nil then
		obs.gs_texture_destroy(d.cur_png_tex)
		d.cur_png_tex = nil
	end
end

local function cursor_add_frame(d, w, h, hx, hy, rgba)
	-- [anti flash-to-black] sanity-check before the texture is created, keep bad frames out.
	-- Sampling grabs several frames back to back; during that window the cursor may be
	-- mid-animation, or the GPU/desktop compositor may be swapping drawing surfaces, so a
	-- grab can come back "almost fully transparent" or "almost fully black". Once such a
	-- frame enters the multi-frame loop it plays back as a cursor flashing black at a regular interval.
	local n = w * h
	if n <= 0 then
		return
	end
	local opaque, black = 0, 0
	for i = 0, n - 1 do
		local o = i * 4 + 1
		local r, g, b, a = rgba:byte(o, o + 3)
		if a > 0 then
			opaque = opaque + 1
			if r < 16 and g < 16 and b < 16 then
				black = black + 1
			end
		end
	end
	-- too few opaque pixels → an empty frame, drop it
	if opaque < n * 0.02 then
		return
	end
	-- almost all opaque pixels are black → the classic "black square" leftover, drop it.
	-- A healthy 32×32 cursor measures 71% opaque with 18% of that black — far from this threshold.
	if black >= opaque * 0.98 then
		return
	end
	local frame_opaque = opaque -- used to pick the most solid frame when there are 2

	local sum = crc32(rgba) -- content fingerprint: identical frames aren't loaded twice
	for i = 1, #d.cur_frames do
		if d.cur_frames[i].hash == sum then
			return
		end
	end
	if #d.cur_frames >= CURSOR_MAX_FRAMES then
		return
	end
	local dir = tmp_dir()
	if dir == "" then
		return
	end
	local hs = string.match(tostring(cursor_ci.hCursor), "0x(%x+)") or "x"
	local path = dir .. "mousefx_cur_" .. hs .. "_" .. tostring(d.cur_seq or 0) ..
		"_" .. tostring(#d.cur_frames) .. ".png"
	if not write_file(path, png_encode(w, h, rgba)) then
		return
	end
	local tex = obs.gs_texture_create_from_file(path)
	kernel32.DeleteFileA(path) -- already in VRAM, the file doesn't need to stay
	if tex == nil then
		return
	end
	d.cur_frames[#d.cur_frames + 1] = { tex = tex, hash = sum, opaque = frame_opaque }
	d.cur_dw, d.cur_dh = w, h
	d.cur_hx, d.cur_hy = hx, hy
	d.cur_u0x, d.cur_u0y = 0.0, 0.0
	d.cur_u1x, d.cur_u1y = 1.0, 1.0
end

-- Manual mode: load a PNG (multi-frame = horizontally tiled)
local function cursor_load_png(d)
	local path = S.cur_img
	if path == nil or path == "" then
		path = "cursor.png"
	end
	local c1 = string.sub(path, 1, 1)
	local c2 = string.sub(path, 2, 2)
	if c2 ~= ":" and c1 ~= "/" and c1 ~= "\\" then
		path = script_path() .. path -- relative paths resolve against the script's folder
	end
	local tex = obs.gs_texture_create_from_file(path)
	if tex == nil then
		return false
	end
	local tw = tonumber(obs.gs_texture_get_width(tex))  or 0
	local th = tonumber(obs.gs_texture_get_height(tex)) or 0
	if tw <= 0 or th <= 0 then
		obs.gs_texture_destroy(tex)
		return false
	end
	local frames = S.cur_frames
	if frames == nil or frames <= 0 then
		frames = math.max(1, math.floor(tw / th + 0.5)) -- horizontal frames: width/height
	end
	frames = math.min(frames, tw)
	d.cur_png_tex = tex
	d.cur_png_frames = frames
	d.cur_png_tw = tw
	d.cur_dw, d.cur_dh = math.floor(tw / frames + 0.5), th
	d.cur_hx = S.cur_hot_x
	d.cur_hy = S.cur_hot_y
	log("Manual cursor image: " .. path .. "  " .. tostring(tw) .. "x" .. tostring(th) ..
		", " .. tostring(frames) .. " frames, hotspot " .. tostring(S.cur_hot_x) .. "," ..
		tostring(S.cur_hot_y))
	return true
end

local function cursor_hot_set(d)
	-- [anti flash-to-black] same reasoning as the auto-grab side: 2 frames alternating looks like flicker.
	-- So a 2-frame image is shown statically as frame 1 instead.
	if d.cur_png_tex ~= nil and d.cur_png_frames > 2 then
		local f = d.cur_png_frames
		local i = 1 + math.floor(d.clock * (S.cur_fps or 10.0)) % f
		local tw = d.cur_png_tw
		-- inset half a pixel on each side so point sampling can't touch the neighbouring frame
		d.cur_u0x = ((i - 1) * d.cur_dh + 0.5) / tw
		d.cur_u1x = (i * d.cur_dh - 0.5) / tw
		d.cur_u0y, d.cur_u1y = 0.0, 1.0
	elseif d.cur_png_tex ~= nil then
		-- single frame / two frames: always frame 1
		if d.cur_png_frames == 2 then
			local tw = d.cur_png_tw
			d.cur_u0x = (0 * d.cur_dh + 0.5) / tw
			d.cur_u1x = (1 * d.cur_dh - 0.5) / tw
			d.cur_u0y, d.cur_u1y = 0.0, 1.0
		else
			d.cur_u0x, d.cur_u0y = 0.0, 0.0
			d.cur_u1x, d.cur_u1y = 1.0, 1.0
		end
	end
end

local function cursor_update(d)
	-- REGRAB is the "Regrab cursor" button's counter: putting it in the key means one click
	-- makes every instance run "clear → resample".
	local key = tostring(S.cur_on) .. "|" .. tostring(S.cur_auto) .. "|" ..
		tostring(S.cur_img) .. "|" .. tostring(S.cur_frames) .. "|" ..
		tostring(S.cur_hot_x) .. "," .. tostring(S.cur_hot_y) .. "|" ..
		tostring(S.cur_fps) .. "|" .. tostring(REGRAB)
	if d.cur_key ~= key then
		cursor_clear(d)
		d.cur_key = key
		d.cur_handle = nil
		d.cur_mode = nil
		d.cur_png_bad = false
		-- every settings change / "Regrab cursor" click gets a fresh round of feedback
		d.cur_ok_logged = false
		d.cur_fail_logged = false
	end
	if not S.cur_on then
		d.cur_now = nil
		return
	end
	if not d.inside then
		d.cur_now = nil
		return
	end

	if S.cur_auto then
		cursor_ci.cbSize = ffi.sizeof(cursor_ci)
		local h = nil
		if user32.GetCursorInfo(cursor_ci) ~= 0 then
			h = cursor_ci.hCursor
		end
		local hs = (h ~= nil) and (string.match(tostring(h), "0x(%x+)") or "x") or "none"
		if hs ~= d.cur_handle then
			cursor_clear(d) -- shape/theme changed: resample (clearing also bumps the sample serial)
			d.cur_handle = hs
			d.cur_mode = "probe"
			d.cur_probe_i = 0
			d.cur_probe_t = nil
			d.cur_ok_logged = false
			d.cur_fail_logged = false
		end
		if d.cur_mode == "probe" then
			if d.cur_probe_t == nil or (d.clock - d.cur_probe_t) >= CURSOR_SAMPLE_S then
				d.cur_probe_t = d.clock
				local w, hh, hx, hy, rgba = grab_cursor()
				if w ~= nil then
					cursor_add_frame(d, w, hh, hx, hy, rgba)
				end
				-- advance the counter either way: a failed grab must still finish the sampling stage,
				-- otherwise it's stuck in probe forever and never reaches the cursor-image fallback.
				d.cur_probe_i = (d.cur_probe_i or 0) + 1
			end
			if (d.cur_probe_i or 0) >= CURSOR_SAMPLES then
				d.cur_mode = "ready"
				if #d.cur_frames == 0 then
					if not d.cur_fail_logged then
						d.cur_fail_logged = true
						log("Auto cursor grab failed; falling back to the cursor image or the built-in arrow")
					end
				elseif not d.cur_ok_logged then
					d.cur_ok_logged = true
					log("System cursor grabbed: " .. tostring(d.cur_dw) .. "x" .. tostring(d.cur_dh) ..
						", hotspot " .. tostring(d.cur_hx) .. "," .. tostring(d.cur_hy) ..
						", " .. tostring(#d.cur_frames) .. " frames")
				end
			end
		end
		-- a grab has failed before: retry every 2 s. On success it switches back to the drawn cursor
		-- by itself; meanwhile the image / built-in arrow holds the frame, so there's no blank window.
		if d.cur_mode == "ready" and #d.cur_frames == 0 then
			if d.cur_retry_t == nil or (d.clock - d.cur_retry_t) >= 2.0 then
				d.cur_retry_t = d.clock
				d.cur_mode = "probe"
				d.cur_probe_i = 0
				d.cur_probe_t = nil
			end
		end
		if #d.cur_frames > 0 then
			-- [anti flash-to-black] animation frame selection.
			-- Sampling may catch only 2 distinct frames (or 1), and one of them is often an
			-- in-between leftover. Playing those 2 alternating reads as a regular black flash. So:
			--
			--   · 1 frame → show it statically, no animation (most stable)
			--   · 2 frames → no alternation, pin the "most solid" one
			--     (most opaque pixels — usually the main shape; leftovers cover less area)
			--   · 3+ frames → actually loop at the frame rate
			local n = #d.cur_frames
			local idx = 1
			if n == 1 then
				idx = 1
			elseif n == 2 then
				local a, b = d.cur_frames[1], d.cur_frames[2]
				idx = ((a.opaque or 0) >= (b.opaque or 0)) and 1 or 2
			else
				idx = 1 + math.floor(d.clock * (S.cur_fps or 10.0)) % n
			end
			d.cur_now = d.cur_frames[idx].tex
			return
		end
		-- auto failed → fall through to the manual image
	end

	if d.cur_png_tex == nil then
		if d.cur_png_bad then
			d.cur_now = nil -- the image failed too; stop retrying every frame
			return
		end
		if not cursor_load_png(d) then
			d.cur_png_bad = true
			d.cur_now = nil
			return
		end
	end
	if d.cur_png_tex ~= nil then
		cursor_hot_set(d)
		d.cur_now = d.cur_png_tex
	end
end

-- ---------------------------------------------------------------- instances
local EFFECT_FILE   = "mouse-fx.effect"
local BLANK_FILE    = "blank.png"

local PARAM_NAMES = {
	"mouse_pos", "img_size", "fx_center",
	"hl_on", "hl_radius", "hl_thickness", "hl_color",
	"hl_ring_on", "hl_fill_on", "hl_fill_alpha",
	"glow_on", "glow_radius", "glow_alpha",
	"ring_thickness", "dot_color",
	"cur_on", "cur_scale", "cur_fill", "cur_line",
	"cur_use_img", "cimg_size", "cimg_hot", "cimg_uv0", "cimg_uv1",
}

local function new_data(source)
	local d = {}
	d.source  = source
	d.width   = 1
	d.height  = 1
	d.clock   = 0
	d.px      = 0
	d.py      = 0
	d.init    = false
	d.inside  = true
	d.clicks  = {}
	d.trail   = {}
	d.trail_t = 0
	d.lb = false
	d.rb = false
	d.mb = false
	d.cur_frames = {}
	d.cur_now = nil

	local dir = script_path()
	obs.obs_enter_graphics()
	d.effect = obs.gs_effect_create_from_file(dir .. EFFECT_FILE, nil)
	if d.effect ~= nil then
		d.p = {}
		for _, n in ipairs(PARAM_NAMES) do
			d.p[n] = obs.gs_effect_get_param_by_name(d.effect, n)
		end
		d.ring  = {}
		d.ringc = {}
		for i = 0, MAX_RINGS - 1 do
			d.ring[i + 1]  = obs.gs_effect_get_param_by_name(d.effect, "ring" .. i)
			d.ringc[i + 1] = obs.gs_effect_get_param_by_name(d.effect, "ringc" .. i)
		end
		d.dot = {}
		for i = 0, MAX_DOTS - 1 do
			d.dot[i + 1] = obs.gs_effect_get_param_by_name(d.effect, "dot" .. i)
		end
		d.blank = obs.gs_texture_create_from_file(dir .. BLANK_FILE)
		d.v2 = obs.vec2()
		d.v4 = obs.vec4()
		d.p.cimg = obs.gs_effect_get_param_by_name(d.effect, "cimg")

		local missing = {}
		for _, n in ipairs(PARAM_NAMES) do
			if d.p[n] == nil then missing[#missing + 1] = n end
		end
		for i = 0, MAX_RINGS - 1 do
			if d.ring[i + 1] == nil then missing[#missing + 1] = "ring" .. i end
			if d.ringc[i + 1] == nil then missing[#missing + 1] = "ringc" .. i end
		end
		for i = 0, MAX_DOTS - 1 do
			if d.dot[i + 1] == nil then missing[#missing + 1] = "dot" .. i end
		end
		if #missing > 0 then
			logerr("Effect parameters that couldn't be fetched: " .. table.concat(missing, ","))
		end
		if d.blank == nil then
			logerr("blank.png failed to load: " .. dir .. BLANK_FILE)
		end
	else
		logerr("effect failed to load: " .. dir .. EFFECT_FILE)
	end
	obs.obs_leave_graphics()
	return d
end

-- In OBS 32's Lua bindings vec2/vec4 are objects: construct empty, then fill with *_set
local function set_v2(d, param, x, y)
	if param == nil then
		return
	end
	obs.vec2_set(d.v2, x, y)
	obs.gs_effect_set_vec2(param, d.v2)
end

local function set_v4(d, param, x, y, z, w)
	if param == nil then
		return
	end
	obs.vec4_set(d.v4, x, y, z, w)
	obs.gs_effect_set_vec4(param, d.v4)
end

local function free_data(d)
	obs.obs_enter_graphics()
	cursor_clear(d)
	if d.effect ~= nil then
		if d.blank ~= nil then
			obs.gs_texture_destroy(d.blank)
		end
		obs.gs_effect_destroy(d.effect)
		d.effect = nil
	end
	obs.obs_leave_graphics()
end

local function add_click(d, r, g, b, a)
	table.insert(d.clicks, { x = d.px, y = d.py, t = d.clock, r = r, g = g, b = b, a = a })
	if #d.clicks > MAX_RINGS then
		table.remove(d.clicks, 1)
	end
end

-- The target capture source's own cursor would cover the highlight; "cursor takeover" puts it underneath
local CURSOR_SOURCES = {
	monitor_capture = true,
	window_capture  = true,
	game_capture    = true,
}

-- Hint de-duplication: one report per instance per reason (a changed reason re-arms it);
-- across instances the same reason is reported at most once per 60 s — repeatedly deleting and
-- re-adding sources or rebuilding instances on scene switches won't flood the log.
-- Goes through log() (INFO): off by default, never pops; turn on "Output log" to see everything.
-- (These hints used to go through logerr and pop unconditionally: OBS raises the script log window
local WARN_SEEN = {}
local function now_ms()
	local ok, v = pcall(function()
		return tonumber(kernel32.GetTickCount64())
	end)
	if ok then
		return v or 0
	end
	return 0
end
local function warn_once(d, reason, nm, msg)
	local key = tostring(reason) .. "|" .. tostring(nm or "")
	if d.warn_key == key then
		return
	end
	d.warn_key = key
	local t = now_ms()
	local seen = WARN_SEEN[key]
	if seen ~= nil and (t - seen) < 60000 then
		return
	end
	WARN_SEEN[key] = t
	log(msg)
end

-- Find the capture source whose "Capture cursor" should be turned off:
--   filter instance → its target source (borrowed ref — must NOT be released)
--   standalone      → take_src (empty → fall back to "zoom link source") (owned ref — must release)
local function takeover_target(d)
	if obs.obs_source_get_id(d.source) == "mouse_fx_filter" then
		if not obs.obs_source_enabled(d.source) then
			return nil, false -- filter is disabled; leave the capture source alone
		end
		return obs.obs_filter_get_target(d.source), false
	end
	local nm = S.take_src
	if nm == nil or nm == "" then
		nm = S.follow_source
	end
	if nm == nil or nm == "" then
		return nil, false
	end
	local ok, src = pcall(obs.obs_get_source_by_name, nm)
	if ok and src ~= nil then
		return src, true
	end
	return nil, false
end

local function apply_cursor_takeover(d)
	if d.cur_t ~= nil and (d.clock - d.cur_t) < 2.0 then
		return
	end
	d.cur_t = d.clock

	local target, owned = takeover_target(d)
	if target == nil then
		local is_filter = obs.obs_source_get_id(d.source) == "mouse_fx_filter"
		-- a user-disabled filter is a normal state (don't touch the capture source), no warning
		if is_filter and not obs.obs_source_enabled(d.source) then
			return
		end
		if S.take_cursor and S.cur_on then
			if is_filter then
				warn_once(d, "no_parent", "",
					"Cursor takeover: the filter isn't attached to any source, so there's no target to turn \"Capture cursor\" off on")
			else
				local nm = S.take_src
				if nm == nil or nm == "" then
					nm = S.follow_source
				end
				if nm == nil or nm == "" then
					warn_once(d, "no_target", "",
						"Cursor takeover: no target to take over. For a standalone layer, set \"Capture source name\" to your capture source, " ..
						"or select \"Zoom link source\" (used when the takeover name is empty). Otherwise \"Capture cursor\" stays on — " ..
						"the translucent fill smears over the cursor, and with a zoom script you get two cursors")
				else
					warn_once(d, "no_source", nm,
						"Cursor takeover: no capture source named '" .. tostring(nm) .. "' (renamed or deleted?). " ..
						"\"Capture cursor\" can't be turned off, so two cursors will show on screen")
				end
			end
		end
		return
	end
	local ok_id, id = pcall(obs.obs_source_get_id, target)
	if not ok_id or id == nil or not CURSOR_SOURCES[id] then
		if owned then obs.obs_source_release(target) end
		warn_once(d, "bad_type", tostring(obs.obs_source_get_name(target)),
			"Cursor takeover: the target isn't a display/window/game capture, so its \"Capture cursor\" can't be turned off")
		return
	end

	local want = S.take_cursor and S.cur_on
	local ok_st, st = pcall(obs.obs_source_get_settings, target)
	if not ok_st or st == nil then
		if owned then obs.obs_source_release(target) end
		warn_once(d, "no_settings", tostring(obs.obs_source_get_name(target)),
			"Cursor takeover: couldn't read the target's settings, skipping this round")
		return
	end
	local now = obs.obs_data_get_bool(st, "capture_cursor")
	if want and now then
		obs.obs_data_set_bool(st, "capture_cursor", false)
		obs.obs_source_update(target, st)
		d.took_cursor = true
		log("Cursor takeover: turned \"Capture cursor\" off on '" .. tostring(obs.obs_source_get_name(target)) ..
			"', the script now draws the cursor above the highlight ring")
	elseif not want and d.took_cursor and not now then
		obs.obs_data_set_bool(st, "capture_cursor", true)
		obs.obs_source_update(target, st)
		d.took_cursor = false
		log("Cursor takeover disabled: \"Capture cursor\" restored on the capture source")
	end
	obs.obs_data_release(st)
	if owned then obs.obs_source_release(target) end
end

-- State update: read coordinates and buttons, advance animation.
-- Doesn't rely on video_tick (OBS skips tick while a source is inactive); render_frame calls it too.
local function update_state(d)
	local ms = tonumber(kernel32.GetTickCount64())
	if d.last_ms == ms then
		return
	end
	if d.t0_ms == nil then
		d.t0_ms = ms
	end
	d.last_ms = ms
	d.clock = (ms - d.t0_ms) / 1000.0

	-- A filter has no size of its own: use the target source's size; a standalone layer uses its canvas size
	local is_filter = (obs.obs_source_get_id(d.source) == "mouse_fx_filter")
	local target = nil
	if is_filter then
		target = obs.obs_filter_get_target(d.source)
	end
	local host = (target ~= nil) and target or d.source
	local w = obs.obs_source_get_base_width(host)
	local h = obs.obs_source_get_base_height(host)
	if w <= 0 or h <= 0 then
		return
	end
	d.width  = w
	d.height = h

	apply_cursor_takeover(d)

	-- auto mode: periodically read the monitor rect the capture source is on
	if S.region_mode == 0 then
		if is_filter then
			if d.auto_t == nil or (d.clock - d.auto_t) > 2.0 then
				d.auto_t = d.clock
				local r = detect_source_region(d.source)
				if r ~= nil then
					d.auto = r
					if not d.auto_logged then
						d.auto_logged = true
						log("Auto-matched capture monitor: " .. tostring(r[1]) .. "," ..
							tostring(r[2]) .. " " .. tostring(r[3]) .. "x" .. tostring(r[4]))
					end
				elseif not d.auto_logged then
					d.auto_failed = (d.auto_failed or 0) + 1
					if d.auto_failed >= 3 then
						d.auto_logged = true
						local s = {}
						for _, mm in ipairs(enum_monitors()) do
							s[#s + 1] = tostring(mm.id) .. " [" .. tostring(mm.left) .. "," ..
								tostring(mm.top) .. " " .. tostring(mm.w) .. "x" .. tostring(mm.h) .. "]"
						end
						log("Auto-match failed, falling back to the primary monitor. Monitors = " .. table.concat(s, " | "))
					end
				end
			end
		else
			-- A standalone source has no target: auto mode first reads the monitor actually captured by
			-- the linked / takeover source (multi-monitor with zero config: switch the monitor in the
			-- capture source and this follows within 2 s, size included); only if that fails, specific monitor → primary.
			local nm = S.follow_source
			if nm == nil or nm == "" then
				nm = S.take_src
			end
			if nm ~= nil and nm ~= "" then
				if d.auto_nm ~= nm then
					-- linked source changed: re-probe, re-arm the log
					d.auto_nm = nm
					d.auto_logged = false
					d.auto_failed = 0
					d.auto_size = nil
				end
				if d.auto_t == nil or (d.clock - d.auto_t) > 2.0 then
					d.auto_t = d.clock
					local r = detect_named_source_region(nm)
					if r ~= nil then
						d.auto = r
						if not d.auto_logged then
							d.auto_logged = true
							log("Standalone auto-match: linked source '" .. nm .. "' captures " ..
								tostring(r[1]) .. "," .. tostring(r[2]) .. " " ..
								tostring(r[3]) .. "x" .. tostring(r[4]))
						end
						local sz = tostring(r[3]) .. "x" .. tostring(r[4])
						if d.auto_size ~= sz then
							d.auto_size = sz
							log("Standalone layer size now follows the captured monitor: " .. sz)
						end
					elseif not d.auto_logged then
						d.auto_failed = (d.auto_failed or 0) + 1
						if d.auto_failed >= 3 then
							d.auto_logged = true
							log("Standalone auto-match: can't read the monitor captured by '" .. nm ..
								"' (source deleted / not a display capture / monitor detection failed), " ..
								"falling back to \"Specific monitor\" / primary. When recording multiple monitors, make sure \"Zoom link source\" " ..
								"points at the capture source for the monitor you're recording")
						end
					end
				end
			end
			-- no link/takeover source configured: fall back to the monitor picked in "specific monitor" (old behaviour)
			if d.auto == nil and S.monitor_sel ~= "" then
				local m = find_monitor(S.monitor_sel)
				if m ~= nil then
					d.auto = { m.left, m.top, m.w, m.h }
					if not d.auto_logged then
						d.auto_logged = true
						log("Standalone auto: using specific monitor " .. tostring(m.left) .. "," ..
							tostring(m.top) .. " " .. tostring(m.w) .. "x" .. tostring(m.h))
					end
				end
			end
		end
	else
		d.auto = nil
	end

	if not d.tick_logged then
		d.tick_logged = true
		log("Frame size " .. tostring(w) .. "x" .. tostring(h) .. ", mapped region " ..
			tostring(d.auto and d.auto[1] or S.region_left) .. "," ..
			tostring(d.auto and d.auto[2] or S.region_top) .. " " ..
			tostring(d.auto and d.auto[3] or S.region_w) .. "x" ..
			tostring(d.auto and d.auto[4] or S.region_h))
	end

	local rl, rt, rw, rh
	if d.auto ~= nil then
		rl, rt, rw, rh = d.auto[1], d.auto[2], d.auto[3], d.auto[4]
	else
		rl, rt, rw, rh = S.region_left, S.region_top, S.region_w, S.region_h
	end
	if rw <= 0 then rw = w end
	if rh <= 0 then rh = h end

	if user32.GetCursorPos(cursor_pt) == 0 then
		return
	end

	local mx = tonumber(cursor_pt.x) or 0
	local my = tonumber(cursor_pt.y) or 0

	-- Zoom link: standalone sources only. The filter version already sits downstream of the crop
	-- filter and gets cropped and stretched with the frame, so it aligns for free; a standalone layer must remap itself.
	local sx, sy
	local zf = 1.0
	if not is_filter then
		local cl, ct, cw, ch = follow_crop(d)
		if cw ~= nil then
			-- convert the cursor into the linked source's frame space, subtract the crop origin, then
			-- scale by "frame size / crop size" into canvas coordinates
			sx = (mx - rl - cl) * (w / cw) * S.zoom + S.offset_x
			sy = (my - rt - ct) * (h / ch) * S.zoom + S.offset_y
			zf = w / cw
			if not d.follow_logged then
				d.follow_logged = true
				log("Zoom link: '" .. S.follow_source .. "' crop rect " ..
					tostring(cl) .. "," .. tostring(ct) .. " " ..
					tostring(cw) .. "x" .. tostring(ch) .. ", factor " ..
					string.format("%.2f", zf))
			end
		end
	end
	if sx == nil then
		sx = (mx - rl) * (w / rw) * S.zoom + S.offset_x
		sy = (my - rt) * (h / rh) * S.zoom + S.offset_y
	end
	d.zf = zf

	if S.smooth >= 1.0 or not d.init then
		d.px, d.py = sx, sy
		d.init = true
	else
		d.px = d.px + (sx - d.px) * S.smooth
		d.py = d.py + (sy - d.py) * S.smooth
	end

	d.inside = (d.px > -400 and d.px < w + 400 and d.py > -400 and d.py < h + 400)

	if S.click_on then
		local lb = bit.band(user32.GetAsyncKeyState(VK_LBUTTON), 0x8000) ~= 0
		local rb = bit.band(user32.GetAsyncKeyState(VK_RBUTTON), 0x8000) ~= 0
		local mb = bit.band(user32.GetAsyncKeyState(VK_MBUTTON), 0x8000) ~= 0
		if lb and not d.lb then add_click(d, S.clk_r, S.clk_g, S.clk_b, S.clk_a) end
		if rb and not d.rb then add_click(d, S.cr_r, S.cr_g, S.cr_b, S.cr_a) end
		if mb and not d.mb then add_click(d, S.cm_r, S.cm_g, S.cm_b, S.cm_a) end
		d.lb, d.rb, d.mb = lb, rb, mb

		local life = S.click_duration + (S.ripple_count - 1) * S.ripple_delay
		while #d.clicks > 0 and (d.clock - d.clicks[1].t) > life do
			table.remove(d.clicks, 1)
		end
	else
		d.clicks = {}
	end

	if S.trail_on then
		if (d.clock - d.trail_t) >= S.trail_step then
			table.insert(d.trail, { x = d.px, y = d.py })
			d.trail_t = d.clock
			while #d.trail > S.trail_count do
				table.remove(d.trail, 1)
			end
		end
	elseif #d.trail > 0 then
		d.trail = {}
	end
end

local function render_data(d)
	if d.effect == nil or d.p == nil then
		return
	end
	update_state(d)
	if d.width <= 0 then
		return
	end
	local e = d.effect
	local p = d.p

	if not d.render_logged then
		d.render_logged = true
		log("First frame rendered (" .. tostring(d.width) .. "x" .. tostring(d.height) .. ")")
	end

	set_v2(d, p.mouse_pos, d.px, d.py)
	set_v2(d, p.img_size, d.width, d.height)
	-- zoom factor: when a standalone layer follows obs-zoom-to-mouse, highlight sizes scale with it
	local zf = d.zf or 1.0
	-- fill / glow center: shifted down so the highlight doesn't cover the system cursor
	set_v2(d, p.fx_center, d.px, d.py + S.fx_offset_y * zf)

	obs.gs_effect_set_float(p.hl_on, (S.hl_on and d.inside) and 1.0 or 0.0)
	obs.gs_effect_set_float(p.hl_radius, S.hl_radius * zf)
	obs.gs_effect_set_float(p.hl_thickness, S.hl_thickness * zf)
	obs.gs_effect_set_float(p.hl_ring_on, S.hl_ring_on)
	obs.gs_effect_set_float(p.hl_fill_on, S.hl_fill_on)
	obs.gs_effect_set_float(p.hl_fill_alpha, S.hl_fill_opacity)
	set_v4(d, p.hl_color, S.hl_r, S.hl_g, S.hl_b, S.hl_a)

	obs.gs_effect_set_float(p.glow_on, (S.glow_on and d.inside) and 1.0 or 0.0)
	obs.gs_effect_set_float(p.glow_radius, S.glow_radius * zf)
	obs.gs_effect_set_float(p.glow_alpha, S.glow_opacity)

	obs.gs_effect_set_float(p.cur_on, (S.cur_on and d.inside) and 1.0 or 0.0)
	obs.gs_effect_set_float(p.cur_scale, S.cur_scale * zf)
	set_v4(d, p.cur_fill, S.cf_r, S.cf_g, S.cf_b, S.cf_a)
	set_v4(d, p.cur_line, S.cl_r, S.cl_g, S.cl_b, S.cl_a)

	-- image cursor: drawn last = topmost, so the highlight ring always sits *under* the cursor
	-- report each error once, and via log rather than logerr:
	-- the image → built-in arrow fallback already covers it; this is recoverable and shouldn't pop the script log.
	local ok_cur, err_cur = pcall(cursor_update, d)
	if not ok_cur then
		d.cur_now = nil
		local es = tostring(err_cur)
		if not CUR_ERR_SEEN[es] then
			CUR_ERR_SEEN[es] = true
			log("Cursor grab/load error (fell back to the built-in arrow): " .. es)
		end
	end
	local use_img = 0.0
	local tex = d.cur_now
	if tex == nil then
		tex = d.blank -- bind a valid texture so we never sample an empty one
	end
	if tex ~= nil then
		use_img = (d.cur_now ~= nil) and 1.0 or 0.0
		if use_img > 0.5 then
			set_v2(d, p.cimg_size, d.cur_dw or 32, d.cur_dh or 32)
			set_v2(d, p.cimg_hot, d.cur_hx or 0, d.cur_hy or 0)
			set_v2(d, p.cimg_uv0, d.cur_u0x or 0.0, d.cur_u0y or 0.0)
			set_v2(d, p.cimg_uv1, d.cur_u1x or 1.0, d.cur_u1y or 1.0)
		else
			set_v2(d, p.cimg_size, 4, 4)
			set_v2(d, p.cimg_hot, 0, 0)
			set_v2(d, p.cimg_uv0, 0.0, 0.0)
			set_v2(d, p.cimg_uv1, 1.0, 1.0)
		end
		if p.cimg ~= nil then
			obs.gs_effect_set_texture(p.cimg, tex)
		end
	end
	obs.gs_effect_set_float(p.cur_use_img, (S.cur_on and d.inside) and use_img or 0.0)

	set_v4(d, p.dot_color, S.dot_r, S.dot_g, S.dot_b, S.dot_a)
	obs.gs_effect_set_float(p.ring_thickness, S.ring_thickness * zf)

	-- click ripples
	local n = 0
	for i = 1, #d.clicks do
		local ck = d.clicks[i]
		for r = 0, S.ripple_count - 1 do
			if n >= MAX_RINGS then
				break
			end
			local age = d.clock - ck.t - r * S.ripple_delay
			if age >= 0 and age < S.click_duration then
				local prog = age / S.click_duration
				local ease = 1 - math.pow(1 - prog, 3)
				local rad  = S.start_radius + (S.end_radius - S.start_radius) * ease
				rad = rad * zf
				local alp  = math.pow(1 - prog, 1.4) * ck.a
				n = n + 1
				set_v4(d, d.ring[n], ck.x, ck.y, rad, alp)
				set_v4(d, d.ringc[n], ck.r, ck.g, ck.b, ck.a * S.fill_opacity)
			end
		end
	end
	for i = n + 1, MAX_RINGS do
		set_v4(d, d.ring[i], 0, 0, 0, 0)
		set_v4(d, d.ringc[i], 0, 0, 0, 0)
	end

	-- trail
	if S.trail_on then
		local cnt = #d.trail
		for s = 0, MAX_DOTS - 1 do
			local node = d.trail[cnt - s]
			if node ~= nil and s < cnt then
				local f = 1 - s / S.trail_count
				if f < 0 then f = 0 end
				set_v4(d, d.dot[s + 1], node.x, node.y,
					S.trail_radius * zf * (0.35 + 0.65 * f), f * S.dot_a)
			else
				set_v4(d, d.dot[s + 1], 0, 0, 0, 0)
			end
		end
	else
		for s = 1, MAX_DOTS do
			set_v4(d, d.dot[s], 0, 0, 0, 0)
		end
	end

	obs.gs_blend_state_push()
	obs.gs_blend_function(obs.GS_BLEND_SRCALPHA, obs.GS_BLEND_INVSRCALPHA)
	while obs.gs_effect_loop(e, "Draw") do
		obs.gs_draw_sprite(d.blank, 0, d.width, d.height)
	end
	obs.gs_blend_state_pop()
end

-- ---------------------------------------------------------------- filter
local filter_def = {}
filter_def.id = "mouse_fx_filter"
filter_def.type = obs.OBS_SOURCE_TYPE_FILTER
filter_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO)

filter_def.get_name = function()
	return "Mouse Highlight Overlay (Mouse FX)"
end

filter_def.create = function(settings, source)
	return new_data(source)
end

filter_def.destroy = function(d)
	free_data(d)
end

filter_def.video_tick = function(d, seconds)
	update_state(d)
end

filter_def.video_render = function(d, effect)
	update_state(d)
	-- In OBS 32 the effect handed to a script can't be used for tech_end directly; take the default effect explicitly
	local eff = obs.obs_get_base_effect(obs.OBS_EFFECT_DEFAULT)
	obs.obs_source_process_filter_begin(d.source, obs.GS_RGBA,
		obs.OBS_ALLOW_DIRECT_RENDERING)
		-- This filter must output at full resolution (base 1920×1080): the crop-and-zoom filter sits ABOVE it
		-- (top of the filter array = the final output stage) and crops the zoomed region out of the full-size
		-- frame this filter produces. If this filter shrank its output there'd be nothing left to crop. Ring
		-- coordinates are computed against the base resolution too (d.width in update_state), so the crop filter
		obs.obs_source_process_filter_tech_end(d.source, eff, d.width, d.height, "Draw")
	render_data(d)
end

-- ---------------------------------------------------------------- standalone source
local source_def = {}
source_def.id = "mouse_fx_source"
source_def.type = obs.OBS_SOURCE_TYPE_INPUT
source_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO, obs.OBS_SOURCE_CUSTOM_DRAW)

source_def.get_name = function()
	return "Mouse Highlight Layer (Mouse FX)"
end

source_def.create = function(settings, source)
	return new_data(source)
end

source_def.destroy = function(d)
	free_data(d)
end

source_def.get_width = function(d)
	-- when "auto" detects the capture source's monitor, width/height follow that monitor (multi-monitor, zero config);
	-- only when detection fails (no linked source / source deleted) does the manual width apply
	if d.auto ~= nil and d.auto[3] ~= nil and d.auto[3] > 0 then
		return d.auto[3]
	end
	return S.canvas_w
end

source_def.get_height = function(d)
	if d.auto ~= nil and d.auto[4] ~= nil and d.auto[4] > 0 then
		return d.auto[4]
	end
	return S.canvas_h
end

source_def.video_tick = function(d, seconds)
	update_state(d)
end

source_def.video_render = function(d, effect)
	render_data(d)
end

-- ---------------------------------------------------------------- script panel
function script_description()
	return "Draws a self-drawn mouse overlay on the canvas: persistent highlight ring + click ripples + trail + cursor.\n" ..
	       "Usage 1 (recommended): add the \"Mouse Highlight Overlay\" filter to a Display / Window Capture source — it follows that monitor;\n" ..
	       "Usage 2: add a \"Mouse Highlight Layer\" source, drag it to the top, set \"Region\" to \"Auto\" and fill in\n" ..
	       "\"Zoom link source\" (the capture source for the monitor you're recording) — region and size both follow it,\n" ..
	       "so switching monitors needs no reconfiguration; \"Specific monitor\" pins it manually instead.\n" ..
	       "Cursor: the script turns off \"Capture cursor\" on the capture source and draws the live system cursor above the ring,\n" ..
	       "so the ring is always under the cursor; theme and shape changes follow automatically.\n" ..
	       "With obs-zoom-to-mouse: pick \"Zoom link source\" and a standalone layer stays aligned through the whole zoom.\n" ..
	       "Coordinates come from the Win32 API in real time — no external program involved."
end

function script_properties()
	local props = obs.obs_properties_create()

	obs.obs_properties_add_text(props, "sep_region", "—— Region ——", obs.OBS_TEXT_INFO)
	local p = obs.obs_properties_add_list(props, "region_mode", "Mouse coordinate region",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(p, "Auto (filter reads its target; standalone reads the monitor captured by \"Zoom link source\")", 0)
	obs.obs_property_list_add_int(p, "Primary monitor", 1)
	obs.obs_property_list_add_int(p, "Virtual desktop (map all monitors)", 2)
	obs.obs_property_list_add_int(p, "Custom (use the values below)", 3)
	obs.obs_property_list_add_int(p, "Specific monitor (use the dropdown below)", 4)
	obs.obs_properties_add_int(props, "custom_left", "Custom left", -8192, 8192, 1)
	obs.obs_properties_add_int(props, "custom_top", "Custom top", -8192, 8192, 1)
	obs.obs_properties_add_int(props, "custom_width", "Custom width", 16, 16384, 1)
	obs.obs_properties_add_int(props, "custom_height", "Custom height", 16, 16384, 1)
	obs.obs_properties_add_int(props, "offset_x", "Global offset X (fine tune)", -4096, 4096, 1)
	obs.obs_properties_add_int(props, "offset_y", "Global offset Y (fine tune)", -4096, 4096, 1)
	obs.obs_properties_add_float_slider(props, "zoom", "Scale correction", 0.1, 4.0, 0.01)

	-- specific monitor dropdown: used when region = "specific monitor"; also the fallback when "auto" can't read the link source
	local pmon = obs.obs_properties_add_list(props, "monitor_sel",
		"Specific monitor (used when region = \"Specific monitor\"; fallback when \"Auto\" can't read the link source)",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(pmon, "(none / use primary)", "")
	local mons = enum_monitors()
	for _, m in ipairs(mons) do
		local label = m.name
		if label == nil or label == "" then label = m.id end
		label = label .. "  [" .. tostring(m.left) .. "," .. tostring(m.top) ..
			" " .. tostring(m.w) .. "x" .. tostring(m.h) .. "]"
		obs.obs_property_list_add_string(pmon, label, m.id)
	end
	obs.obs_properties_add_text(props, "note_region",
		"A standalone layer (Mouse Highlight Layer) is a detached layer with no target, so \"Auto\" can't read a capture source.\n" ..
		"Pick the monitor you're recording under \"Specific monitor\" below, and set \"Layer width / height\" at the bottom\n" ..
		"to that monitor's resolution, or the axes won't line up.", obs.OBS_TEXT_INFO)

	-- zoom link source: standalone layer follows obs-zoom-to-mouse's crop zoom
	local pfol = obs.obs_properties_add_list(props, "follow_source",
		"Zoom link source (for use with obs-zoom-to-mouse)",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(pfol, "(no link)", "")
	do
		local sources = obs.obs_enum_sources()
		if sources ~= nil then
			for _, src in ipairs(sources) do
				local sid = obs.obs_source_get_id(src)
				if sid == "monitor_capture" or sid == "window_capture" or sid == "game_capture" then
					local nm = obs.obs_source_get_name(src)
					obs.obs_property_list_add_string(pfol, nm, nm)
				end
			end
			obs.source_list_release(sources)
		end
	end
	obs.obs_properties_add_text(props, "note_follow",
		"When a standalone layer is used with obs-zoom-to-mouse, the highlight drifts because it doesn't take the crop.\n" ..
		"Pick the zoomed capture source here and the layer remaps its coordinates to that crop rect every frame,\n" ..
		"staying aligned through zoom in / follow / zoom out (standalone \"Mouse Highlight Layer\" only;\n" ..
		"the filter version sits below the crop filter and gets zoomed with the frame, so it doesn't need this).\n" ..
		"If a source you just created isn't listed, reload the script to refresh.", obs.OBS_TEXT_INFO)

	obs.obs_properties_add_text(props, "sep_hl", "—— Highlight ring ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "hl_on", "Enable highlight ring")
	local pm = obs.obs_properties_add_list(props, "hl_mode", "Highlight style",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(pm, "Outer ring + fill", 0)
	obs.obs_property_list_add_int(pm, "Outer ring only", 1)
	obs.obs_property_list_add_int(pm, "Fill only", 2)
	obs.obs_properties_add_float_slider(props, "hl_radius", "Radius", 0, 200, 1)
	obs.obs_properties_add_float_slider(props, "hl_thickness", "Ring thickness", 0, 30, 0.5)
	obs.obs_properties_add_color(props, "hl_color", "Color")
	obs.obs_properties_add_float_slider(props, "hl_opacity", "Ring opacity", 0, 1, 0.01)
	obs.obs_properties_add_float_slider(props, "hl_fill_opacity", "Fill strength", 0, 1, 0.01)
	obs.obs_properties_add_float_slider(props, "fx_offset_y",
		"Circle center offset (drops ring/glow below the cursor so it doesn't wash over it)", -120, 120, 1)
	obs.obs_properties_add_bool(props, "glow_on", "Enable glow")
	obs.obs_properties_add_float_slider(props, "glow_radius", "Glow radius", 0, 400, 1)
	obs.obs_properties_add_float_slider(props, "glow_opacity", "Glow strength", 0, 1, 0.01)
	obs.obs_properties_add_text(props, "note_lay",
		"Layer order (bottom to top): trail → glow → click ripples → fill → ring → cursor.\n" ..
		"So the ring is always under the cursor — provided \"Self-drawn cursor\" below is on.\n" ..
		"\"Circle center offset\" is no longer needed; leave it at 0.",
		obs.OBS_TEXT_INFO)

	obs.obs_properties_add_text(props, "sep_click", "—— Click ripples ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "click_on", "Enable click effects")
	obs.obs_properties_add_float_slider(props, "click_duration", "Ring duration (s)", 0.1, 2.0, 0.05)
	obs.obs_properties_add_float_slider(props, "start_radius", "Start radius", 0, 100, 1)
	obs.obs_properties_add_float_slider(props, "end_radius", "End radius", 0, 300, 1)
	obs.obs_properties_add_float_slider(props, "ring_thickness", "Ring width", 0, 40, 0.5)
	obs.obs_properties_add_int_slider(props, "ripple_count", "Ring count (1–3)", 1, 3, 1)
	obs.obs_properties_add_float_slider(props, "ripple_delay", "Delay between rings (s)", 0, 0.5, 0.01)
	obs.obs_properties_add_float_slider(props, "fill_opacity", "Fill strength", 0, 1, 0.01)
	obs.obs_properties_add_float_slider(props, "click_opacity", "Overall opacity", 0, 1, 0.01)
	obs.obs_properties_add_color(props, "color_left", "Left button color")
	obs.obs_properties_add_color(props, "color_right", "Right button color")
	obs.obs_properties_add_color(props, "color_middle", "Middle button color")

	obs.obs_properties_add_text(props, "sep_trail", "—— Motion trail ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "trail_on", "Enable trail")
	obs.obs_properties_add_int_slider(props, "trail_count", "Trail count", 2, MAX_DOTS, 1)
	obs.obs_properties_add_float_slider(props, "trail_radius", "Trail dot radius", 1, 40, 0.5)
	obs.obs_properties_add_float_slider(props, "trail_step", "Sample interval (s)", 0.01, 0.2, 0.005)
	obs.obs_properties_add_color(props, "trail_color", "Trail color")
	obs.obs_properties_add_float_slider(props, "trail_opacity", "Trail opacity", 0, 1, 0.01)

	local TT = obs.OBS_TEXT_DEFAULT or 0
	obs.obs_properties_add_text(props, "sep_cur", "—— Self-drawn cursor (always above the ring) ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "cur_on", "Enable self-drawn cursor")
	obs.obs_properties_add_bool(props, "cur_auto",
		"Read the live system cursor (theme / shape changes follow automatically)")
	-- If a theme change isn't picked up (Windows sometimes reuses the same cursor handle, so the
	-- script can't tell the difference), one click forces a clear + regrab. The callback runs on the
	-- UI thread and only bumps the counter; the real resample still happens in the graphics context (cursor_update).
	pcall(obs.obs_properties_add_button, props, "btn_regrab",
		"Regrab cursor (click if a theme or image change wasn't picked up)",
		function(pp, prop)
			REGRAB = REGRAB + 1
			return false
		end)
	obs.obs_properties_add_text(props, "note_cur",
		"The ring is drawn over the captured frame, but the system cursor was baked into that frame long ago,\n" ..
		"so the ring would always cover it. To get the ring under the cursor, the only way is to turn off\n" ..
		"\"Capture cursor\" on the capture source and let this script draw the cursor on the top layer — the settings below.\n" ..
		"\"Auto read\" = pull the current cursor bitmap from Windows at runtime; theme and shape changes follow.\n" ..
		"Turn it off (or if auto fails) and the \"Cursor image\" file is used. A horizontally tiled image\n" ..
		"plays back at the \"frame rate\". Hotspot = the cursor's action point, relative to one frame's top-left\n" ..
		"(the bundled image is 1,1; a plain arrow is 0,0). If a theme change isn't picked up, hit \"Regrab cursor\" above.\n" ..
		"To see what was grabbed (pixel count, frame count), tick \"Output log\" at the bottom.",
		obs.OBS_TEXT_INFO)
	obs.obs_properties_add_text(props, "cur_img", "Cursor image (relative to script folder)", TT)
	obs.obs_properties_add_int(props, "cur_frames", "Image frame count (0 = auto from width/height)", 0, 64, 1)
	obs.obs_properties_add_float_slider(props, "cur_fps", "Multi-frame cursor fps", 1, 30, 1)
	obs.obs_properties_add_int(props, "cur_hot_x", "Hotspot X", 0, 512, 1)
	obs.obs_properties_add_int(props, "cur_hot_y", "Hotspot Y", 0, 512, 1)
	obs.obs_properties_add_float_slider(props, "cur_scale", "Cursor scale", 0.5, 3.0, 0.1)
	obs.obs_properties_add_bool(props, "take_cursor",
		"Cursor takeover: turn off \"Capture cursor\" on the capture source automatically (required, otherwise two cursors show)")
	obs.obs_properties_add_text(props, "take_src",
		"Capture source name for takeover (standalone: required; empty = use \"Zoom link source\" above)", TT)

	obs.obs_properties_add_text(props, "sep_arrow",
		"—— Built-in arrow (fallback when both auto read and the image fail) ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_color(props, "cur_fill", "Arrow fill color")
	obs.obs_properties_add_color(props, "cur_line", "Arrow outline color")

	obs.obs_properties_add_text(props, "sep_other", "—— Misc ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_float_slider(props, "smooth", "Smoothing (1 = no interpolation)", 0.05, 1.0, 0.05)
	obs.obs_properties_add_int(props, "canvas_w", "Layer width (in \"Auto\" mode it follows the captured monitor)", 16, 16384, 1)
	obs.obs_properties_add_int(props, "canvas_h", "Layer height (in \"Auto\" mode it follows the captured monitor)", 16, 16384, 1)
	obs.obs_properties_add_bool(props, "log_on", "Output log (debugging; off by default to keep the log quiet)")

	return props
end

function script_load(settings)
	script_update(settings)
	obs.obs_register_source(filter_def)
	obs.obs_register_source(source_def)
	log("Loaded v" .. SCRIPT_VERSION .. " (EN build). Region " .. tostring(S.region_left) .. "," .. tostring(S.region_top) ..
		" " .. tostring(S.region_w) .. "x" .. tostring(S.region_h))
end

function script_unload()
	log("Unloaded")
end
