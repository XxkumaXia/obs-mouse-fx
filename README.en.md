[简体中文](README.md) | English

# OBS Mouse Highlight Overlay (Mouse FX)

<p align="center">
  <img src="docs/hero-highlight.png" width="420" alt="mouse highlight">
</p>

An **OBS built-in Lua script** that draws a mouse highlight circle, click ripples and a motion
trail directly onto your canvas — and renders the system cursor **on top of everything**.
Built for tutorials, demos and screencasts.

## Features

- **Persistent highlight circle** — an outer ring plus a translucent fill, each individually
  toggleable (default: yellow ring with soft fill). Radius, thickness, colors and glow are adjustable
- **Click ripples** — expanding rings on click, with a separate color per mouse button
  (left / right / middle) and support for 1–3 stacked rings
- **Optional motion trail** — fading afterimages that follow the cursor
- **Self-drawn system cursor** (the core feature) — the script grabs the current Windows cursor
  bitmap (hotspot included) in real time and paints it on the **topmost layer**, so the highlight
  circle always sits *under* the cursor instead of tinting or covering it:
  - Switching cursor themes or shapes (arrow ↔ text ↔ hand) is picked up **automatically**
  - Animated `.ani` cursors are sampled into 5 frames and looped
  - If grabbing ever fails it falls back gracefully: bundled arrow sprite → built-in SDF arrow,
    so you never end up with no cursor at all
- **Works with any custom cursor theme** — whatever theme Windows is using is what gets drawn:

  <p align="center"><img src="docs/effect-custom-cursor.png" width="300" alt="custom cursor theme"></p>

- **Multi-monitor aware** — automatically matches the monitor that your capture source points at,
  so coordinates stay correct across displays
- **Zoom-follow compatible** — pairs with
  [obs-zoom-to-mouse](https://github.com/tryptophane/obs-zoom-to-mouse): coordinates are remapped
  every frame, keeping the overlay locked while zooming
- **Zero dependencies** — no Python service, no browser source, no background process.
  One Lua script plus one effect file

More effects:

<p align="center">
  <img src="docs/effect-glow.png" width="300" alt="glow effect">
  <img src="docs/effect-cyan.png" width="300" alt="cyan highlight">
</p>

## Installation

### 1. Get the files

Download `obs-mouse-fx-v1.0.0.zip` from the
[Releases page](https://github.com/XxkumaXia/obs-mouse-fx/releases) and extract it
(or clone this repository and use the `obs-fx` folder).

> Keep `mouse-fx.lua`, `mouse-fx.effect` and `blank.png` **in the same folder** — OBS fails to
> load the script if they are separated. Prefer a folder path without non-ASCII characters
> (e.g. `D:\obs-fx`), since some OBS builds cannot load scripts from such paths.

### 2. Load it in OBS

1. Open OBS Studio → menu **Tools → Scripts** (`工具 → 脚本`)
2. In the Scripts window, click the **+** button at the bottom left
3. Browse to the extracted folder and select **`mouse-fx.lua`** → **Open**
4. `mouse-fx.lua` now appears in the script list on the left, and its property panel appears on
   the right. Every parameter applies **instantly** — no restart required
5. OBS remembers added scripts, so it is loaded automatically on the next launch

<p align="center"><img src="docs/panel-region.png" width="480" alt="script properties panel"></p>

### 3. Add it to your scene

Either of the two usages below — see [Usage](#usage).

### Updating

Overwrite the old files with the new ones, then click the **Reload Scripts** (circular arrow)
button at the bottom of the Scripts window. OBS loads the copy at the path you selected, so if
you move the folder you need to remove and re-add the script.

## Usage

### A. As a filter on a capture source (recommended)

Right-click your **Display Capture / Window Capture / Game Capture** source → **Filters** →
**+** (Effect Filters) → **Mouse Highlight Overlay (Mouse FX)**.
The filter detects which monitor it is attached to and converts coordinates automatically —
multi-monitor setups need no manual configuration.

### B. As a standalone overlay source

Scene → Sources **+** → **Mouse Highlight Layer (Mouse FX)**, then drag it to the top of the list.
A standalone layer cannot tell which monitor you are recording, so in the script panel set
**Region → Specify monitor** and set **Layer width / height** to that monitor's resolution:

<p align="center"><img src="docs/panel-region.png" width="480" alt="region settings"></p>

Optional: when using [obs-zoom-to-mouse](https://github.com/tryptophane/obs-zoom-to-mouse) with
the standalone layer, pick the zoomed capture source in the **Zoom-follow source** dropdown and
the overlay remaps itself to the zoom crop every frame.

### Why the circle stays *under* the cursor

OBS's display capture bakes the system cursor **into the captured frame**, while the highlight
overlay sits above that frame — a translucent fill would inevitably smear over the cursor.

The fix: with **Cursor takeover** enabled, the script automatically turns off the capture source's
"Capture cursor" option and draws the cursor itself on the topmost layer. The layer order is fixed:

```
trail → glow → click ripples → fill → ring → cursor (always on top)
```

## Parameters

The properties panel is grouped into *Region / Highlight circle / Click ripples / Trail /
Custom cursor / Misc*. Overview:

| Group | Key options |
|---|---|
| Highlight circle | style, radius, ring thickness, color, opacity, glow |
| Click ripples | duration, start/end radius, ring width, 1–3 rings, per-button colors |
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

The complete parameter reference (Chinese) lives in
**[obs-fx/使用说明.md](obs-fx/使用说明.md)**.

## Troubleshooting

Enable **Debug logging**, reload the script, then open the OBS log
(Help → Log Files) and look for lines starting with `[鼠标高亮]` — a healthy load prints
`首帧渲染完成` ("first frame rendered").

| Symptom | Fix |
|---|---|
| Circle offset from the real cursor | Check the "mapped region" log line; if it is wrong, switch Region to **Custom** and enter the monitor origin + resolution |
| Standalone layer misaligned | Region → **Specify monitor**, and set Layer width/height to that monitor's resolution |
| Two cursors on screen | Make sure both **Self-drawn cursor** and **Cursor takeover** are enabled |
| Cursor theme change not picked up | Click the **Regrab cursor** button |
| Nothing shows up at all | Verify the three files share one folder, the filter is enabled, and the log shows "first frame rendered" |

The full troubleshooting table (Chinese) is in
[obs-fx/使用说明.md](obs-fx/使用说明.md#五排障).

## Development

See **[DEVELOPMENT.md](DEVELOPMENT.md)** for the architecture breakdown, a key-code index and the
history of hard-won fixes, plus the debug scripts under `dev-archive/`
(cursor parsing, 1bpp mask verification, FFI auditing, cursor sprite regeneration).

## Platform

**Windows only** — cursor position and bitmap both come from the Win32 API (LuaJIT `ffi`).
Tested on OBS Studio 28+ (LuaJIT + libobs graphics API).

## License

[MIT](LICENSE). The bundled `cursor.png` is a neutral arrow generated by
`dev-archive/make_cursor_png.py` — no third-party copyright attached.
