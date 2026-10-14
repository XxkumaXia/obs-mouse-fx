[English](README.md) | 简体中文

# OBS Mouse Highlight Overlay (Mouse FX) / OBS 鼠标高亮叠加

<p align="center">
  <img src="docs/hero-highlight.png" width="420" alt="mouse highlight">
</p>

An **OBS built-in Lua script** that draws a mouse highlight circle, click ripples and a motion
trail directly onto your canvas — and renders the system cursor **on top of everything**.
Perfect for tutorials, demos and screencasts.

一个 **OBS 内置 Lua 脚本**：直接在画面里画出鼠标高亮圈、点击波纹、移动拖影，
并把系统光标画在最上层——教程 / 演示录屏神器。

## Features

- **Persistent highlight circle** — outer ring + translucent fill, both individually toggleable
  (default: yellow ring + soft fill)
- **Click ripples** — left / right / middle buttons can have different colors; 1–3 expanding rings
- **Optional motion trail** — fading afterimages that follow the cursor
- **Self-drawn cursor** (the core feature) — the script grabs the current Windows cursor bitmap
  (including hotspot) in real time and paints it on the **topmost layer**, so the highlight circle
  always sits *under* the cursor instead of tinting it:
  - Switching cursor themes / shapes (arrow ↔ text ↔ hand) is picked up **automatically**
  - Animated `.ani` cursors are sampled into 5 frames and looped
  - Graceful fallback if grabbing fails: bundled arrow sprite → built-in SDF arrow
- **Works with custom cursor themes** — any theme you use on Windows is what gets drawn:

  <p align="center"><img src="docs/effect-custom-cursor.png" width="300" alt="custom cursor theme"></p>

- **Multi-monitor aware** — automatically matches the monitor your capture source points at
- **Zoom-follow compatible** — works with
  [obs-zoom-to-mouse](https://github.com/tryptophane/obs-zoom-to-mouse); coordinates are remapped
  every frame so the overlay stays locked while zooming
- **Zero dependencies** — no Python service, no browser source, no background app.
  One Lua script + one effect file.

More effects:

<p align="center">
  <img src="docs/effect-glow.png" width="300" alt="glow effect">
  <img src="docs/effect-cyan.png" width="300" alt="cyan highlight">
</p>

## Installation

1. Download the `obs-fx` folder from this repository
   (`mouse-fx.lua`, `mouse-fx.effect` and `blank.png` **must stay together in one directory**)
2. OBS menu → **Tools → Scripts** → click **+** → pick `obs-fx/mouse-fx.lua`
3. Every parameter applies instantly, no restart needed

> Prefer a path without non-ASCII characters (some OBS builds fail to load scripts
> from such paths).

## Usage

### A. As a filter on your capture source (recommended)

Right-click your **Display Capture / Window Capture / Game Capture** → **Filters** → **+** →
**Mouse Highlight Overlay (Mouse FX)**.
The filter detects which monitor it is attached to and converts coordinates automatically —
multi-monitor setups need no manual config.

### B. As a standalone overlay source

Add source **Mouse Highlight Layer (Mouse FX)** and drag it to the top.
A standalone layer has no idea which monitor you are recording, so in the script panel choose
**Region → Specify monitor** and set **Layer width/height** to that monitor's resolution:

<p align="center"><img src="docs/panel-region.png" width="480" alt="region settings"></p>

### Why the circle stays *under* the cursor

OBS's display capture bakes the system cursor **into the captured frame**, while the highlight
overlay sits above the frame — a translucent fill would inevitably smear over the cursor.

The fix: with **Cursor takeover** enabled, the script automatically disables the capture source's
"Capture cursor" option and draws the cursor itself on the topmost layer. The layer order is fixed:

```
trail → glow → click ripples → fill → ring → cursor (always on top)
```

## Parameters

The properties panel is grouped into *Region / Highlight circle / Click ripples / Trail /
Custom cursor / Misc*. Full parameter tables live in
**[obs-fx/使用说明.md](obs-fx/使用说明.md)** (Chinese). Highlights:

| Group | Key options |
|---|---|
| Highlight circle | style, radius, ring thickness, color, opacity, glow |
| Click ripples | duration, radii, ring width, 1–3 rings, per-button colors |
| Trail | count, radius, sampling interval, color |
| Custom cursor | auto-grab system cursor, regrab button, image fallback, hotspot, scale |
| Region | auto / primary monitor / virtual desktop / custom / specify monitor |
| Misc | smoothing, zoom-follow source, debug logging |

<p align="center">
  <img src="docs/panel-highlight.png" width="420" alt="highlight settings">
  <img src="docs/panel-ripple.png" width="420" alt="ripple settings">
</p>

<p align="center">
  <img src="docs/panel-trail.png" width="420" alt="trail settings">
  <img src="docs/panel-cursor.png" width="420" alt="cursor settings">
</p>

## Troubleshooting

Enable **Debug logging**, reload the script, then check the OBS log file
(Help → Log Files) for lines starting with `[鼠标高亮]` — a healthy load shows
`首帧渲染完成` (first frame rendered).

| Symptom | Fix |
|---|---|
| Circle offset from the real cursor | Check the "mapped region" log line; if wrong, switch Region to **Custom** and enter the monitor's origin + resolution |
| Standalone layer misaligned | Region → **Specify monitor**, and set Layer width/height to that monitor's resolution |
| Two cursors on screen | Make sure both **Self-drawn cursor** and **Cursor takeover** are enabled |
| Cursor theme change not picked up | Click the **Regrab cursor** button |
| Nothing shows up | Verify the three files are in the same directory, the filter is enabled, and the log shows "first frame rendered" |

The full troubleshooting table (Chinese) is in
[obs-fx/使用说明.md](obs-fx/使用说明.md#五排障).

## Development

See **[DEVELOPMENT.md](DEVELOPMENT.md)** for the architecture breakdown, key code index and the
history of hard-won fixes, plus the debug scripts in `dev-archive/`
(cursor parsing, 1bpp mask verification, FFI auditing, PNG regenerating).

## Platform

**Windows only** (cursor position and bitmap come from the Win32 API).
Tested with OBS Studio 28+ (LuaJIT + libobs graphics API).

## License

[MIT](LICENSE). The bundled `cursor.png` is a neutral arrow generated by
`dev-archive/make_cursor_png.py` — no third-party copyright attached.
