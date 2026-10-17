# -*- coding: utf-8 -*-
"""
test_zoom_link.py —— mouse-fx.lua「缩放联动 / 自绘接管」改动的功能测试
================================================================
背景：修了两个问题——
  1. follow_find_crop_name() 曾经「名字带 zoom 就算，再不然 fallback 到任意
     crop_filter」：会误认 zoom 脚本的临时滤镜 temp_obs-zoom-to-mouse-crop，
     以及用户自挂的 Crop/Pad，导致联动倍率算错（偏移 / 双光标）。
     现在只认精确名 obs-zoom-to-mouse-crop。
  2. apply_cursor_takeover() 的失败路径曾经全静默（找不到源 / 类型不符 /
     读不到设置都不吭声），排障时没线索。现在按原因打 logerr（始终输出，
     不受面板「输出日志」开关限制），同实例同原因只报一次。

原理：把 [mock + mouse-fx.lua 源码 + 用例] 拼成同一个 Lua chunk 执行——
用例排在源码之后、同一作用域，因此能直接调到脚本里的 local 函数
（follow_find_crop_name / follow_crop / apply_cursor_takeover /
detect_named_source_region / update_state）。
obs API 全部用 Lua 表 mock，不需要真实 OBS；ffi 走本机真实 user32/kernel32。

覆盖（T0-T24）：
  T0-T5   联动裁剪滤镜精确名匹配 + follow_crop 节流提示
  T6-T15  自绘接管成功 / 各失败路径提示 / 恢复路径
  T16-T22 独立源「自动」区域：按联动缩放源（回退接管源）读它捕获的显示器、
          换源重新探测、读不到时提示并退回指定显示器/主屏、
          宽高跟随（get_width/get_height）
  T23-T24 日志策略：输出日志关闭（默认）时引导提示完全静默；
          同一原因跨实例 60 秒内只提示一次（反复删加源不刷屏）

运行：python dev-archive/test_zoom_link.py     （依赖 lupa：pip install lupa）
"""

import os
import sys

try:
    import lupa
except ImportError:
    sys.exit("需要 lupa：pip install lupa")

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_FILE = os.path.join(HERE, "..", "obs-fx", "mouse-fx.lua")

# ---------------------------------------------------------------- mock 前缀
# 说明：S 表在 OBS 里由 script_update 从设置数据填充；用例里直接赋值模拟
# 加载后的状态（take_cursor / cur_on 默认 true）。
# lupa 自带的是 Lua 5.5（不是 OBS 里的 LuaJIT），没有 bit / ffi 内建，
# 这里用 package.preload 补上；ffi 只被脚本在加载时 cdef/load/new，
# 被测函数（follow_* / apply_cursor_takeover）不碰 ffi。
MOCK = r"""
package.preload["bit"] = function()
	local bit_mock = {}
	local function bits(x, i)
		return math.floor((x % 4294967296) / 2 ^ i) % 2
	end
	local function fold(f, a, b, ...)
		if b == nil then return a end
		local r = 0
		for i = 0, 31 do
			if f(bits(a, i), bits(b, i)) == 1 then r = r + 2 ^ i end
		end
		return fold(f, r, ...)
	end
	bit_mock.band = function(a, b, ...)
		return fold(function(x, y) return (x == 1 and y == 1) and 1 or 0 end, a, b, ...)
	end
	bit_mock.bor = function(a, b, ...)
		return fold(function(x, y) return (x == 1 or y == 1) and 1 or 0 end, a, b, ...)
	end
	bit_mock.bxor = function(a, b, ...)
		return fold(function(x, y) return (x ~= y) and 1 or 0 end, a, b, ...)
	end
	bit_mock.lshift = function(a, n) return (a % 4294967296) * 2 ^ n end
	bit_mock.rshift = function(a, n) return math.floor((a % 4294967296) / 2 ^ n) end
	bit_mock.bnot = function(a) return 4294967295 - (a % 4294967296) end
	return bit_mock
end

package.preload["ffi"] = function()
	local ffi_mock = {}
	-- 用例可控时钟：update_state 的 2 秒重探测节流靠它推进
	local TICK = 0
	ffi_mock.cdef = function() end
	ffi_mock.new = function() return {} end
	ffi_mock.cast = function() return nil end
	ffi_mock.sizeof = function() return 0 end
	ffi_mock.string = function() return "" end
	ffi_mock.load = function()
		return setmetatable({}, {
			__index = function(t, k)
				if k == "GetTickCount64" then
					return function() return TICK end
				end
				return function() return 0 end
			end
		})
	end
	set_tick = function(v) TICK = v end
	return ffi_mock
end

local LOG = {}

local obslua = {}
obslua.LOG_INFO = 300
obslua.LOG_ERROR = 100
obslua.OBS_SOURCE_VIDEO = 1
obslua.OBS_SOURCE_CUSTOM_DRAW = 2
obslua.script_log = function(lvl, msg)
	LOG[#LOG + 1] = msg
end

local REG = {}
obslua.obs_get_source_by_name = function(nm)
	return REG[nm]
end
obslua.obs_source_get_id = function(s)
	return s and s.id or nil
end
obslua.obs_source_get_name = function(s)
	return s and s.name or nil
end
obslua.obs_source_release = function(s) end
obslua.obs_source_enabled = function(s)
	if s == nil then return false end
	if s.enabled == nil then return true end
	return s.enabled
end
obslua.obs_source_enum_filters = function(s)
	if s == nil then return {} end
	return s.filters or {}
end
obslua.obs_source_list_release = function(f) end
obslua.source_list_release = function(f) end
obslua.obs_source_get_filter_by_name = function(s, nm)
	if s == nil or s.filters == nil then return nil end
	for _, f in ipairs(s.filters) do
		if f.name == nm then return f end
	end
	return nil
end
obslua.obs_source_get_settings = function(s)
	if s == nil then return nil end
	return s.settings
end
obslua.obs_source_update = function(s, st) end
obslua.obs_filter_get_target = function(f)
	return f and f.target or nil
end
obslua.obs_data_get_bool = function(st, k)
	if st == nil then return false end
	return st[k] and true or false
end
obslua.obs_data_set_bool = function(st, k, v)
	st[k] = v
end
obslua.obs_data_get_int = function(st, k)
	if st == nil then return 0 end
	return st[k] or 0
end
obslua.obs_data_get_string = function(st, k)
	if st == nil then return "" end
	return st[k] or ""
end
obslua.obs_data_release = function(st) end
obslua.obs_source_get_base_width = function(s)
	if s == nil then return 0 end
	return s.base_w or 0
end
obslua.obs_source_get_base_height = function(s)
	if s == nil then return 0 end
	return s.base_h or 0
end

local FAIL = 0
local PASS = 0
local function check(cond, name)
	if cond then
		PASS = PASS + 1
		print("  PASS  " .. name)
	else
		FAIL = FAIL + 1
		print("  FAIL  " .. name)
	end
end
local function eq(got, want, name)
	check(got == want, name .. "  [got=" .. tostring(got) .. " want=" .. tostring(want) .. "]")
end
local function log_count(sub)
	local n = 0
	for _, m in ipairs(LOG) do
		if string.find(m, sub, 1, true) then n = n + 1 end
	end
	return n
end
local function has_log(sub)
	return log_count(sub) > 0
end
local function log_clear()
	for i = #LOG, 1, -1 do LOG[i] = nil end
end
"""

# ---------------------------------------------------------------- 用例（拼在源码尾部）
CASES = r"""
print("== T0 常量 ==")
eq(ZOOM_CROP_NAME, "obs-zoom-to-mouse-crop", "T0 联动裁剪滤镜名常量")

print("== T1 精确名匹配：temp_ 临时滤镜不能顶替 ==")
REG["显示器采集"] = {
	id = "monitor_capture", name = "显示器采集", enabled = true,
	settings = { capture_cursor = true },
	filters = {
		{ id = "crop_filter", name = "temp_obs-zoom-to-mouse-crop", enabled = true,
		  settings = { left = 0, top = 0, cx = 1920, cy = 1080 } },
		{ id = "crop_filter", name = "obs-zoom-to-mouse-crop", enabled = true,
		  settings = { left = 100, top = 50, cx = 960, cy = 540 } },
	},
}
S.follow_source = "显示器采集"
eq(follow_find_crop_name(), "obs-zoom-to-mouse-crop", "T1 有 temp_ 也只认精确名")

print("== T2 不拿用户自挂的 Crop/Pad 顶替（旧代码的 bug）==")
REG["自有裁剪采集"] = {
	id = "monitor_capture", name = "自有裁剪采集", enabled = true,
	settings = { capture_cursor = true },
	filters = {
		{ id = "crop_filter", name = "Crop/Pad", enabled = true,
		  settings = { left = 0, top = 0, cx = 1920, cy = 1080 } },
	},
}
S.follow_source = "自有裁剪采集"
eq(follow_find_crop_name(), nil, "T2 用户自挂 Crop/Pad 不被当作联动裁剪框")

print("== T3 其它边界 ==")
REG["色块"] = { id = "color_source", name = "色块", enabled = true, settings = {}, filters = {} }
S.follow_source = "色块"
eq(follow_find_crop_name(), nil, "T3a 非采集源返回 nil")
S.follow_source = "不存在的源"
eq(follow_find_crop_name(), nil, "T3b 源不存在返回 nil")
REG["禁用的裁剪"] = {
	id = "monitor_capture", name = "禁用的裁剪", enabled = true,
	settings = { capture_cursor = true },
	filters = { { id = "crop_filter", name = "obs-zoom-to-mouse-crop", enabled = false,
	              settings = { left = 0, top = 0, cx = 1920, cy = 1080 } } },
}
S.follow_source = "禁用的裁剪"
eq(follow_find_crop_name(), nil, "T3c 裁剪滤镜被禁用时不认")

print("== T4 follow_crop 成功路径 + 换源重置 ==")
S.follow_source = "显示器采集"
local d = { clock = 0 }
local cl, ct, cw, ch = follow_crop(d)
eq(cl, 100, "T4a left")
eq(ct, 50, "T4b top")
eq(cw, 960, "T4c cx")
eq(ch, 540, "T4d cy")
S.follow_source = "自有裁剪采集"
eq(follow_crop(d), nil, "T4e 换源后旧裁剪框立即失效")

print("== T5 找不到 zoom 滤镜：延迟 3 次重解析才提示、不重复 ==")
S.log_on = true
S.follow_source = "没有任何滤镜的采集"
REG["没有任何滤镜的采集"] = {
	id = "monitor_capture", name = "没有任何滤镜的采集", enabled = true,
	settings = { capture_cursor = true }, filters = {},
}
local d5 = { clock = 0 }
follow_crop(d5)
d5.clock = 2; follow_crop(d5)
check(log_count("找不到 zoom 裁剪滤镜") == 0, "T5a 前两次不警告（滤镜可能还没懒建）")
d5.clock = 4; follow_crop(d5)
check(log_count("找不到 zoom 裁剪滤镜") == 1, "T5b 连续第三次找不到才警告")
d5.clock = 6; follow_crop(d5)
d5.clock = 8; follow_crop(d5)
check(log_count("找不到 zoom 裁剪滤镜") == 1, "T5c 同源不重复刷")

print("== T6 自绘接管：滤镜版正常关掉捕获光标 ==")
local cap6 = { id = "monitor_capture", name = "T6采集", enabled = true,
               settings = { capture_cursor = true }, filters = {} }
local filt6 = { id = "mouse_fx_filter", name = "T6滤镜", enabled = true, target = cap6 }
local d6 = { source = filt6, clock = 0 }
S.log_on = true; S.take_cursor = true; S.cur_on = true; S.take_src = ""; S.follow_source = ""
apply_cursor_takeover(d6)
eq(cap6.settings.capture_cursor, false, "T6a 捕获光标被关掉")
check(has_log("已关掉"), "T6b 成功日志（输出日志开着时才打）")

print("== T7 独立源没配接管源：提示一次（INFO 级，跟输出日志开关）==")
local layer = { id = "mouse_fx_source", name = "鼠标高亮层", enabled = true, settings = {} }
S.log_on = true
S.take_src = ""; S.follow_source = ""
local d7 = { source = layer, clock = 0 }
log_clear()
apply_cursor_takeover(d7)
check(log_count("没有可接管的目标") == 1, "T7a 未配置时警告一次（log_on=false 也打）")
d7.clock = 5; apply_cursor_takeover(d7)
d7.clock = 9; apply_cursor_takeover(d7)
check(log_count("没有可接管的目标") == 1, "T7b 不重复刷")

print("== T8 接管源名字写错 / 被改名 ==")
S.take_src = "被改名的采集"
local d8 = { source = layer, clock = 0 }
log_clear()
apply_cursor_takeover(d8)
check(log_count("找不到名为「被改名的采集」的采集源") == 1, "T8a 源不存在时警告")
d8.clock = 5; apply_cursor_takeover(d8)
check(log_count("找不到名为「被改名的采集」的采集源") == 1, "T8b 不重复")
S.take_src = "另一个不存在的源"
d8.clock = 9; apply_cursor_takeover(d8)
check(log_count("另一个不存在的源") == 1, "T8c 原因变化后重新武装")

print("== T9 接管目标不是采集源 ==")
REG["T9色块"] = { id = "color_source", name = "T9色块", enabled = true,
                  settings = { capture_cursor = false }, filters = {} }
S.take_src = "T9色块"
local d9 = { source = layer, clock = 0 }
log_clear()
apply_cursor_takeover(d9)
check(log_count("目标源不是显示器/窗口/游戏采集") == 1, "T9 类型不符时警告")

print("== T10 设置读取失败 ==")
REG["T10采集"] = { id = "monitor_capture", name = "T10采集", enabled = true,
                   settings = nil, filters = {} }
S.take_src = "T10采集"
local d10 = { source = layer, clock = 0 }
log_clear()
apply_cursor_takeover(d10)
check(log_count("读不到目标源的设置") == 1, "T10 读取失败时警告")

print("== T11 滤镜被禁用：不警告也不动作 ==")
local cap11 = { id = "monitor_capture", name = "T11采集", enabled = true,
                settings = { capture_cursor = true }, filters = {} }
local filt11 = { id = "mouse_fx_filter", name = "T11滤镜", enabled = false, target = cap11 }
local d11 = { source = filt11, clock = 0 }
S.take_src = ""; S.follow_source = ""; S.take_cursor = true; S.cur_on = true
log_clear()
apply_cursor_takeover(d11)
check(#LOG == 0, "T11a 禁用滤镜不产生任何日志")
eq(cap11.settings.capture_cursor, true, "T11b 不碰采集源的捕获光标")

print("== T12 滤镜没挂到源上 ==")
local filt12 = { id = "mouse_fx_filter", name = "T12滤镜", enabled = true, target = nil }
local d12 = { source = filt12, clock = 0 }
log_clear()
apply_cursor_takeover(d12)
check(log_count("滤镜没有挂到任何源上") == 1, "T12 孤立滤镜警告")

print("== T13 用户关掉自绘光标：恢复捕获光标 ==")
local cap13 = { id = "monitor_capture", name = "T13采集", enabled = true,
                settings = { capture_cursor = false }, filters = {} }
local filt13 = { id = "mouse_fx_filter", name = "T13滤镜", enabled = true, target = cap13 }
local d13 = { source = filt13, clock = 0, took_cursor = true }
S.log_on = true; S.take_cursor = true; S.cur_on = false; S.take_src = ""; S.follow_source = ""
apply_cursor_takeover(d13)
eq(cap13.settings.capture_cursor, true, "T13a 恢复采集源的捕获光标")
check(has_log("恢复了采集源"), "T13b 恢复日志")

print("== T14 用户关掉自绘接管：不警告 ==")
S.take_cursor = false; S.cur_on = true; S.take_src = ""; S.follow_source = ""
local d14 = { source = layer, clock = 0 }
log_clear()
apply_cursor_takeover(d14)
check(#LOG == 0, "T14 主动关闭接管时不警告")

print("== T15 独立源经「联动缩放源」回退关掉捕获光标 ==")
REG["独立层采集"] = { id = "monitor_capture", name = "独立层采集", enabled = true,
                      settings = { capture_cursor = true }, filters = {} }
S.follow_source = "独立层采集"; S.take_src = ""; S.take_cursor = true; S.cur_on = true
local d15 = { source = layer, clock = 0 }
apply_cursor_takeover(d15)
eq(REG["独立层采集"].settings.capture_cursor, false, "T15 联动缩放源兼任接管目标")

-- ================================================================ 独立源自动跟随
-- 模拟本机三屏（用户实际布局）：SKG27B2 是 Windows 主屏，AOC2477 被采集
enum_monitors = function()
	return {
		{ id = "DISPLAY1", name = "SKG27B2", left = 0,    top = 0,     w = 2560, h = 1440 },
		{ id = "DISPLAY2", name = "AOC2477", left = 309,  top = -1080, w = 1920, h = 1080 },
	}
end
REG["显示器采集2"] = {
	id = "monitor_capture", name = "显示器采集2", enabled = true,
	settings = { capture_cursor = true, monitor_id = "DISPLAY2" },
	filters = {}, base_w = 1920, base_h = 1080,
}
local layer17 = { id = "mouse_fx_source", name = "鼠标高亮层", enabled = true,
                  settings = {}, base_w = 1920, base_h = 1080 }

print("== T16 detect_named_source_region：按源名读捕获的显示器 ==")
S.region_mode = 0; S.follow_source = "显示器采集2"; S.take_src = ""
local r16 = detect_named_source_region("显示器采集2")
eq(r16[1], 309, "T16a left（AOC2477 在主屏右边）")
eq(r16[2], -1080, "T16b top（负偏移，多屏关键）")
eq(r16[3], 1920, "T16c w")
eq(r16[4], 1080, "T16d h")
eq(detect_named_source_region(""), nil, "T16e 空名返回 nil")
eq(detect_named_source_region("不存在的源"), nil, "T16f 源不存在返回 nil")

print("== T17 update_state 自动模式：区域和宽高都跟随捕获屏 ==")
local d17 = { source = layer17, clock = 0 }
S.take_cursor = false; S.cur_on = true; S.monitor_sel = ""; S.log_on = true
set_tick(0)
log_clear()
update_state(d17)
eq(d17.auto[1], 309, "T17a 区域左 = 309（不再傻用主屏 0,0）")
eq(d17.auto[2], -1080, "T17b 区域上 = -1080")
check(has_log("独立源自动匹配"), "T17c 自动匹配日志")
check(has_log("宽高已跟随"), "T17d 宽高跟随日志")
eq(source_def.get_width(d17), 1920, "T17e get_width 返回捕获屏宽")
eq(source_def.get_height(d17), 1080, "T17f get_height 返回捕获屏高")

print("== T18 宽高兜底：没探测到时用手动宽高 ==")
S.canvas_w = 1280; S.canvas_h = 720
local d18 = { source = layer17 }
eq(source_def.get_width(d18), 1280, "T18a 未探测回退手动宽")
eq(source_def.get_height(d18), 720, "T18b 未探测回退手动高")

print("== T19 联动源为空：回退接管目标源探测 ==")
S.follow_source = ""; S.take_src = "显示器采集2"
local d19 = { source = layer17, clock = 0 }
set_tick(10000)
update_state(d19)
eq(d19.auto[1], 309, "T19 经接管目标源探测到同一块屏")

print("== T20 读不到显示器：连续 3 次才提示、不重复、不设错区域 ==")
-- 模拟 script_update 已跑过 get_region()：自动读不到时的兜底 = 主屏
S.region_left, S.region_top, S.region_w, S.region_h = 0, 0, 2560, 1440
S.follow_source = "被删掉的采集"; S.take_src = ""; S.monitor_sel = ""
S.log_on = true
local d20 = { source = layer17, clock = 0 }
set_tick(0); update_state(d20)
set_tick(3000); update_state(d20)
check(log_count("读不到联动源") == 0, "T20a 前两次不提示（同 follow_miss 的节流思路）")
set_tick(6000); update_state(d20)
check(log_count("读不到联动源") == 1, "T20b 第三次打提示（开输出日志时可见）")
set_tick(9000); update_state(d20)
set_tick(12000); update_state(d20)
check(log_count("读不到联动源") == 1, "T20c 不重复刷")
eq(d20.auto, nil, "T20d 探测失败不瞎设区域（交给 monitor_sel/主屏兜底）")
REG["T20窗口"] = { id = "window_capture", name = "T20窗口", enabled = true,
                   settings = {}, filters = {}, base_w = 800, base_h = 600 }
S.follow_source = "T20窗口"
local d20b = { source = layer17, clock = 0 }
set_tick(0); update_state(d20b)
set_tick(3000); update_state(d20b)
set_tick(6000); update_state(d20b)
check(log_count("读不到联动源") == 2, "T20e 窗口采集（无 monitor_id）走同一条失败提示")

print("== T21 没配联动源：monitor_sel 兜底（原有行为保留）==")
S.follow_source = ""; S.take_src = ""; S.monitor_sel = "DISPLAY2"; S.log_on = true
local d21 = { source = layer17, clock = 0 }
set_tick(0)
log_clear()
update_state(d21)
eq(d21.auto[1], 309, "T21a 用指定显示器矩形")
check(has_log("独立源自动：使用指定显示器"), "T21b 原有日志文案保留")

print("== T22 换联动源：重新探测、日志重新武装、宽高跟着换 ==")
REG["另一块屏采集"] = {
	id = "monitor_capture", name = "另一块屏采集", enabled = true,
	settings = { capture_cursor = true, monitor_id = "DISPLAY1" },
	filters = {}, base_w = 2560, base_h = 1440,
}
S.follow_source = "另一块屏采集"; S.monitor_sel = ""
local d22 = { source = layer17, clock = 0 }
set_tick(0); update_state(d22)
eq(d22.auto[1], 0, "T22a 新屏原点 0,0（SKG27B2）")
eq(d22.auto[3], 2560, "T22b 新屏 2560 宽")
eq(source_def.get_width(d22), 2560, "T22c 宽高自动换成 2560")
check(log_count("独立源自动匹配") == 1, "T22d 换源后重新打匹配日志（重新武装）")
check(has_log("宽高已跟随捕获的显示器：2560x1440"), "T22e 宽高更换日志")

print("== T23 输出日志关闭（默认）：引导提示完全静默，不弹不刷 ==")
S.log_on = false
S.follow_source = ""; S.take_src = ""
local d23 = { source = layer17, clock = 0 }
log_clear()
apply_cursor_takeover(d23)
check(#LOG == 0, "T23a log_on=false 时接管提示静默（OBS 不会弹脚本日志窗）")
set_tick(0); update_state(d23)
set_tick(3000); update_state(d23)
check(#LOG == 0, "T23b 自动匹配失败也静默")

print("== T24 跨实例去重：同一原因 60 秒内只提示一次 ==")
S.log_on = true; S.take_cursor = true; S.cur_on = true
S.take_src = "被改名的采集2"
local d24a = { source = layer17, clock = 0 }
local d24b = { source = layer17, clock = 0 }
log_clear()
apply_cursor_takeover(d24a)
apply_cursor_takeover(d24b)
check(log_count("找不到名为「被改名的采集2」的采集源") == 1, "T24a 两个实例同一原因只报一次（反复删加源不刷屏）")

print("")
if FAIL > 0 then
	error("FAILED: " .. FAIL .. " 个断言没过")
end
print("ALL PASS (" .. PASS .. " 个断言)")
"""


def main():
    with open(LUA_FILE, "rb") as f:
        src = f.read().decode("utf-8")
    program = MOCK + "\n" + src + "\n" + CASES + "\n"
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    try:
        rt.execute(program)
    except lupa.LuaError as e:
        print("LUA ERROR:", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
