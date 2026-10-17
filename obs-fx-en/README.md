# Mouse FX — English build

OBS Lua script that draws a mouse highlight ring, click ripples and a motion trail on your
canvas, and paints the **real system cursor on the topmost layer** so the ring can never tint,
blur or hide it.

This is the same script as the Chinese build (`obs-fx/`), with every panel label, log message and
code comment in English. Internal source ids and settings keys are unchanged, so it is a drop-in
replacement: existing filters, layers and their settings carry over untouched.

---

## Files

| File | Required | Notes |
|---|---|---|
| `mouse-fx.lua` | yes | The script. Load it from Tools → Scripts |
| `mouse-fx.effect` | yes | Shader. Must sit next to the `.lua` |
| `blank.png` | yes | 1×1 transparent carrier texture used by the shader |
| `cursor.png` | no | Fallback sprite used if the live cursor grab ever fails |

All four **must stay in the same folder**. Keep the path ASCII-only (e.g. `D:\obs-fx-en`) — some
OBS builds refuse to load scripts from paths with non-ASCII characters.

---

## Install

1. OBS Studio → **Tools → Scripts**
2. Click **+** at the bottom left, select `mouse-fx.lua`, **Open**
3. The properties panel appears on the right. Changes apply instantly — no restart, no reload

OBS remembers added scripts and loads them on the next launch. To update, overwrite the files and
click **Reload Scripts** (the circular arrow) at the bottom of the Scripts window.

**Load one build at a time.** The Chinese and English builds register the same source ids, so
having both in the script list at once is a conflict. Switching is safe — settings are keyed
identically and survive the swap.

---

## Usage — pick exactly one

### A. Filter on a capture source (recommended)

Right-click a **Display / Window / Game Capture** source → **Filters** → **+** under *Effect
Filters* → **Mouse Highlight Overlay (Mouse FX)**.

The filter detects which monitor the source is on and converts coordinates itself. Nothing to
configure, including on multi-monitor setups.

### B. Standalone overlay layer

**Sources → + → Mouse Highlight Layer (Mouse FX)**, dragged to the top of the scene.

Set **Zoom link source** (or **Capture source name**) and the layer finds that source by name,
reads which monitor it captures, and follows its region and size — switching monitors needs no
reconfiguration and re-syncs within about two seconds. You can also pin it by hand: **Region →
Specific monitor**, then set **Layer width / height** to that monitor's resolution.

### With obs-zoom-to-mouse

- Filter version goes **below** the zoom crop filter — it then gets cropped and scaled with the
  frame and stays aligned for free
- Standalone version goes on top with **Zoom link source** pointed at the zoomed source; it
  remaps to the crop rect every frame
- Never both usages at once, and never a filter on the standalone layer — that draws the effect
  twice (the "two circles, one big one small, washed-out colors" bug)
- Leave **Capture cursor** unchecked on the capture source; cursor takeover turns it off for you

---

## Parameters

| Group | Options |
|---|---|
| Region | Auto / primary monitor / virtual desktop / custom values / specific monitor; global offset X/Y; scale correction |
| Highlight ring | Style (ring + fill / ring only / fill only), radius, ring thickness, color, ring opacity, fill strength, circle center offset, glow on/off, glow radius, glow strength |
| Click ripples | On/off, ring duration, start/end radius, ring width, ring count (1–3), delay between rings, fill strength, overall opacity, per-button colors |
| Motion trail | On/off, count, dot radius, sample interval, color, opacity |
| Self-drawn cursor | On/off, auto read, regrab button, image path, frame count, fps, hotspot X/Y, scale, cursor takeover, capture source name, built-in arrow colors |
| Misc | Smoothing, layer width/height, output log |

Layer order is fixed and not configurable:

```
trail → glow → click ripples → fill → ring → cursor
```

---

## Troubleshooting

Turn on **Output log**, reload the script, then open **Help → Log Files** and look for lines
starting with `[Mouse FX]`. A healthy load prints:

```
[Mouse FX] Loaded v1.1.1 (EN build). Region ...
[Mouse FX] First frame rendered (1920x1080)
```

| Symptom | Fix |
|---|---|
| Ring offset from the cursor | Check the "mapped region" log line; if it's wrong, set Region to **Custom** and enter the monitor origin and resolution |
| Standalone layer misaligned | Set **Zoom link source** to the capture source you're recording and Region to **Auto** |
| Two cursors on screen | Both **Self-drawn cursor** and **Cursor takeover** must be on. Turn on **Output log** and reload — the log names the exact reason |
| Cursor theme change ignored | Click **Regrab cursor** |
| Nothing renders | Three required files in one folder, filter enabled, and "First frame rendered" in the log |
| `effect failed to load` | `mouse-fx.effect` is missing or in a different folder from the `.lua` |

---

## Compatibility

- **Windows only** — cursor position and bitmap come from the Win32 API via LuaJIT `ffi`
- **OBS Studio 28+**, tested against 30.x
- A script, not a compiled plugin: no installer, no admin rights, nothing to whitelist

## Build

Version **1.1.1** — the same number as the Chinese build in `obs-fx/`. This isn't a separate
release: same source, same filter/source ids, same settings keys, only the panel strings, log
messages and comments are English. The version is copied out of `obs-fx/mouse-fx.lua` at build
time and never typed by hand — the build script aborts if the two numbers ever drift apart, so
the only visible difference between the two archives is the name:

```
build/obs-mouse-fx-v1.1.1.zip        Chinese
build/obs-mouse-fx-en-v1.1.1.zip     English   <- same version, "-en" is the whole story
```

Regenerate after editing the Chinese source, from the repository root:

```
python dev-archive/build_en_lua.py
```

The translator is a line-for-line string/comment map — code structure is never touched, which is
why the English build stays byte-comparable to the Chinese one outside of strings and comments.

## License

MIT. The bundled `cursor.png` is a neutral arrow generated by `dev-archive/make_cursor_png.py` —
no third-party cursor artwork is redistributed.
