# dev-archive（开发归档）

本目录是 `obs-fx` 鼠标高亮插件的**开发期过程文件**，**不是运行时交付物**，OBS 不需要它们，日常使用/改代码也不用碰。

## 内容
- `make_cursor_png.py` — 纯标准库绘制 `obs-fx/cursor.png`（32×32 中性箭头，白填充+黑描边，内置 PNG 编码器）。想换光标兜底图的样式就改它再重新生成。
- `ani_parse.py` — 从 `.ani/.cur` 正确解光标 RGBA 帧（处理 AND 掩码，不留白边）。想用自己的光标主题做兜底图时用它解帧。
- `grab_pixels.py` / `grab_test.py` / `verify_fix.py` — 复刻并验证光标像素读取、1bpp 掩码修复（黑块成因）。
- `audit_calls.py` / `pe_exports.py` — 审计 FFI 调用是否真有对应 DLL 导出。
- `check.py` — Lua 语法检查（依赖 `lupa`）。
- `*.png`（`bandicam_*`、`highlight*_view`、`current_*`、`desired_*`）— 开发期效果对照截图 / 预览图。

## 什么时候会用到
- 要**换/重生成 `cursor.png`** 时：改样式 → `make_cursor_png.py`；用自己的主题 → `ani_parse.py` 解帧后横向平铺。
- 要**复现或验证光标黑块修复**时，参考 `verify_fix.py` / `grab_test.py`。
- 要**审计 FFI 调用**时，参考 `audit_calls.py`。
- 改完 Lua 后做**语法检查**：`python check.py`。

> 历史说明：早期自带的 `cursor.png` 解自某第三方光标主题，为规避版权问题，
> 开源版已替换为 `make_cursor_png.py` 生成的中性箭头，相关第三方衍生图已移除。

> 主项目说明见上层 `DEVELOPMENT.md`。
