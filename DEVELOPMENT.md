# DEVELOPMENT.md — 开发者文档（mouse-fx）

> 面向**要改这套代码的开发者**写的。看这份就够了。
> 用户视角使用文档在 `obs-fx/使用说明.md`，两边内容不重复：那份讲"怎么用"，这份讲"怎么改"。

---

## 0. 一句话定位

一个 **OBS 内置 Lua 脚本**（`obs-fx/mouse-fx.lua`），装上后在画面上画出：
**常驻高亮圈（外环+填充）+ 点击波纹 + 移动拖影 + 自绘系统光标**。
坐标用 LuaJIT 的 `ffi` 直接调 Win32 API 实时读取，**不需要** Python 服务 / 浏览器源 / 任何后台程序。

早期"Python 服务 + 浏览器源"那套方案已废弃删除，现在只有这一版。

---

## 1. 文件清单（哪些要紧）

```
obs-mouse-fx/
├── README.md              ← GitHub 首页（用户向，简版）
├── DEVELOPMENT.md         ← 你正在看的这份（开发者向）
├── LICENSE                ← MIT
├── obs-fx/                ← 【运行时交付物】OBS 直接加载这一整个目录
│   ├── mouse-fx.lua        ★ 脚本主体（FFI 读鼠标 + 抓系统光标 + 滤镜/源注册 + 参数面板），改代码主要动这里
│   ├── mouse-fx.effect     ★ 着色器（画圈 / 波纹 / 拖影 / 光标图），绘制逻辑全在这里
│   ├── blank.png           ★ 4×4 透明载体图，绘制用，【别删】，三个文件必须同目录
│   ├── cursor.png          ★ 光标图（32×32 中性箭头，自制无版权问题）；自动读取失败时的兜底
│   └── 使用说明.md         ← 用户向使用文档（参数表 / 排障表）
└── dev-archive/           ← 开发期产物 / 过程文件，【非运行时必需】，仅供溯源（见 §7）
```

**铁律**：`mouse-fx.lua` / `mouse-fx.effect` / `blank.png` 必须放在同一目录，拆开就加载失败。

---

## 2. 它是怎么工作的（原理）

### 2.1 两种用法
- **用法 A：滤镜版（推荐）** — 给"显示器采集 / 窗口采集 / 游戏采集"加滤镜 `鼠标高亮叠加 (Mouse FX)`。
  滤镜能读到自己挂在哪块屏上，自动换算坐标（多屏不用管）。
- **用法 B：独立源** — 场景里新增来源 `鼠标高亮层 (Mouse FX)`，拖到最上层。
  独立图层**读不到**挂在哪块屏，必须手动在面板"坐标区域 → 指定显示器"里选你录的那块屏，
  并把"独立源 宽/高"设成该屏分辨率，否则只认主屏、位置对不上。

注册名（改显示名/匹配逻辑时搜这两个 id）：
- 滤镜：`filter_def.id = "mouse_fx_filter"` → 显示名 `鼠标高亮叠加 (Mouse FX)`（lua 约 1560 行）
- 独立源：`source_def.id = "mouse_fx_source"` → 显示名 `鼠标高亮层 (Mouse FX)`（lua 约 1596 行）

### 2.2 鼠标坐标获取（FFI Win32）
`mouse-fx.lua` 头部 `ffi.cdef` 声明了 `GetCursorPos / GetAsyncKeyState / EnumDisplayMonitors /
GetMonitorInfoA / EnumDisplayDevicesA / GetSystemMetrics / GetTickCount64`，
`ffi.load("user32")`、`ffi.load("kernel32")`。**没有 ffi 就直接 return 不加载**（lua 47 行附近）。

### 2.3 多显示器坐标映射（最容易出错的地方）
- `enum_monitors()`（lua 103 行）：用 `EnumDisplayDevicesA(EDD_GET_DEVICE_INTERFACE_NAME)` 取每块屏的
  `DeviceID`（形如 `\\?\DISPLAY#型号#...#{guid}`），同时拿到 `rcMonitor` 左上角与宽高。
- OBS"显示器采集"源里存的 `monitor_id` **等于** 本机 `EnumDisplayDevicesA` 的 `DeviceID`（同串）。
  `find_monitor()`（lua 137 行）做双向子串匹配，把"采集源 → 物理屏"对应上。
- 独立源没有挂载目标，`obs_filter_get_target` 返回 nil，所以面板才有"指定显示器"下拉
  （`region_mode` 选项 4），由用户手动指定。`get_region()`（lua 375 行）是坐标换算总入口。

### 2.4 自绘光标（本插件的核心设计，重点坑）
OBS"显示器采集"勾"捕获光标"时，会把系统光标**烤进采集画面**。高亮圈是叠在画面之上的图层，
物理上钻不进画面，于是半透明填充会糊在光标上（看起来"圈盖住光标"）。

解法：关掉采集源的"捕获光标"，改由脚本**自己把当前系统光标画到最上层**。
图层顺序（下→上，固定）：
```
拖影 → 柔光 → 点击波纹 → 内部填充 → 外环 → 光标（永远在最上）
```
相关逻辑：
- `grab_cursor()`（lua 648 行）：向 Windows 要当前光标位图（含热点），**动画光标启动时连采 5 帧循环**。
  抓到的位图临时写成 PNG 到 `%TEMP%\mousefx_cur_*.png`，载入显存后**立即删除**，不遗留垃圾。
- **1bpp 掩码坑（已修）**：光标掩码是 1bpp 位图，早年用 32bpp 读 → 全 0 → 每个像素算不透明
  → 光标被画成一整块黑。现在按 1bpp 正确解析（`dev-archive/verify_fix.py`、`grab_test.py` 即验证此修复）。
- `cur_use_img`：自动读取失败/关闭时，改用 `cursor.png` 画光标（32×32 中性箭头，见 `make_cursor_png.py`）。
- `cur_on=0` 且都失败 → 画内置箭头（`effect` 里的 `arrowSDF`），填充/描边色可调。
- "重新抓取光标"按钮：`REGRAB` 计数器（lua 30 行）+ `cursor_update()`（lua 952 行）清空重采。
  因为 Windows 偶尔把旧光标**回收成同一句柄**再给新光标，光比句柄看不出变化，留了手动开关。

### 2.5 颜色字节序（必踩的坑，已修）
OBS `obs_properties_add_color` 返回的是 **`0xAABBGGRR`（低字节是 R）**，不是 `0xAARRGGBB`。
旧代码按 RRGGBB 解 → 红↔蓝互换。修复：`argb()`（lua 289 行）按"低字节=R"解；
新增 `rgb2int(r,g,b,a)`（lua 299 行）生成默认色，**禁止再手写颜色字面量**。改颜色相关代码务必走这两个函数。

### 2.6 与 obs-zoom-to-mouse 的联动
独立源（用法 B）不吃 zoom 脚本对采集源做的"裁剪+拉伸"放大，直接叠会错位。
解决：面板"联动缩放源"下拉（坐标区域分组下）选中被缩放的采集源，
`follow_find_crop_name()`（lua 189 行）/ `follow_crop()`（lua 233 行）每帧读 zoom 脚本那枚
裁剪滤镜 `obs-zoom-to-mouse-crop` 的当前裁剪框，把光标坐标按"减裁剪框 → 乘拉伸倍率"重映射，
高亮圈和柔光也同步乘放大倍率。滤镜版（用法 A）加在裁剪滤镜下方，天然被一起放大，不需要这项。

---

## 3. 关键代码索引（改哪改什么）

| 想改的东西 | 去哪看 | 备注 |
|---|---|---|
| 参数默认值 | `script_defaults()`（lua 406）+ 顶部 `S = {}`（lua 25 行） | `S` 必须在所有引用它的函数之前声明（local 可见性坑，踩过两次） |
| 颜色（读/写） | `argb()` 289 / `rgb2int()` 299 | 严守 AABBGGRR 字节序 |
| 显示器枚举/匹配 | `enum_monitors()` 103 / `find_monitor()` 137 | DeviceID 双向匹配 |
| 坐标换算总入口 | `get_region()` 375 / `detect_source_region()` 160 | 独立源/滤镜分流在这里 |
| 抓取系统光标 | `grab_cursor()` 648 / `cursor_update()` 952 / `cursor_load_png()` 890 | 1bpp 掩码在这里 |
| 每帧状态/坐标 | `update_state()` 1261 | 鼠标、点击、光标采样都在这里 |
| 渲染（传 uniform 给 effect） | `render_data()` 1425 | 把状态塞进 effect 的 uniform |
| 绘制（圈/波纹/拖影/光标） | `mouse-fx.effect` 的 `PSMouse`（effect 181 行） | 数学/遮罩全在 effect |
| 参数面板布局 | `script_properties()` 1640 | 分组、下拉、按钮都在这 |
| 注册滤镜/源 | `script_load()` 1796 | `obs_register_source(filter_def/source_def)` |

---

## 4. 部署 & 生效（⚠️ 最重要，务必看）

**OBS 加载的是你添加脚本时所选路径的那份文件**——改了仓库源码后，OBS 不会自动同步。

两种常用做法：
1. 直接把整个 `obs-fx/` 拷到你日常存放脚本的目录（建议纯英文路径），覆盖旧文件，
   然后在 OBS「工具 → 脚本」里选中 `mouse-fx.lua` 点一下"重新加载"；
2. 或者先在脚本列表里移除，再重新添加仓库里的 `mouse-fx.lua`。
（OBS 菜单 工具→脚本 里看到的路径能确认当前加载的是哪个。）

加载步骤（用户向，详见 `obs-fx/使用说明.md`）：工具→脚本→+ 选 `mouse-fx.lua`；
然后给采集源加滤镜，或场景里加"鼠标高亮层"。

排障先看 OBS 日志（帮助→日志文件）：正常应有 `[鼠标高亮] 首帧渲染完成`。
"输出日志"开关默认关（不刷屏），排障时再开。

---

## 5. 已知坑 / 历史修复（都是真机踩出来的）

1. **颜色红蓝反** → `argb()`/`rgb2int()` 已修（见 2.5）。
2. **光标黑块** → 1bpp 掩码按 32bpp 读导致，已修（见 2.4）。
3. **独立源只认主屏** → 独立源无挂载目标，`get_region` 读不到屏；新增"指定显示器"下拉修。
4. **OBS 异常关闭/安全模式弹窗** → 早版本跨帧持有采集源引用导致崩溃，已修（不再跨帧持有）。
5. **`S` 表位置** → local 只从声明处可见，函数若定义在 `S` 之前会把 `S` 当全局 → 运行时 nil 崩。务必保持 `S` 在文件开头。
6. **日志刷屏** → 只有"配置性错误"（effect/贴图加载失败）才无条件打；鼠标/光标这类有兜底的信息一律跟"输出日志"开关走。

---

## 6. 测试 / 验证方法

- 语法：`dev-archive/check.py`（用 `lupa` 跑 Lua 语法检查）。
- 光标掩码修复验证：`dev-archive/verify_fix.py`、`grab_test.py`（Python 复刻 `grab_cursor` 逻辑，验证 1bpp 掩码与黑块成因）。
- FFI 调用审计：`dev-archive/audit_calls.py`（比对 DLL 导出表，确认每个 ffi.cdef 都真实存在）。
- 真机：开 OBS 加载 → 日志应有 `首帧渲染完成`；移动鼠标看高亮圈跟随；点击看波纹；换光标主题看是否自动跟上（不行点"重新抓取光标"）。

---

## 7. dev-archive/ 是什么（非运行时，仅供溯源）

开发/调试期的**过程文件**，不是交付物，OBS 不需要它们：
- `make_cursor_png.py`：纯标准库绘制 `cursor.png`（32×32 中性箭头，白填充+黑描边，含 PNG 编码器），可重新生成或改样式。
- `ani_parse.py`：从 `.ani/.cur` 正确解出光标 RGBA 帧（处理 AND 掩码，不留白边）——想换成自己的光标主题时用它解帧。
- `grab_pixels.py` / `grab_test.py` / `verify_fix.py`：复刻并验证光标像素读取 / 1bpp 掩码修复。
- `audit_calls.py` / `pe_exports.py`：审计 FFI 调用是否真有对应 DLL 导出。
- `check.py`：Lua 语法检查（依赖 `lupa`）。
- `*.png`（`bandicam_*`、`highlight*_view`、`current_*`、`desired_*`）：
  开发期的效果对照图 / 预览图，用于肉眼比对效果与验证修复。

> 历史说明：早期仓库自带的 `cursor.png` 解自某第三方光标主题，为规避版权问题，
> 开源版替换为 `make_cursor_png.py` 生成的中性箭头，相关第三方衍生图已移除。
