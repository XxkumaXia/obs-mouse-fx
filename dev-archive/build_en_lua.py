# -*- coding: utf-8 -*-
"""Regenerate the English build of mouse-fx.lua from the Chinese original.

Run from the repository root:

    python dev-archive/build_en_lua.py

Reads  obs-fx/mouse-fx.lua        (Chinese source of truth)
Writes obs-fx-en/mouse-fx.lua     (English build)
       build/obs-mouse-fx-v*.zip  (Chinese package)
       build/obs-mouse-fx-en-v*.zip (English package)

Both archives carry the same version - the version is read from the source, never
typed by hand - and the filenames differ by the "-en" token only.

Three maps: LIT (string literals, matched with their quotes, longest first),
COM (standalone comment lines, by line number), INLINE (trailing comments).
Code lines are never rewritten, so the two builds differ only in strings and
comments. Prints a summary and fails loudly if any CJK is left behind.
"""
import io, re, sys

SRC = "obs-fx/mouse-fx.lua"
DST = "obs-fx-en/mouse-fx.lua"

# ---------------------------------------------------------------- string literals
LIT = [
("[鼠标高亮] ", "[Mouse FX] "),
("当前 OBS 的 Lua 环境没有 ffi，脚本无法获取鼠标位置，已停止加载",
 "This OBS build has no ffi in its Lua environment, so the mouse position can't be read. Loading stopped."),
("联动缩放：源「", "Zoom link: source '"),
("」上找不到 zoom 裁剪滤镜（", "' has no zoom crop filter ("),
("），暂按未放大处理。", ") — treating the view as unzoomed for now. "),
("不会拿采集源上其它 Crop/Pad 滤镜顶替；zoom 脚本建好滤镜后会自动接上",
 "Other Crop/Pad filters on that source are never used as a stand-in; it reconnects once the zoom script creates the filter"),
("手动光标图：", "Manual cursor image: "),
("，", ", "),
(" 帧，热点 ", " frames, hotspot "),
("自动读取系统光标失败，改用「光标图片」或内置箭头兜底",
 "Auto cursor grab failed; falling back to the cursor image or the built-in arrow"),
("已抓到系统光标：", "System cursor grabbed: "),
("，热点 ", ", hotspot "),
(" 帧", " frames"),
("effect 里取不到的参数：", "Effect parameters that couldn't be fetched: "),
("blank.png 加载失败：", "blank.png failed to load: "),
("effect 加载失败：", "effect failed to load: "),
("自绘接管：滤镜没有挂到任何源上，找不到要关「捕获光标」的目标",
 "Cursor takeover: the filter isn't attached to any source, so there's no target to turn \\\"Capture cursor\\\" off on"),
("自绘接管：没有可接管的目标。独立源请把「接管用的采集源名」填成你的采集源，",
 "Cursor takeover: no target to take over. For a standalone layer, set \\\"Capture source name\\\" to your capture source, "),
("或选中「联动缩放源」（接管源名留空时用它）；否则采集源的「捕获光标」关不掉——",
 "or select \\\"Zoom link source\\\" (used when the takeover name is empty). Otherwise \\\"Capture cursor\\\" stays on — "),
("半透明填充会糊在光标上，配合放大脚本时更是两个光标",
 "the translucent fill smears over the cursor, and with a zoom script you get two cursors"),
("自绘接管：找不到名为「", "Cursor takeover: no capture source named '"),
("」的采集源（被改名或删除了？）。", "' (renamed or deleted?). "),
("「捕获光标」关不掉，画面上会出现两个光标",
 "\\\"Capture cursor\\\" can't be turned off, so two cursors will show on screen"),
("自绘接管：目标源不是显示器/窗口/游戏采集，关不掉它的「捕获光标」",
 "Cursor takeover: the target isn't a display/window/game capture, so its \\\"Capture cursor\\\" can't be turned off"),
("自绘接管：读不到目标源的设置，本轮跳过",
 "Cursor takeover: couldn't read the target's settings, skipping this round"),
("自绘接管：已关掉「", "Cursor takeover: turned \\\"Capture cursor\\\" off on '"),
("」的「捕获光标」，改由脚本画在高亮圈之上", "', the script now draws the cursor above the highlight ring"),
("自绘接管已关闭：恢复了采集源的「捕获光标」",
 "Cursor takeover disabled: \\\"Capture cursor\\\" restored on the capture source"),
("自动匹配采集显示器：", "Auto-matched capture monitor: "),
("自动匹配失败，改用主屏兜底。本机显示器 = ",
 "Auto-match failed, falling back to the primary monitor. Monitors = "),
("独立源自动匹配：联动源「", "Standalone auto-match: linked source '"),
("」捕获 ", "' captures "),
("独立源宽高已跟随捕获的显示器：", "Standalone layer size now follows the captured monitor: "),
("独立源自动匹配：读不到联动源「", "Standalone auto-match: can't read the monitor captured by '"),
("」捕获的显示器（源被删了 / 不是显示器采集 / 显示器识别失败），",
 "' (source deleted / not a display capture / monitor detection failed), "),
("已退回「指定显示器」/主屏。多屏录制时请确认「联动缩放源」",
 "falling back to \\\"Specific monitor\\\" / primary. When recording multiple monitors, make sure \\\"Zoom link source\\\" "),
("填的是当前在录那块屏的采集源", "points at the capture source for the monitor you're recording"),
("独立源自动：使用指定显示器 ", "Standalone auto: using specific monitor "),
("画面尺寸 ", "Frame size "),
("，映射区域 ", ", mapped region "),
("联动缩放：「", "Zoom link: '"),
("」裁剪框 ", "' crop rect "),
("，倍率 ", ", factor "),
("首帧渲染完成（", "First frame rendered ("),
("）", ")"),
("抓取/加载光标出错（已退回内置箭头）：", "Cursor grab/load error (fell back to the built-in arrow): "),
("鼠标高亮叠加 (Mouse FX)", "Mouse Highlight Overlay (Mouse FX)"),
("鼠标高亮层 (Mouse FX)", "Mouse Highlight Layer (Mouse FX)"),
("在画面上叠加自绘鼠标效果：常驻高亮圈 + 点击扩散波纹 + 拖影 + 光标。\\n",
 "Draws a self-drawn mouse overlay on the canvas: persistent highlight ring + click ripples + trail + cursor.\\n"),
("用法一（推荐）：给「显示器采集 / 窗口采集」加滤镜「鼠标高亮叠加」，自动跟随那块屏；\\n",
 "Usage 1 (recommended): add the \\\"Mouse Highlight Overlay\\\" filter to a Display / Window Capture source — it follows that monitor;\\n"),
("用法二：场景里新增来源「鼠标高亮层」拖到最上层，「坐标区域」选「自动」并填好\\n",
 "Usage 2: add a \\\"Mouse Highlight Layer\\\" source, drag it to the top, set \\\"Region\\\" to \\\"Auto\\\" and fill in\\n"),
("「联动缩放源」（你在录的那块屏的采集源）即可——区域和宽高都自动跟随那块屏，\\n",
 "\\\"Zoom link source\\\" (the capture source for the monitor you're recording) — region and size both follow it,\\n"),
("换屏录制不用改任何设置；也可选「指定显示器」手动固定。\\n",
 "so switching monitors needs no reconfiguration; \\\"Specific monitor\\\" pins it manually instead.\\n"),
("光标：脚本会关掉采集源的「捕获光标」，改由自己把当前系统光标画在高亮圈之上，\\n",
 "Cursor: the script turns off \\\"Capture cursor\\\" on the capture source and draws the live system cursor above the ring,\\n"),
("所以圈永远在光标「下面」；换光标主题 / 换形状会自动跟上。\\n",
 "so the ring is always under the cursor; theme and shape changes follow automatically.\\n"),
("配合 obs-zoom-to-mouse 缩放时：独立源选好「联动缩放源」即可全程对齐。\\n",
 "With obs-zoom-to-mouse: pick \\\"Zoom link source\\\" and a standalone layer stays aligned through the whole zoom.\\n"),
("坐标由 Win32 API 实时获取，无需任何外部程序。",
 "Coordinates come from the Win32 API in real time — no external program involved."),
("—— 坐标区域 ——", "—— Region ——"),
("鼠标坐标区域", "Mouse coordinate region"),
("自动（滤镜读挂载目标；独立源读「联动缩放源」捕获的显示器）",
 "Auto (filter reads its target; standalone reads the monitor captured by \\\"Zoom link source\\\")"),
("主屏", "Primary monitor"),
("虚拟桌面（多屏全部映射）", "Virtual desktop (map all monitors)"),
("自定义（用下面的数值）", "Custom (use the values below)"),
("指定显示器（用下面的下拉）", "Specific monitor (use the dropdown below)"),
("自定义 左", "Custom left"),
("自定义 上", "Custom top"),
("自定义 宽", "Custom width"),
("自定义 高", "Custom height"),
("整体偏移 X（微调）", "Global offset X (fine tune)"),
("整体偏移 Y（微调）", "Global offset Y (fine tune)"),
("缩放修正", "Scale correction"),
("指定显示器（区域选「指定显示器」时生效；「自动」读不到联动源时兜底）",
 "Specific monitor (used when region = \\\"Specific monitor\\\"; fallback when \\\"Auto\\\" can't read the link source)"),
("（未选 / 用主屏）", "(none / use primary)"),
("独立源（鼠标高亮层）是独立图层、没有挂载目标，所以「自动」无法读采集源。\\n",
 "A standalone layer (Mouse Highlight Layer) is a detached layer with no target, so \\\"Auto\\\" can't read a capture source.\\n"),
("请在下方「指定显示器」选你正在录的那块屏；并把最下方「独立源 宽/高」设成该屏分辨率，\\n",
 "Pick the monitor you're recording under \\\"Specific monitor\\\" below, and set \\\"Layer width / height\\\" at the bottom\\n"),
("坐标轴才会对得上。", "to that monitor's resolution, or the axes won't line up."),
("联动缩放源（配合 obs-zoom-to-mouse 用）", "Zoom link source (for use with obs-zoom-to-mouse)"),
("（不联动）", "(no link)"),
("独立源配合 obs-zoom-to-mouse 放大时，高亮会因不吃裁剪而错位。\\n",
 "When a standalone layer is used with obs-zoom-to-mouse, the highlight drifts because it doesn't take the crop.\\n"),
("在这里选中被缩放的那台采集源，高亮层就会按它的裁剪框实时重映射坐标，\\n",
 "Pick the zoomed capture source here and the layer remaps its coordinates to that crop rect every frame,\\n"),
("放大 / 跟随 / 缩回全程对齐（仅对「鼠标高亮层」独立源生效；\\n",
 "staying aligned through zoom in / follow / zoom out (standalone \\\"Mouse Highlight Layer\\\" only;\\n"),
("滤镜版加在裁剪滤镜下方，天然一起被放大，无需此项）。\\n",
 "the filter version sits below the crop filter and gets zoomed with the frame, so it doesn't need this).\\n"),
("若列表里没有刚建的源，重新加载一次脚本即可刷新。",
 "If a source you just created isn't listed, reload the script to refresh."),
("—— 常驻高亮圈 ——", "—— Highlight ring ——"),
("启用高亮圈", "Enable highlight ring"),
("高亮样式", "Highlight style"),
("外环 + 内部填充", "Outer ring + fill"),
("仅外环", "Outer ring only"),
("仅内部填充", "Fill only"),
("半径", "Radius"),
("外环粗细", "Ring thickness"),
("颜色", "Color"),
("外环不透明度", "Ring opacity"),
("内部填充强度", "Fill strength"),
("圆心下移（让圆/柔光落在光标下方，不糊住光标）",
 "Circle center offset (drops ring/glow below the cursor so it doesn't wash over it)"),
("启用柔光", "Enable glow"),
("柔光半径", "Glow radius"),
("柔光强度", "Glow strength"),
("图层顺序（自下而上）：拖影 → 柔光 → 点击波纹 → 内部填充 → 外环 → 光标。\\n",
 "Layer order (bottom to top): trail → glow → click ripples → fill → ring → cursor.\\n"),
("所以高亮圈永远在光标「下面」——前提是用下面的「自绘光标」。\\n",
 "So the ring is always under the cursor — provided \\\"Self-drawn cursor\\\" below is on.\\n"),
("「圆心下移」现在不需要了，保持 0 即可。",
 "\\\"Circle center offset\\\" is no longer needed; leave it at 0."),
("—— 点击波纹 ——", "—— Click ripples ——"),
("启用点击效果", "Enable click effects"),
("单环持续（秒）", "Ring duration (s)"),
("起始半径", "Start radius"),
("结束半径", "End radius"),
("环粗细", "Ring width"),
("重数（1~3）", "Ring count (1–3)"),
("重间延迟（秒）", "Delay between rings (s)"),
("整体不透明度", "Overall opacity"),
("左键颜色", "Left button color"),
("右键颜色", "Right button color"),
("中键颜色", "Middle button color"),
("—— 移动拖影 ——", "—— Motion trail ——"),
("启用拖影", "Enable trail"),
("残影数量", "Trail count"),
("残影半径", "Trail dot radius"),
("采样间隔（秒）", "Sample interval (s)"),
("拖影颜色", "Trail color"),
("拖影不透明度", "Trail opacity"),
("—— 自绘光标（永远画在高亮圈之上）——", "—— Self-drawn cursor (always above the ring) ——"),
("启用自绘光标", "Enable self-drawn cursor"),
("自动读取系统当前光标（换主题 / 换形状自动跟上）",
 "Read the live system cursor (theme / shape changes follow automatically)"),
("重新抓取光标（换主题/换图片后没跟上就点一下）",
 "Regrab cursor (click if a theme or image change wasn't picked up)"),
("高亮圈是叠在采集画面上的，而系统光标早就被「烤」进采集画面里了，\\n",
 "The ring is drawn over the captured frame, but the system cursor was baked into that frame long ago,\\n"),
("所以高亮圈一定会盖住它。要做到「圈在光标下面」，只能关掉采集源的\\n",
 "so the ring would always cover it. To get the ring under the cursor, the only way is to turn off\\n"),
("「捕获光标」，改由本脚本把光标画在最上层——也就是下面这些设置。\\n",
 "\\\"Capture cursor\\\" on the capture source and let this script draw the cursor on the top layer — the settings below.\\n"),
("「自动读取」= 运行时直接从 Windows 取当前光标位图，换主题 / 换形状都会自动跟上；\\n",
 "\\\"Auto read\\\" = pull the current cursor bitmap from Windows at runtime; theme and shape changes follow.\\n"),
("关掉它（或自动读取失败）就用「光标图片」那张图。图片若是横向平铺的多帧，\\n",
 "Turn it off (or if auto fails) and the \\\"Cursor image\\\" file is used. A horizontally tiled image\\n"),
("会按「帧率」循环播放。热点 = 光标作用点，相对单帧左上角（自带图是 1,1，普通箭头是 0,0）。\\n",
 "plays back at the \\\"frame rate\\\". Hotspot = the cursor's action point, relative to one frame's top-left\\n"),
("换了主题没自动跟上时，点上面的「重新抓取光标」即可。\\n",
 "(the bundled image is 1,1; a plain arrow is 0,0). If a theme change isn't picked up, hit \\\"Regrab cursor\\\" above.\\n"),
("想看抓取结果（抓到多少像素、几帧），勾选最下面的「输出日志」。",
 "To see what was grabbed (pixel count, frame count), tick \\\"Output log\\\" at the bottom."),
("光标图片（相对脚本目录）", "Cursor image (relative to script folder)"),
("图片帧数（0=按宽/高自动）", "Image frame count (0 = auto from width/height)"),
("多帧光标帧率", "Multi-frame cursor fps"),
("热点 X", "Hotspot X"),
("热点 Y", "Hotspot Y"),
("光标缩放", "Cursor scale"),
("自绘接管：自动关掉采集源的「捕获光标」（必须开，否则画面上是两个光标）",
 "Cursor takeover: turn off \\\"Capture cursor\\\" on the capture source automatically (required, otherwise two cursors show)"),
("接管用的采集源名（独立源必填；留空 = 用上面的「联动缩放源」）",
 "Capture source name for takeover (standalone: required; empty = use \\\"Zoom link source\\\" above)"),
("—— 内置箭头（自动读取和图片都失败时的兜底）——",
 "—— Built-in arrow (fallback when both auto read and the image fail) ——"),
("箭头填充色", "Arrow fill color"),
("箭头描边色", "Arrow outline color"),
("—— 其它 ——", "—— Misc ——"),
("跟手程度（1=完全不插值）", "Smoothing (1 = no interpolation)"),
("独立源 宽（「自动」模式下跟随捕获的显示器）",
 "Layer width (in \\\"Auto\\\" mode it follows the captured monitor)"),
("独立源 高（「自动」模式下跟随捕获的显示器）",
 "Layer height (in \\\"Auto\\\" mode it follows the captured monitor)"),
("输出日志（调试用，默认关闭不刷屏）",
 "Output log (debugging; off by default to keep the log quiet)"),
("已加载 v", "Loaded v"),
("。区域 ", ". Region "),
("已卸载", "Unloaded"),
]

# ---------------------------------------------------------------- comments (by line number)
COM = {
21: " Script settings table: must be declared before any function that reads it!",
22: " In Lua a local only becomes visible at its declaration point, so a function defined",
23: " above it compiles S into a global → nil at runtime → every frame raises",
24: " \"attempt to index global 'S'\". (Bitten by this twice. Keep S at the top of the file.)",

27: " Counter behind the \"Regrab cursor\" button: each click bumps it and the value goes into",
28: " cursor_update's key, so every instance runs a \"clear + resample\". Declared at the top of",
29: " the file so the properties callback closure and cursor_update both see it.",

32: " Report each distinct error once (a failing theme switch would otherwise flood the log)",

35: " Version string, printed in the load log: when troubleshooting, confirm which build OBS",
36: " actually loaded. (Shipped a fix once while OBS kept running the old file.)",

39: " Logging is off by default so the OBS script log stays quiet. Turn on \"Output log\" to debug.",
40: " Level policy (changed in v1.1.1, see DEVELOPMENT.md pitfall 10):",
41: "   the OBS frontend auto-opens and raises the script log window for anything at or above",
42: "   LOG_WARNING (obs-studio/plugins/frontend-tools/scripts.cpp, log callback),",
43: "   i.e. ERROR and WARNING pop a window, INFO does not.",
44: "   So: log() = INFO, follows the \"Output log\" switch, never pops — every hint goes here;",
45: "   logerr() = ERROR, pops unconditionally, reserved for genuinely fatal failures (effect / blank.png",
46: "   failing to load means nothing can be drawn at all — the user has to know).",

52: " Errors always print (rare, and they flag real configuration problems)",

113: " Enumerate all monitors: returns a list of {left, top, w, h, id} (id = device interface path)",
147: " Find the monitor rect matching an OBS monitor_id (auto mode)",
170: " Filter: read the display-capture settings of the target source and derive the mapping region",
193: " Standalone source: read the monitor rect it captures, by source name (auto mode).",
194: " The filter can call obs_filter_get_target and get its target directly; a standalone source is",
195: " a detached layer, so it can only look the source up by name. This is the multi-monitor trick:",

228: " ---------------------------------------------------------------- zoom link",
229: " Used together with obs-zoom-to-mouse.lua: it zooms by shrinking the source's output with a",
230: " crop filter and stretching the scene item back to full size, leaving the item transform alone.",
231: " A standalone layer (Mouse Highlight Layer) is a separate layer that never sees that transform,",
232: " so here we read the live crop rect off the linked source and remap cursor coordinates into the",
233: " zoomed frame. Fixed filter name used by obs-zoom-to-mouse (BlankSourceCode); only that exact",

235: " Resolve the crop filter name on the linked source. ★ Take it live, release it right away, never hold a source ref across frames ★",
236: " (Once cached the source ref in d.cap long-term: at OBS shutdown that ref kept the source alive,",
237: "  obs_source_destroy_defer then released in the wrong order → unhandled c0000005 → crash / recovery prompt on every launch.)",

253: " Find the crop filter: only the exact obs-zoom-to-mouse name counts.",
254: " It used to be \"any name containing zoom, else fall back to any enabled crop_filter\". Two pitfalls:",
255: "   ① the zoom script converts a scene item's own transform crop into a temporary filter",
256: "      named temp_obs-zoom-to-mouse-crop — contains \"zoom\", but it holds the user's static",
257: "      crop, not the per-frame animation rect, so trusting it skews the factor and offsets the overlay;",
258: "   ② a Crop/Pad filter the user added on the zoom script's advice gets taken as the link rect,",
259: "      the coordinate frames don't match, and with a failed cursor takeover you get two cursors on screen.",
260: " Now: no match returns nil (the caller treats it as unzoomed and logs a warning). Never a substitute.",

283: " Returns the current crop rect cl, ct, cw, ch (in the linked source's space); nil when unlinked/unreadable",
288: " Invalidated on source change; otherwise the filter name is re-resolved every 2 s (either can be renamed)",

301: " Warn only after a few consecutive misses: the zoom script creates its crop filter",
302: " lazily, a few seconds after load or a scene switch — can't shout on the first miss.",

351: " ---------------------------------------------------------------- settings",
353: " OBS's obs_properties_add_color returns 0xAABBGGRR (the low byte is R!)",
354: " Parsed it as 0xAARRGGBB once: red↔blue and cyan↔yellow swapped. Don't change it back.",
364: " Build an OBS color int from (r,g,b,a), each 0–255. No hand-written literals.",

421: " Self-drawn cursor: drawn last = topmost, so the persistent ring always sits *under* it",
440: " 0 auto (follow the captured monitor) / 1 primary / 2 virtual desktop / 3 custom / 4 specific monitor",
459: " Settings that must be stored as double (all other numeric ones are int)",

581: " ---------------------------------------------------------------- cursor grab",
582: " Read the \"current cursor\" bitmap (hotspot included) straight from Windows at runtime:",
583: "   GetCursorInfo → GetIconInfo → GetDIBits → encode to PNG ourselves → hand it to OBS as a texture.",
584: " So cursor theme changes, shape changes (arrow↔text↔hand) and .ani animations all follow along.",
616: " ---- minimal PNG encoder (RGBA8 + stored/uncompressed deflate) — no external library ----",
658: " zlib stream: all stored (uncompressed) blocks — simplest, and hardest to get wrong",
680: " rgba must be top-down, 4 bytes per pixel",
713: " Grab the current system cursor once; returns w, h, hotx, hoty, rgba (top-down)",

734: " Note: GetObjectA lives in gdi32, not user32! Getting this wrong throws",
735: " \"cannot resolve symbol 'GetObjectA'\" and silently kills the whole grab path.",

749: " ============ the mask must be read at its own bit depth ============",
750: " [the real root cause of the flash-to-black bug]",
751: " hbmMask is a 1bpp bitmap (bmBitsPixel=1)! Early builds passed a 32bpp",
752: " BITMAPINFOHEADER to GetDIBits, and Windows can't turn a 1bpp bitmap into a",
753: " 32bpp request, so the returned buffer had alpha = 0 everywhere → `mb > 127`",
754: " was never true → every pixel counted as opaque, and the cursor was drawn as",
755: " one solid black square. Measured: a 32×32 mask really does contain 297",
756: " \"transparent\" pixels — exactly that number. Correct approach: request biBitCount=1 and read the bits.",

775: " ============ color bitmap: also read at its own bit depth ============",
776: " 32bpp (with alpha) and 8bpp (indexed + palette) need separate branches.",
795: " 32bpp cursors carry real alpha; old 8bpp cursors have alpha = 0 always,",
796: " so use the AND mask for transparency instead (white in the mask = transparent)",
807: " no usable alpha and no mask → this grab is invalid; let the caller retry / fall back",
828: " 1bpp: bit set = transparent (white), clear = opaque",
845: " a frame with no opaque pixels at all = invalid (grab timing, or the cursor is hidden);",
846: " keeping it only makes the animation flash empty. Drop it.",

870: " Note: the next 4 functions must all be called inside a graphics context (render_data / after enter_graphics)",
872: " Each clear bumps a \"sample serial\": it goes into the temp PNG filename, so no regrab",
873: " (shape change / theme change / button click) can ever collide with an old filename —",
874: " which also sidesteps the texture-cache-by-path problem where a new cursor showed the old image.",

893: " [anti flash-to-black] sanity-check before the texture is created, keep bad frames out.",
894: " Sampling grabs several frames back to back; during that window the cursor may be",
895: " mid-animation, or the GPU/desktop compositor may be swapping drawing surfaces, so a",
896: " grab can come back \"almost fully transparent\" or \"almost fully black\". Once such a",
897: " frame enters the multi-frame loop it plays back as a cursor flashing black at a regular interval.",

913: " too few opaque pixels → an empty frame, drop it",
917: " almost all opaque pixels are black → the classic \"black square\" leftover, drop it.",
918: " A healthy 32×32 cursor measures 71% opaque with 18% of that black — far from this threshold.",

955: " Manual mode: load a PNG (multi-frame = horizontally tiled)",
994: " [anti flash-to-black] same reasoning as the auto-grab side: 2 frames alternating looks like flicker.",
995: " So a 2-frame image is shown statically as frame 1 instead.",
1000: " inset half a pixel on each side so point sampling can't touch the neighbouring frame",
1005: " single frame / two frames: always frame 1",

1019: " REGRAB is the \"Regrab cursor\" button's counter: putting it in the key means one click",
1020: " makes every instance run \"clear → resample\".",
1031: " every settings change / \"Regrab cursor\" click gets a fresh round of feedback",
1067: " advance the counter either way: a failed grab must still finish the sampling stage,",
1068: " otherwise it's stuck in probe forever and never reaches the cursor-image fallback.",
1086: " a grab has failed before: retry every 2 s. On success it switches back to the drawn cursor",
1087: " by itself; meanwhile the image / built-in arrow holds the frame, so there's no blank window.",

1097: " [anti flash-to-black] animation frame selection.",
1098: " Sampling may catch only 2 distinct frames (or 1), and one of them is often an",
1099: " in-between leftover. Playing those 2 alternating reads as a regular black flash. So:",
1100: "",
1101: "   · 1 frame → show it statically, no animation (most stable)",
1102: "   · 2 frames → no alternation, pin the \"most solid\" one",
1103: "     (most opaque pixels — usually the main shape; leftovers cover less area)",
1104: "   · 3+ frames → actually loop at the frame rate",
1118: " auto failed → fall through to the manual image",
1123: " the image failed too; stop retrying every frame",

1138: " ---------------------------------------------------------------- instances",
1218: " In OBS 32's Lua bindings vec2/vec4 are objects: construct empty, then fill with *_set",

1255: " The target capture source's own cursor would cover the highlight; \"cursor takeover\" puts it underneath",
1262: " Hint de-duplication: one report per instance per reason (a changed reason re-arms it);",
1263: " across instances the same reason is reported at most once per 60 s — repeatedly deleting and",
1264: " re-adding sources or rebuilding instances on scene switches won't flood the log.",
1265: " Goes through log() (INFO): off by default, never pops; turn on \"Output log\" to see everything.",
1266: " (These hints used to go through logerr and pop unconditionally: OBS raises the script log window",

1292: " Find the capture source whose \"Capture cursor\" should be turned off:",
1293: "   filter instance → its target source (borrowed ref — must NOT be released)",
1294: "   standalone      → take_src (empty → fall back to \"zoom link source\") (owned ref — must release)",
1325: " a user-disabled filter is a normal state (don't touch the capture source), no warning",

1385: " State update: read coordinates and buttons, advance animation.",
1386: " Doesn't rely on video_tick (OBS skips tick while a source is inactive); render_frame calls it too.",
1398: " A filter has no size of its own: use the target source's size; a standalone layer uses its canvas size",
1415: " auto mode: periodically read the monitor rect the capture source is on",

1442: " A standalone source has no target: auto mode first reads the monitor actually captured by",
1443: " the linked / takeover source (multi-monitor with zero config: switch the monitor in the",
1444: " capture source and this follows within 2 s, size included); only if that fails, specific monitor → primary.",
1451: " linked source changed: re-probe, re-arm the log",
1485: " no link/takeover source configured: fall back to the monitor picked in \"specific monitor\" (old behaviour)",

1527: " Zoom link: standalone sources only. The filter version already sits downstream of the crop",
1528: " filter and gets cropped and stretched with the frame, so it aligns for free; a standalone layer must remap itself.",
1534: " convert the cursor into the linked source's frame space, subtract the crop origin, then",
1535: " scale by \"frame size / crop size\" into canvas coordinates",

1612: " zoom factor: when a standalone layer follows obs-zoom-to-mouse, highlight sizes scale with it",
1614: " fill / glow center: shifted down so the highlight doesn't cover the system cursor",
1634: " image cursor: drawn last = topmost, so the highlight ring always sits *under* the cursor",
1635: " report each error once, and via log rather than logerr:",
1636: " the image → built-in arrow fallback already covers it; this is recoverable and shouldn't pop the script log.",

1673: " click ripples",
1699: " trail",
1727: " ---------------------------------------------------------------- filter",

1751: " In OBS 32 the effect handed to a script can't be used for tech_end directly; take the default effect explicitly",
1755: " This filter must output at full resolution (base 1920×1080): the crop-and-zoom filter sits ABOVE it",
1756: " (top of the filter array = the final output stage) and crops the zoomed region out of the full-size",
1757: " frame this filter produces. If this filter shrank its output there'd be nothing left to crop. Ring",
1758: " coordinates are computed against the base resolution too (d.width in update_state), so the crop filter",

1763: " ---------------------------------------------------------------- standalone source",
1782: " when \"auto\" detects the capture source's monitor, width/height follow that monitor (multi-monitor, zero config);",
1783: " only when detection fails (no linked source / source deleted) does the manual width apply",
1805: " ---------------------------------------------------------------- script panel",

1837: " specific monitor dropdown: used when region = \"specific monitor\"; also the fallback when \"auto\" can't read the link source",
1855: " zoom link source: standalone layer follows obs-zoom-to-mouse's crop zoom",
1930: " If a theme change isn't picked up (Windows sometimes reuses the same cursor handle, so the",
1931: " script can't tell the difference), one click forces a clear + regrab. The callback runs on the",
1932: " UI thread and only bumps the counter; the real resample still happens in the graphics context (cursor_update).",
}

# ---------------------------------------------------------------- block comment header (plain text lines)
HEAD = {
2: "mouse-fx.lua — OBS mouse highlight overlay (filter / standalone source)",
4: "Usage: load this file from the OBS menu \"Tools → Scripts → +\".",
5: "      Then right-click a Display / Window / Game Capture source → Filters → Add",
6: "      \"Mouse Highlight Overlay\"; or add a \"Mouse Highlight Layer\" source to the scene.",
8: "How it works: LuaJIT's ffi calls Win32 directly for cursor position and buttons,",
9: "      then mouse-fx.effect draws the highlight ring / click ripples / trail / self-drawn cursor.",
10: "      No external service, browser source or Python environment required.",
12: "Note: mouse-fx.effect and blank.png must sit in the same folder as this file.",
}

# ---------------------------------------------------------------- inline trailing comments (code kept verbatim)
INLINE = {
377: " 0 auto / 1 primary / 2 virtual desktop / 3 custom / 4 specific monitor",
378: " specific monitor: the monitor's DeviceID (used when region = 4)",
379: " zoom link source: source name zoomed by obs-zoom-to-mouse (standalone only)",
389: " 0 ring+fill / 1 ring only / 2 fill only",
395: " circle center shift down for fill/glow (keeps it off the system cursor)",
423: " read the live system cursor (theme / shape changes follow automatically)",
424: " image used when auto fails (relative to script dir; frames tiled horizontally; repo ships a 32x32 neutral arrow)",
425: " 0 = derive frame count from width/height",
426: " playback rate for multi-frame cursors",
427: " hotspot (relative to one frame's top-left, pixels)",
432: " cursor takeover: turn off \"Capture cursor\" on the capture source",
433: " capture source name for takeover (standalone only; empty = use zoom link source)",
437: " output log: off by default, keeps the OBS script log quiet",
759: " 1bpp rows are 4-byte aligned",
767: " key: 1bpp",
771: " bytes are read below as (srow + x/8)",
818: " the mask is bottom-up too",
819: " mask stride at 1bpp",
820: " color stride at 32bpp",
866: " how many samples (to reconstruct .ani animations)",
867: " sample interval (seconds)",
922: " used to pick the most solid frame when there are 2",
924: " content fingerprint: identical frames aren't loaded twice",
944: " already in VRAM, the file doesn't need to stay",
964: " relative paths resolve against the script's folder",
978: " horizontal frames: width/height",
1052: " shape/theme changed: resample (clearing also bumps the sample serial)",
1298: " filter is disabled; leave the capture source alone",
1649: " bind a valid texture so we never sample an empty one",
}

# ---------------------------------------------------------------- apply
src = io.open(SRC, encoding="utf-8").read()
lines = src.split("\n")
before = len(lines)

for ln, tail in COM.items():
    l = lines[ln - 1]
    i = l.index("--")
    lines[ln - 1] = l[:i] + "--" + tail

for ln, text in HEAD.items():
    lines[ln - 1] = text

for ln, tail in INLINE.items():
    l = lines[ln - 1]
    i = l.index("--")
    lines[ln - 1] = l[:i + 2] + tail

src = "\n".join(lines)

# literals: longest first so short keys can't eat long ones
applied = {}
for zh, en in sorted(LIT, key=lambda p: -len(p[0])):
    key = '"' + zh + '"'
    if key in src:
        applied[zh] = src.count(key)
        src = src.replace(key, '"' + en + '"')

# mark the build in the load log so the OBS log tells the two builds apart
src = src.replace('log("Loaded v" .. SCRIPT_VERSION .. ". Region "',
                  'log("Loaded v" .. SCRIPT_VERSION .. " (EN build). Region "')

io.open(DST if False else "obs-fx-en/mouse-fx.lua", "w", encoding="utf-8").write(src)

# ---------------------------------------------------------------- verify
cjk = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
left = [(n, l) for n, l in enumerate(src.split("\n"), 1) if cjk.search(l)]
print("lines before/after:", before, len(src.split("\n")))
print("literals replaced:", len(applied), "/", len(LIT))
print("comments replaced:", len(COM), "->", sum(1 for k in COM))
print("header lines:", len(HEAD))
print("remaining CJK lines:", len(left))
for n, l in left[:20]:
    print("  ", n, l[:120])

# ---------------------------------------------------------------- package
# One rule, no hand-typed numbers: both archives carry the SAME version, and the
# only difference between the two filenames is the "-en" token. Whatever
# SCRIPT_VERSION says in obs-fx/mouse-fx.lua decides both names.
import zipfile, os

def version_of(text, path):
    m = re.search(r'SCRIPT_VERSION\s*=\s*"([^"]+)"', text)
    if not m:
        raise SystemExit("no SCRIPT_VERSION in " + path)
    return m.group(1)

v_zh = version_of(io.open("obs-fx/mouse-fx.lua", encoding="utf-8").read(), "obs-fx/mouse-fx.lua")
v_en = version_of(src, "obs-fx-en/mouse-fx.lua")
if v_zh != v_en:
    raise SystemExit("version mismatch: zh=%s en=%s - the English build must keep the same "
                     "version as the Chinese source; the filename is the only difference." % (v_zh, v_en))

PACKS = [
    ("obs-fx",    "build/obs-mouse-fx-v%s.zip"    % v_zh,
     ["mouse-fx.lua", "mouse-fx.effect", "blank.png", "cursor.png", "\u4f7f\u7528\u8bf4\u660e.md"]),
    ("obs-fx-en", "build/obs-mouse-fx-en-v%s.zip" % v_en,
     ["mouse-fx.lua", "mouse-fx.effect", "blank.png", "cursor.png", "README.md", "LICENSE"]),
]
os.makedirs("build", exist_ok=True)
for folder, out, files in PACKS:
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files:
            z.write(os.path.join(folder, f), arcname=folder + "/" + f)
    print("packaged:", out, os.path.getsize(out), "bytes")

