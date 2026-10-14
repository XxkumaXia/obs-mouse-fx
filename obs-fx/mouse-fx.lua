--[[
mouse-fx.lua —— OBS 鼠标高亮叠加（滤镜 / 独立源）
================================================================
用法：OBS 菜单「工具 → 脚本 → +」加载本文件即可。
      然后在「显示器采集 / 窗口采集 / 游戏采集」上右键 → 滤镜 → 添加
      「鼠标高亮叠加」；或者直接在场景里新增来源「鼠标高亮层」。

原理：LuaJIT 的 ffi 直接调 Win32 拿光标坐标与按键，
      再由 mouse-fx.effect 画高亮环 / 点击波纹 / 拖影 / 自绘箭头。
      不需要任何外部服务、浏览器源或 Python 环境。

注意：mouse-fx.effect 与 blank.png 必须与本文件放在同一目录。
]]

obs = obslua
bit = bit or require("bit")

local LOG_INFO  = obs.LOG_INFO  or 300
local LOG_ERROR = obs.LOG_ERROR or 100

-- 脚本设置表：必须声明在任何引用它的函数之前！
-- Lua 里 local 只从声明处开始可见，若函数定义在它之前，函数内的 S 会被
-- 编译成「全局变量」→ 运行时 nil → 每帧报 attempt to index global 'S'。
-- （这个坑踩过两次，务必保持 S 在文件开头。）
local S = {}

-- 「重新抓取光标」按钮的计数器：每次点击 +1，值进 cursor_update 的 key，
-- 于是所有实例都会做一次「清空 + 重新采样」。放在文件最前面，属性面板的
-- 回调闭包和 cursor_update 才能同时看到它。
local REGRAB = 0

-- 同一条错误只报一次（换主题反复失败时不刷屏）
local CUR_ERR_SEEN = {}

-- 日志默认关闭，避免在 OBS 脚本日志里刷屏。需要排障时在面板里打开「输出日志」。
local function log(msg)
	if S.log_on then
		obs.script_log(LOG_INFO, "[鼠标高亮] " .. msg)
	end
end
-- 错误日志始终输出（数量极少，用于提示真正的配置问题）
local function logerr(msg)
	obs.script_log(LOG_ERROR, "[鼠标高亮] " .. msg)
end

-- ---------------------------------------------------------------- FFI
local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then
	logerr("当前 OBS 的 Lua 环境没有 ffi，脚本无法获取鼠标位置，已停止加载")
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

-- 枚举所有显示器：返回 {left, top, w, h, id} 列表（id 为设备接口路径）
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

-- 按 OBS 的 monitor_id 找到对应显示器矩形（自动模式用）
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

-- 滤镜：读取「目标源」的显示器采集设置，自动确定映射区域
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

-- ---------------------------------------------------------------- 缩放联动
-- 与 obs-zoom-to-mouse.lua 搭配用：它对采集源做「裁剪滤镜压小输出 + 场景项拉伸回原尺寸」
-- 来放大画面，场景项变换本身不动。独立源（鼠标高亮层）是另一个图层，吃不到这个变换，
-- 所以这里主动读出联动源上裁剪滤镜的当前裁剪框，把光标坐标重新映射回放大后的画面。
-- 解析联动源上的裁剪滤镜名。★ 现场取用、用完立即释放，绝不跨帧持有 source 引用 ★
-- （曾经把源引用缓存到 d.cap 长期持有：OBS 关闭时该引用会拖住源对象，
--   obs_source_destroy_defer 里释放顺序错乱 → 未处理异常 c0000005 → 崩溃/每次启动弹恢复提示。）
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

	-- 找裁剪滤镜：优先 obs-zoom-to-mouse 的（名字带 zoom），其次任意启用的 crop_filter
	local name = nil
	local ok2, filters = pcall(obs.obs_source_enum_filters, src)
	if ok2 and filters ~= nil then
		local fallback = nil
		for _, f in pairs(filters) do
			if f ~= nil and obs.obs_source_enabled(f) and
				obs.obs_source_get_id(f) == "crop_filter" then
				local nm = obs.obs_source_get_name(f) or ""
				if string.find(string.lower(nm), "zoom", 1, true) ~= nil then
					name = nm
					break
				end
				if fallback == nil then fallback = nm end
			end
		end
		if name == nil then
			name = fallback
		end
		local release = obs.obs_source_list_release or obs.source_list_release
		if release ~= nil then
			pcall(release, filters)
		end
	end
	obs.obs_source_release(src)
	return name
end

-- 返回当前裁剪框 cl, ct, cw, ch（联动源坐标系）；没联动/读不到时返回 nil
local function follow_crop(d)
	if S.follow_source == "" then
		return nil
	end
	-- 换源时立即失效；平时每 2 秒重解析一次滤镜名（源/滤镜可能被改名）
	if d.follow_name ~= S.follow_source then
		d.follow_name = S.follow_source
		d.follow_t = nil
		d.crop_name = nil
		d.follow_logged = false
	end
	if d.follow_t == nil or (d.clock - d.follow_t) >= 2.0 then
		d.follow_t = d.clock
		d.crop_name = follow_find_crop_name()
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

-- ---------------------------------------------------------------- 设置

-- OBS 的 obs_properties_add_color 返回 0xAABBGGRR（低字节是 R！）
-- 曾经按 0xAARRGGBB 解过，结果 红↔蓝 互换、青↔黄 互换，别再改回去
local function argb(v, mul)
	v = math.floor(tonumber(v) or 0) % 4294967296
	local r = v % 256
	local g = math.floor(v / 256) % 256
	local b = math.floor(v / 65536) % 256
	local a = math.floor(v / 16777216) % 256
	return r / 255, g / 255, b / 255, (a / 255) * (mul or 1.0)
end

-- 用 (r,g,b,a) 各 0~255 生成 OBS 颜色整数，别再手写字面量
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
	region_mode   = 0,      -- 0 自动 / 1 主屏 / 2 虚拟桌面 / 3 自定义 / 4 指定显示器
	monitor_sel   = "",     -- 指定显示器：monitor 的 DeviceID（区域选 4 时生效）
	follow_source = "",     -- 联动缩放源：obs-zoom-to-mouse 缩放的采集源名（独立源专用）
	custom_left   = 0,
	custom_top    = 0,
	custom_width  = 1920,
	custom_height = 1080,
	offset_x      = 0,
	offset_y      = 0,
	zoom          = 1.0,

	hl_on         = true,
	hl_mode       = 0,      -- 0 环+填充 / 1 仅环 / 2 仅填充
	hl_radius     = 32.0,
	hl_thickness  = 4.0,
	hl_color      = C_YELLOW,
	hl_opacity    = 0.9,
	hl_fill_opacity = 0.38,
	fx_offset_y   = 0.0,    -- 填充/柔光 圆心下移量（避开系统光标）
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
	-- 自绘光标：画在最后 = 最上层，所以常驻高亮圈一定在它「下面」
	cur_on        = true,
	cur_auto      = true,   -- 自动读取系统当前光标（换主题 / 换形状自动跟上）
	cur_img       = "cursor.png", -- 自动失败时用的图片（相对脚本目录；多帧横向平铺；仓库自带 32×32 中性箭头）
	cur_frames    = 0,      -- 0 = 按 宽/高 自动分帧
	cur_fps       = 10.0,   -- 多帧光标的播放帧率
	cur_hot_x     = 1,      -- 热点（相对单帧左上角，像素）
	cur_hot_y     = 1,
	cur_scale     = 1.0,
	cur_fill      = C_WHITE,
	cur_line      = C_BLACK,
	take_cursor   = true,   -- 自绘接管：自动关掉采集源的「捕获光标」
	take_src      = "",     -- 接管用的采集源名（独立源用；空 = 用「联动缩放源」）

	canvas_w      = 1920,
	canvas_h      = 1080,
	log_on        = false,  -- 输出日志：默认关闭，避免在 OBS 脚本日志里刷屏
}

-- 0 自动（跟随采集的显示器）/ 1 主屏 / 2 虚拟桌面 / 3 自定义 / 4 指定显示器
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

-- 需要按 double 存的项（其余数字项按 int 存）
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

-- ---------------------------------------------------------------- 光标抓取
-- 运行时直接从 Windows 读出「当前光标」的位图（含热点）：
--   GetCursorInfo → GetIconInfo → GetDIBits → 自己编码成 PNG → 交给 OBS 当纹理。
-- 所以换光标主题、换光标形状（箭头↔文本↔手型）、.ani 动画都能自动跟上。
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

-- ---- 极简 PNG 编码器（RGBA8 + 无压缩 deflate）——不依赖任何外部库 ----
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

-- zlib 流：全部用 stored（不压缩）块，最省事也最不容易出错
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

-- rgba 必须「自上而下、每像素 4 字节」
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

-- 抓一次「当前系统光标」，返回 w, h, hotx, hoty, rgba(自上而下)
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
	-- 注意：GetObjectA 属于 gdi32，不是 user32！写错会抛
	-- "cannot resolve symbol 'GetObjectA'" 并让整个抓取流程静默失效。
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

			-- ============ 掩码必须按它自己的位深读 ============
			-- 【闪黑 bug 的真正根源】
			-- hbmMask 是 1bpp 位图（bmBitsPixel=1）！早期版本拿 32bpp 的
			-- BITMAPINFOHEADER 去 GetDIBits 它，Windows 无法把 1bpp 转成
			-- 32bpp 请求，返回的缓冲区里 alpha 全是 0 → `mb > 127` 恒为假
			-- → 每个像素都判成「不透明」，光标被画成一整块纯黑方块。
			-- 实测：32×32 掩码里真实有 297 个「透明」像素，正是这个数。
			-- 正确做法：用 biBitCount=1 请求，再按位取。
			local mask = nil
			if ii.hbmMask ~= nil then
				local mrow = math.floor((w + 31) / 32) * 4 -- 1bpp 行按 4 字节对齐
				local mbuf = ffi.new("unsigned char[?]", mrow * h)
				local mbmi = ffi.new("FXBMIX")
				local mh = mbmi.bmiHeader
				mh.biSize = 40
				mh.biWidth = w
				mh.biHeight = h
				mh.biPlanes = 1
				mh.biBitCount = 1 -- 关键：1bpp
				mh.biCompression = 0
				if gdi32.GetDIBits(hdc, ii.hbmMask, 0, h, mbuf, mbmi, 0) ~= 0 then
					mask = ffi.string(mbuf, mrow * h)
					mask = mask -- 下面按 (srow + x/8) 取字节
				end
			end

			-- ============ 颜色位图：按它自己的位深读 ============
			-- 32bpp（带 alpha）和 8bpp（索引色 + 调色板）要走不同分支。
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
				-- 32bpp 光标带真 alpha；老式 8bpp 光标 alpha 恒为 0，
				-- 这时要用 AND 掩码判透明（掩码为白 = 透明）
				local has_alpha = false
				if color ~= nil then
					for i = 1, n do
						if color:byte(i * 4) > 0 then
							has_alpha = true
							break
						end
					end
				end

				-- 没有可用 alpha 也没有掩码 → 这次抓取无效，交给上层重试/兜底
				if color ~= nil and not has_alpha and mask == nil then
					if ii.hbmColor ~= nil then gdi32.DeleteObject(ii.hbmColor) end
					if ii.hbmMask  ~= nil then gdi32.DeleteObject(ii.hbmMask)  end
					return nil
				end

				local mrow = math.floor((w + 31) / 32) * 4
				local px = {}
				local opaque = 0
				for y = 0, h - 1 do
					local my = h - 1 - y          -- 掩码同样自下而上
					local srow = my * mrow        -- 掩码按 1bpp 行跨度
					local crow = my * w * 4       -- 颜色按 32bpp 行跨度
					for x = 0, w - 1 do
						local b, g, r, a = 0, 0, 0, 0
						if color ~= nil then
							local co = crow + x * 4
							b, g, r, a = color:byte(co + 1, co + 4)
						end
						if not has_alpha then
							-- 1bpp：位为 1 = 透明（白），0 = 不透明
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

				-- 一整帧完全没有不透明像素 = 无效帧（抓取时序问题/光标处于隐藏态），
				-- 收进去只会让动画里出现「闪一下全空」。直接丢掉。
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

local CURSOR_SAMPLES = 5      -- 采样几次（用于还原 .ani 动画）
local CURSOR_SAMPLE_S  = 0.09 -- 采样间隔（秒）
local CURSOR_MAX_FRAMES = 8

-- 注意：以下 4 个函数都必须在「图形上下文内」调用（render_data / 已 enter_graphics）
local function cursor_clear(d)
	-- 每次清空都换一个「采样序号」：临时 PNG 的文件名带它，
	-- 于是任何一次重新抓取（换形状 / 换主题 / 点按钮）都不会撞上旧文件名，
	-- 也就绕开了按路径缓存贴图导致「换了光标还是旧图」的问题。
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
	-- 【防闪黑】进纹理之前先做一次「理智检查」，把坏帧挡在外面。
	-- 采样阶段是连着抓几帧，期间光标可能正处于动画的过渡态，
	-- 或 GPU/桌面合成器正在换绘制表面，抓到的可能是一张
	-- 「几乎全透明」或「几乎纯黑」的残帧。这种帧一旦进到多帧循环里，
	-- 播放时就表现为光标规律性地闪黑一下——正是用户看到的 bug。
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
	-- 不透明像素太少 → 这张就是「空帧」，丢掉
	if opaque < n * 0.02 then
		return
	end
	-- 不透明像素里几乎全是黑的 → 典型的「黑方块」残帧，丢掉。
	-- 实测正常光标（32×32）不透明占 71%、其中黑只占 18%，离这个阈值很远。
	if black >= opaque * 0.98 then
		return
	end
	local frame_opaque = opaque -- 供「2 帧时选最实的一帧」用

	local sum = crc32(rgba) -- 内容指纹：重复帧不重复加载
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
	kernel32.DeleteFileA(path) -- 已进显存，文件不必留着
	if tex == nil then
		return
	end
	d.cur_frames[#d.cur_frames + 1] = { tex = tex, hash = sum, opaque = frame_opaque }
	d.cur_dw, d.cur_dh = w, h
	d.cur_hx, d.cur_hy = hx, hy
	d.cur_u0x, d.cur_u0y = 0.0, 0.0
	d.cur_u1x, d.cur_u1y = 1.0, 1.0
end

-- 手动模式：加载一张 PNG（多帧则横向平铺）
local function cursor_load_png(d)
	local path = S.cur_img
	if path == nil or path == "" then
		path = "cursor.png"
	end
	local c1 = string.sub(path, 1, 1)
	local c2 = string.sub(path, 2, 2)
	if c2 ~= ":" and c1 ~= "/" and c1 ~= "\\" then
		path = script_path() .. path -- 相对路径按「脚本所在目录」解析
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
		frames = math.max(1, math.floor(tw / th + 0.5)) -- 横向分帧：宽/高
	end
	frames = math.min(frames, tw)
	d.cur_png_tex = tex
	d.cur_png_frames = frames
	d.cur_png_tw = tw
	d.cur_dw, d.cur_dh = math.floor(tw / frames + 0.5), th
	d.cur_hx = S.cur_hot_x
	d.cur_hy = S.cur_hot_y
	log("手动光标图：" .. path .. "  " .. tostring(tw) .. "x" .. tostring(th) ..
		"，" .. tostring(frames) .. " 帧，热点 " .. tostring(S.cur_hot_x) .. "," ..
		tostring(S.cur_hot_y))
	return true
end

local function cursor_hot_set(d)
	-- 【防闪黑】和自动抓取那侧同样的道理：2 帧交替最容易看起来像闪烁。
	-- 这里让「只有 2 帧」的图片直接静态显示第 1 帧，不交替。
	if d.cur_png_tex ~= nil and d.cur_png_frames > 2 then
		local f = d.cur_png_frames
		local i = 1 + math.floor(d.clock * (S.cur_fps or 10.0)) % f
		local tw = d.cur_png_tw
		-- 左右各内缩半个像素，避免点采样蹭到相邻帧
		d.cur_u0x = ((i - 1) * d.cur_dh + 0.5) / tw
		d.cur_u1x = (i * d.cur_dh - 0.5) / tw
		d.cur_u0y, d.cur_u1y = 0.0, 1.0
	elseif d.cur_png_tex ~= nil then
		-- 单帧 / 双帧：固定用第 1 帧
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
	-- REGRAB 是「重新抓取光标」按钮的计数：它进 key 就意味着点一下按钮，
	-- 所有实例都会走一遍「清空 → 重新采样」。
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
		-- 每次设置变化 / 点「重新抓取光标」都给一次新的反馈
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
			cursor_clear(d) -- 换了形状/主题：重新采样（清空时已顺带换掉采样序号）
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
				-- 无论抓到没抓到都推进计数：抓不到也必须走完采样阶段，
				-- 否则会永远卡在 probe，连「光标图片」的兜底都轮不到。
				d.cur_probe_i = (d.cur_probe_i or 0) + 1
			end
			if (d.cur_probe_i or 0) >= CURSOR_SAMPLES then
				d.cur_mode = "ready"
				if #d.cur_frames == 0 then
					if not d.cur_fail_logged then
						d.cur_fail_logged = true
						log("自动读取系统光标失败，改用「光标图片」或内置箭头兜底")
					end
				elseif not d.cur_ok_logged then
					d.cur_ok_logged = true
					log("已抓到系统光标：" .. tostring(d.cur_dw) .. "x" .. tostring(d.cur_dh) ..
						"，热点 " .. tostring(d.cur_hx) .. "," .. tostring(d.cur_hy) ..
						"，" .. tostring(#d.cur_frames) .. " 帧")
				end
			end
		end
		-- 抓取失败过：每 2 秒重试一轮。成功后会自己切回自绘光标，
		-- 期间画面由「光标图片 / 内置箭头」顶着，不会空窗。
		if d.cur_mode == "ready" and #d.cur_frames == 0 then
			if d.cur_retry_t == nil or (d.clock - d.cur_retry_t) >= 2.0 then
				d.cur_retry_t = d.clock
				d.cur_mode = "probe"
				d.cur_probe_i = 0
				d.cur_probe_t = nil
			end
		end
		if #d.cur_frames > 0 then
			-- 【防闪黑】动画帧选择。
			-- 采样期的光标可能只抓到 2 个不同画面（甚至 1 个），而其中一张
			-- 往往是动画过渡态的残帧。若就这样 2 帧交替播放，肉眼看到的就是
			-- 规律性「闪黑」。所以：
			--   · 只有 1 帧 → 直接静态显示，不做动画（最稳）
			--   · 只有 2 帧 → 不交替，固定显示「最实」的那一帧
			--     （不透明像素最多的那张，通常就是主形态，残帧的不透明面积偏小）
			--   · 3 帧以上 → 才真正按帧率循环播放
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
		-- 自动失败 → 落到手动图片
	end

	if d.cur_png_tex == nil then
		if d.cur_png_bad then
			d.cur_now = nil -- 图片也加载过、失败了，别再每帧重试
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

-- ---------------------------------------------------------------- 实例
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
			logerr("effect 里取不到的参数：" .. table.concat(missing, ","))
		end
		if d.blank == nil then
			logerr("blank.png 加载失败：" .. dir .. BLANK_FILE)
		end
	else
		logerr("effect 加载失败：" .. dir .. EFFECT_FILE)
	end
	obs.obs_leave_graphics()
	return d
end

-- OBS 32 的 Lua 绑定里 vec2 / vec4 是对象：先无参构造，再用 *_set 填值
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

-- 目标采集源自带的系统光标会把高亮盖住；「自绘接管」让它压在系统光标之下
local CURSOR_SOURCES = {
	monitor_capture = true,
	window_capture  = true,
	game_capture    = true,
}

-- 找出「该关捕获光标」的那个采集源：
--   滤镜实例 → 它挂载的目标源（借用引用，绝不能 release）
--   独立源   → take_src（空则回退「联动缩放源」）（有引用，用完必须 release）
local function takeover_target(d)
	if obs.obs_source_get_id(d.source) == "mouse_fx_filter" then
		if not obs.obs_source_enabled(d.source) then
			return nil, false -- 滤镜被禁用，别去动采集源
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
		return
	end
	local ok_id, id = pcall(obs.obs_source_get_id, target)
	if not ok_id or id == nil or not CURSOR_SOURCES[id] then
		if owned then obs.obs_source_release(target) end
		return
	end

	local want = S.take_cursor and S.cur_on
	local ok_st, st = pcall(obs.obs_source_get_settings, target)
	if not ok_st or st == nil then
		if owned then obs.obs_source_release(target) end
		return
	end
	local now = obs.obs_data_get_bool(st, "capture_cursor")
	if want and now then
		obs.obs_data_set_bool(st, "capture_cursor", false)
		obs.obs_source_update(target, st)
		d.took_cursor = true
		log("自绘接管：已关掉「" .. tostring(obs.obs_source_get_name(target)) ..
			"」的「捕获光标」，改由脚本画在高亮圈之上")
	elseif not want and d.took_cursor and not now then
		obs.obs_data_set_bool(st, "capture_cursor", true)
		obs.obs_source_update(target, st)
		d.took_cursor = false
		log("自绘接管已关闭：恢复了采集源的「捕获光标」")
	end
	obs.obs_data_release(st)
	if owned then obs.obs_source_release(target) end
end

-- 状态更新：读取坐标、按键、推进动画。
-- 不依赖 video_tick（源未激活时 OBS 不会调 tick），渲染帧里也会调用一次。
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

	-- 滤镜自身没有尺寸，要取它挂载的目标源的宽高；独立源(鼠标高亮层)用自身的画布尺寸
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

	-- 自动模式：定期读取采集源所在的显示器矩形
	if S.region_mode == 0 then
		if is_filter then
			if d.auto_t == nil or (d.clock - d.auto_t) > 2.0 then
				d.auto_t = d.clock
				local r = detect_source_region(d.source)
				if r ~= nil then
					d.auto = r
					if not d.auto_logged then
						d.auto_logged = true
						log("自动匹配采集显示器：" .. tostring(r[1]) .. "," ..
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
						log("自动匹配失败，改用主屏兜底。本机显示器 = " .. table.concat(s, " | "))
					end
				end
			end
		else
			-- 独立源没有挂载目标，自动模式改用「指定显示器」所选屏；没选则主屏
			if S.monitor_sel ~= "" then
				local m = find_monitor(S.monitor_sel)
				if m ~= nil then
					d.auto = { m.left, m.top, m.w, m.h }
					if not d.auto_logged then
						d.auto_logged = true
						log("独立源自动：使用指定显示器 " .. tostring(m.left) .. "," ..
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
		log("画面尺寸 " .. tostring(w) .. "x" .. tostring(h) .. "，映射区域 " ..
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

	-- 缩放联动：只对独立源生效。滤镜版本来就画在裁剪滤镜下游，
	-- 会被一起裁剪拉伸，天然对齐；独立源则要自己按裁剪框重映射。
	local sx, sy
	local zf = 1.0
	if not is_filter then
		local cl, ct, cw, ch = follow_crop(d)
		if cw ~= nil then
			-- 光标先换算成联动源画面内坐标，减去裁剪框左上角，再按
			-- 「画面尺寸 / 裁剪尺寸」的拉伸倍率放大到画布坐标
			sx = (mx - rl - cl) * (w / cw) * S.zoom + S.offset_x
			sy = (my - rt - ct) * (h / ch) * S.zoom + S.offset_y
			zf = w / cw
			if not d.follow_logged then
				d.follow_logged = true
				log("联动缩放：「" .. S.follow_source .. "」裁剪框 " ..
					tostring(cl) .. "," .. tostring(ct) .. " " ..
					tostring(cw) .. "x" .. tostring(ch) .. "，倍率 " ..
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
		log("首帧渲染完成（" .. tostring(d.width) .. "x" .. tostring(d.height) .. "）")
	end

	set_v2(d, p.mouse_pos, d.px, d.py)
	set_v2(d, p.img_size, d.width, d.height)
	-- 联动缩放倍率：独立源跟随 obs-zoom-to-mouse 放大时，高亮尺寸也同步缩放
	local zf = d.zf or 1.0
	-- 填充 / 柔光的圆心：整体下移，避免高亮盖住系统光标
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

	-- 图片光标：画在最后 = 最上层，所以高亮圈一定在光标「下面」
	-- 出错只报一次（同一条错误），而且是 log 而不是 logerr：
	-- 这里已经有「图片 → 内置箭头」兜底，属于可恢复问题，不该弹脚本日志。
	local ok_cur, err_cur = pcall(cursor_update, d)
	if not ok_cur then
		d.cur_now = nil
		local es = tostring(err_cur)
		if not CUR_ERR_SEEN[es] then
			CUR_ERR_SEEN[es] = true
			log("抓取/加载光标出错（已退回内置箭头）：" .. es)
		end
	end
	local use_img = 0.0
	local tex = d.cur_now
	if tex == nil then
		tex = d.blank -- 兜底绑一张合法纹理，避免采样空纹理
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

	-- 点击波纹
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

	-- 拖影
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

-- ---------------------------------------------------------------- 滤镜
local filter_def = {}
filter_def.id = "mouse_fx_filter"
filter_def.type = obs.OBS_SOURCE_TYPE_FILTER
filter_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO)

filter_def.get_name = function()
	return "鼠标高亮叠加 (Mouse FX)"
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
	-- OBS 32 传给脚本的 effect 参数不能直接用于 tech_end，显式取默认 effect
	local eff = obs.obs_get_base_effect(obs.OBS_EFFECT_DEFAULT)
	obs.obs_source_process_filter_begin(d.source, obs.GS_RGBA,
		obs.OBS_ALLOW_DIRECT_RENDERING)
		-- 本滤镜必须输出完整分辨率(来源基准 1920×1080)：因为「缩放裁剪」滤镜排在本滤镜之上
		-- （数组最上方 = 最终输出那一环），它会从本滤镜输出的全尺寸画面里裁出放大区域；
		-- 若本滤镜输出变小，裁剪就无内容可裁。高亮环坐标也按来源基准分辨率计算(update_state 的 d.width)，
		-- 所以裁剪滤镜必须在上方、本滤镜在下方——二者配合才能既放大又叠高亮。
		obs.obs_source_process_filter_tech_end(d.source, eff, d.width, d.height, "Draw")
	render_data(d)
end

-- ---------------------------------------------------------------- 独立源
local source_def = {}
source_def.id = "mouse_fx_source"
source_def.type = obs.OBS_SOURCE_TYPE_INPUT
source_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO, obs.OBS_SOURCE_CUSTOM_DRAW)

source_def.get_name = function()
	return "鼠标高亮层 (Mouse FX)"
end

source_def.create = function(settings, source)
	return new_data(source)
end

source_def.destroy = function(d)
	free_data(d)
end

source_def.get_width = function(d)
	return S.canvas_w
end

source_def.get_height = function(d)
	return S.canvas_h
end

source_def.video_tick = function(d, seconds)
	update_state(d)
end

source_def.video_render = function(d, effect)
	render_data(d)
end

-- ---------------------------------------------------------------- 脚本面板
function script_description()
	return "在画面上叠加自绘鼠标效果：常驻高亮圈 + 点击扩散波纹 + 拖影 + 光标。\n" ..
	       "用法一（推荐）：给「显示器采集 / 窗口采集」加滤镜「鼠标高亮叠加」，自动跟随那块屏；\n" ..
	       "用法二：场景里新增来源「鼠标高亮层」拖到最上层——需在「坐标区域」选「指定显示器」并\n" ..
	       "在下拉里挑你正在录的那块屏，再把「独立源 宽/高」设成该屏分辨率。\n" ..
	       "光标：脚本会关掉采集源的「捕获光标」，改由自己把当前系统光标画在高亮圈之上，\n" ..
	       "所以圈永远在光标「下面」；换光标主题 / 换形状会自动跟上。\n" ..
	       "配合 obs-zoom-to-mouse 缩放时：独立源选好「联动缩放源」即可全程对齐。\n" ..
	       "坐标由 Win32 API 实时获取，无需任何外部程序。"
end

function script_properties()
	local props = obs.obs_properties_create()

	obs.obs_properties_add_text(props, "sep_region", "—— 坐标区域 ——", obs.OBS_TEXT_INFO)
	local p = obs.obs_properties_add_list(props, "region_mode", "鼠标坐标区域",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(p, "自动（滤镜读下方采集源；独立源用下面「指定显示器」）", 0)
	obs.obs_property_list_add_int(p, "主屏", 1)
	obs.obs_property_list_add_int(p, "虚拟桌面（多屏全部映射）", 2)
	obs.obs_property_list_add_int(p, "自定义（用下面的数值）", 3)
	obs.obs_property_list_add_int(p, "指定显示器（用下面的下拉）", 4)
	obs.obs_properties_add_int(props, "custom_left", "自定义 左", -8192, 8192, 1)
	obs.obs_properties_add_int(props, "custom_top", "自定义 上", -8192, 8192, 1)
	obs.obs_properties_add_int(props, "custom_width", "自定义 宽", 16, 16384, 1)
	obs.obs_properties_add_int(props, "custom_height", "自定义 高", 16, 16384, 1)
	obs.obs_properties_add_int(props, "offset_x", "整体偏移 X（微调）", -4096, 4096, 1)
	obs.obs_properties_add_int(props, "offset_y", "整体偏移 Y（微调）", -4096, 4096, 1)
	obs.obs_properties_add_float_slider(props, "zoom", "缩放修正", 0.1, 4.0, 0.01)

	-- 指定显示器下拉：区域选「指定显示器」时生效；独立源在「自动」下也会用它定位
	local pmon = obs.obs_properties_add_list(props, "monitor_sel",
		"指定显示器（区域选「指定显示器」时生效；独立源「自动」也用此项）",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(pmon, "（未选 / 用主屏）", "")
	local mons = enum_monitors()
	for _, m in ipairs(mons) do
		local label = m.name
		if label == nil or label == "" then label = m.id end
		label = label .. "  [" .. tostring(m.left) .. "," .. tostring(m.top) ..
			" " .. tostring(m.w) .. "x" .. tostring(m.h) .. "]"
		obs.obs_property_list_add_string(pmon, label, m.id)
	end
	obs.obs_properties_add_text(props, "note_region",
		"独立源（鼠标高亮层）是独立图层、没有挂载目标，所以「自动」无法读采集源。\n" ..
		"请在下方「指定显示器」选你正在录的那块屏；并把最下方「独立源 宽/高」设成该屏分辨率，\n" ..
		"坐标轴才会对得上。", obs.OBS_TEXT_INFO)

	-- 联动缩放源：独立源跟随 obs-zoom-to-mouse 的裁剪缩放
	local pfol = obs.obs_properties_add_list(props, "follow_source",
		"联动缩放源（配合 obs-zoom-to-mouse 用）",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(pfol, "（不联动）", "")
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
		"独立源配合 obs-zoom-to-mouse 放大时，高亮会因不吃裁剪而错位。\n" ..
		"在这里选中被缩放的那台采集源，高亮层就会按它的裁剪框实时重映射坐标，\n" ..
		"放大 / 跟随 / 缩回全程对齐（仅对「鼠标高亮层」独立源生效；\n" ..
		"滤镜版加在裁剪滤镜下方，天然一起被放大，无需此项）。\n" ..
		"若列表里没有刚建的源，重新加载一次脚本即可刷新。", obs.OBS_TEXT_INFO)

	obs.obs_properties_add_text(props, "sep_hl", "—— 常驻高亮圈 ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "hl_on", "启用高亮圈")
	local pm = obs.obs_properties_add_list(props, "hl_mode", "高亮样式",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(pm, "外环 + 内部填充", 0)
	obs.obs_property_list_add_int(pm, "仅外环", 1)
	obs.obs_property_list_add_int(pm, "仅内部填充", 2)
	obs.obs_properties_add_float_slider(props, "hl_radius", "半径", 0, 200, 1)
	obs.obs_properties_add_float_slider(props, "hl_thickness", "外环粗细", 0, 30, 0.5)
	obs.obs_properties_add_color(props, "hl_color", "颜色")
	obs.obs_properties_add_float_slider(props, "hl_opacity", "外环不透明度", 0, 1, 0.01)
	obs.obs_properties_add_float_slider(props, "hl_fill_opacity", "内部填充强度", 0, 1, 0.01)
	obs.obs_properties_add_float_slider(props, "fx_offset_y",
		"圆心下移（让圆/柔光落在光标下方，不糊住光标）", -120, 120, 1)
	obs.obs_properties_add_bool(props, "glow_on", "启用柔光")
	obs.obs_properties_add_float_slider(props, "glow_radius", "柔光半径", 0, 400, 1)
	obs.obs_properties_add_float_slider(props, "glow_opacity", "柔光强度", 0, 1, 0.01)
	obs.obs_properties_add_text(props, "note_lay",
		"图层顺序（自下而上）：拖影 → 柔光 → 点击波纹 → 内部填充 → 外环 → 光标。\n" ..
		"所以高亮圈永远在光标「下面」——前提是用下面的「自绘光标」。\n" ..
		"「圆心下移」现在不需要了，保持 0 即可。",
		obs.OBS_TEXT_INFO)

	obs.obs_properties_add_text(props, "sep_click", "—— 点击波纹 ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "click_on", "启用点击效果")
	obs.obs_properties_add_float_slider(props, "click_duration", "单环持续（秒）", 0.1, 2.0, 0.05)
	obs.obs_properties_add_float_slider(props, "start_radius", "起始半径", 0, 100, 1)
	obs.obs_properties_add_float_slider(props, "end_radius", "结束半径", 0, 300, 1)
	obs.obs_properties_add_float_slider(props, "ring_thickness", "环粗细", 0, 40, 0.5)
	obs.obs_properties_add_int_slider(props, "ripple_count", "重数（1~3）", 1, 3, 1)
	obs.obs_properties_add_float_slider(props, "ripple_delay", "重间延迟（秒）", 0, 0.5, 0.01)
	obs.obs_properties_add_float_slider(props, "fill_opacity", "内部填充强度", 0, 1, 0.01)
	obs.obs_properties_add_float_slider(props, "click_opacity", "整体不透明度", 0, 1, 0.01)
	obs.obs_properties_add_color(props, "color_left", "左键颜色")
	obs.obs_properties_add_color(props, "color_right", "右键颜色")
	obs.obs_properties_add_color(props, "color_middle", "中键颜色")

	obs.obs_properties_add_text(props, "sep_trail", "—— 移动拖影 ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "trail_on", "启用拖影")
	obs.obs_properties_add_int_slider(props, "trail_count", "残影数量", 2, MAX_DOTS, 1)
	obs.obs_properties_add_float_slider(props, "trail_radius", "残影半径", 1, 40, 0.5)
	obs.obs_properties_add_float_slider(props, "trail_step", "采样间隔（秒）", 0.01, 0.2, 0.005)
	obs.obs_properties_add_color(props, "trail_color", "拖影颜色")
	obs.obs_properties_add_float_slider(props, "trail_opacity", "拖影不透明度", 0, 1, 0.01)

	local TT = obs.OBS_TEXT_DEFAULT or 0
	obs.obs_properties_add_text(props, "sep_cur", "—— 自绘光标（永远画在高亮圈之上）——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_bool(props, "cur_on", "启用自绘光标")
	obs.obs_properties_add_bool(props, "cur_auto",
		"自动读取系统当前光标（换主题 / 换形状自动跟上）")
	-- 换主题后万一没跟上（Windows 偶尔会复用同一个光标句柄，脚本就看不出差别），
	-- 点一下就能强制清空重抓。回调跑在 UI 线程，只改计数器，真正的重采样
	-- 仍发生在图形上下文里（cursor_update）。
	pcall(obs.obs_properties_add_button, props, "btn_regrab",
		"重新抓取光标（换主题/换图片后没跟上就点一下）",
		function(pp, prop)
			REGRAB = REGRAB + 1
			return false
		end)
	obs.obs_properties_add_text(props, "note_cur",
		"高亮圈是叠在采集画面上的，而系统光标早就被「烤」进采集画面里了，\n" ..
		"所以高亮圈一定会盖住它。要做到「圈在光标下面」，只能关掉采集源的\n" ..
		"「捕获光标」，改由本脚本把光标画在最上层——也就是下面这些设置。\n" ..
		"「自动读取」= 运行时直接从 Windows 取当前光标位图，换主题 / 换形状都会自动跟上；\n" ..
		"关掉它（或自动读取失败）就用「光标图片」那张图。图片若是横向平铺的多帧，\n" ..
		"会按「帧率」循环播放。热点 = 光标作用点，相对单帧左上角（自带图是 1,1，普通箭头是 0,0）。\n" ..
		"换了主题没自动跟上时，点上面的「重新抓取光标」即可。\n" ..
		"想看抓取结果（抓到多少像素、几帧），勾选最下面的「输出日志」。",
		obs.OBS_TEXT_INFO)
	obs.obs_properties_add_text(props, "cur_img", "光标图片（相对脚本目录）", TT)
	obs.obs_properties_add_int(props, "cur_frames", "图片帧数（0=按宽/高自动）", 0, 64, 1)
	obs.obs_properties_add_float_slider(props, "cur_fps", "多帧光标帧率", 1, 30, 1)
	obs.obs_properties_add_int(props, "cur_hot_x", "热点 X", 0, 512, 1)
	obs.obs_properties_add_int(props, "cur_hot_y", "热点 Y", 0, 512, 1)
	obs.obs_properties_add_float_slider(props, "cur_scale", "光标缩放", 0.5, 3.0, 0.1)
	obs.obs_properties_add_bool(props, "take_cursor",
		"自绘接管：自动关掉采集源的「捕获光标」（必须开，否则画面上是两个光标）")
	obs.obs_properties_add_text(props, "take_src",
		"接管用的采集源名（独立源必填；留空 = 用上面的「联动缩放源」）", TT)

	obs.obs_properties_add_text(props, "sep_arrow",
		"—— 内置箭头（自动读取和图片都失败时的兜底）——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_color(props, "cur_fill", "箭头填充色")
	obs.obs_properties_add_color(props, "cur_line", "箭头描边色")

	obs.obs_properties_add_text(props, "sep_other", "—— 其它 ——", obs.OBS_TEXT_INFO)
	obs.obs_properties_add_float_slider(props, "smooth", "跟手程度（1=完全不插值）", 0.05, 1.0, 0.05)
	obs.obs_properties_add_int(props, "canvas_w", "独立源 宽", 16, 16384, 1)
	obs.obs_properties_add_int(props, "canvas_h", "独立源 高", 16, 16384, 1)
	obs.obs_properties_add_bool(props, "log_on", "输出日志（调试用，默认关闭不刷屏）")

	return props
end

function script_load(settings)
	script_update(settings)
	obs.obs_register_source(filter_def)
	obs.obs_register_source(source_def)
	log("已加载。区域 " .. tostring(S.region_left) .. "," .. tostring(S.region_top) ..
		" " .. tostring(S.region_w) .. "x" .. tostring(S.region_h))
end

function script_unload()
	log("已卸载")
end
