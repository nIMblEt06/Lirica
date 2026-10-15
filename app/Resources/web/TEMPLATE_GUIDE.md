# Spotify Wallpaper template guide

Don't want to write code? Use **Template Builder…** in the menu: it makes templates visually, and its **Edit Code**
button turns any design into an HTML template you can keep editing here.

A template is a folder with two files:

```
my-template/
  manifest.json   name, description, category and the settings shown in Spotify Wallpaper's inspector
  index.html      the wallpaper: plain HTML + CSS (+ optional JS)
```

Put it in this folder (`~/Library/Application Support/Spotify Wallpaper/Templates`). The easiest start is
**Open Spotify Wallpaper → pick a template → ⋯ → Duplicate & edit code**. While a custom template is being edited, the preview and
the wallpaper reload every time you save.

Each template runs in two ways:

- **Live layer**: while a song plays, the page runs as an animated layer just above your wallpaper (below the
  desktop icons) on every Space and screen. It keeps its own playback clock, so lines change exactly on their
  timestamps, and CSS transitions/animations play. `<html>` has the class `sw-live` in this mode.
- **Still**: on each track change the page is also captured as the real wallpaper (lock screen, Mission Control,
  when the app isn't running). Transitions are off for stills, so scope animations under `.sw-live`.

Use `vmin`/`vw`/`vh` units so it adapts to both laptop and ultrawide screens.

## Boilerplate

```html
<!doctype html>
<html><head>
<meta charset="utf-8">
<link rel="stylesheet" href="/runtime/runtime.css">
<script src="/runtime/runtime.js"></script>
<style> body { background: var(--dark); color: #fff; } </style>
</head><body>
  <img data-src="track.cover">
  <h1 data-bind="track.title"></h1>
  <lyrics-block before="1" after="3"></lyrics-block>
</body></html>
```

## Data you can bind

| Path | Meaning |
|---|---|
| `track.title` `track.artist` `track.album` | text |
| `track.cover` | cover image URL |
| `track.duration` `track.position` | seconds |
| `track.progress` | 0–1 |
| `track.elapsed` `track.remaining` `track.length` | `1:23` style text |
| `track.isPlaying` | true / false |
| `lyrics.current` | the line being sung (empty during instrumental gaps) |
| `lyrics.prev1` `lyrics.next1` `lyrics.next2` `lyrics.next3` | neighbouring lines |
| `lyrics.prev[n]` `lyrics.next[n]` | up to 8 either way, e.g. `lyrics.next.4` |
| `lyrics.lines` `lyrics.index` | everything, for custom JS |
| `lyrics.lineProgress` | 0–1 through the current line |
| `lyrics.hasLyrics` `lyrics.synced` `lyrics.isInstrumental` | flags |
| `lyrics.translation` | the current line's translation ("" when there's none) |
| `lyrics.hasTranslation` | true when the song's lyrics come with translations |
| `lyrics.singer` | who sings the current line in a duet: `A`, `B` or `both` ("" otherwise) |
| `lyrics.singers` `lyrics.isDuet` | the duet's names in voice order A, B (empty if it isn't one), and a flag |
| `lyrics.lines[n].translation` `lyrics.lines[n].singer` | the same, per line |
| `track.genre` | the artist's genre, e.g. `Alternative` ("" when unknown) |
| `weather.condition` | `clear`, `clouds`, `rain`, `snow`, `fog` or `storm`; `weather` is missing when the app doesn't know |
| `weather.temp` / `weather.tempC` / `weather.tempF` | `14°` in the unit your region uses / Celsius / Fahrenheit |
| `weather.temperature` `weather.isDay` `weather.sunrise` `weather.sunset` | raw values (°C; times in ms since 1970) |
| `time.dayPhase` | `night`, `dawn`, `day` or `dusk`, from today's sunrise and sunset when known, else the clock |
| `time.sunProgress` | 0–1 from sunrise to sunset (0 before, 1 after) |
| `focus` | true while you share your screen or a Focus is on; lyrics hide (see below) |
| `colors.vibrant` `colors.dominant` `colors.card` `colors.deep` `colors.dark` `colors.light` `colors.muted` `colors.paper` `colors.onDominant` | colors from the cover |
| `colors.palette` | the 6 main cover colors |
| `time.song` / `time.line` | seconds into the song / into the current line |
| `time.clock` / `time.clock24` | `10:42 PM` / `22:42` |
| `time.date` / `time.day` | `Saturday, October 3` / `Saturday` |
| `time.hour` `time.minute` `time.second` | the current time as numbers |
| `params.<key>` | your template's settings |
| `screen.width` `screen.height` `screen.scale` | the screen being drawn |

### Attributes

- `data-bind="track.title"` sets the text. Add pipes: `|upper`, `|lower`, `|note` (empty → `• • •`), `|time`, `|pct`.
- `data-template="Now playing {{track.title}} · {{time.clock}}"` mixes variables into text (pipes work inside `{{ }}`).
- `data-src="track.cover"` sets `src` on an image.
- `data-show="lyrics.hasLyrics"` hides the element when false. Prefix `!` to invert.
- `data-attr-<name>="expr"` sets any attribute, e.g. `data-attr-after="params.linesAfter"`.
- `data-control="playPause"` makes the element control Spotify — see **Playback controls** below.

### CSS variables

`--progress`, `--line-progress`, `--cover-url` (use as `background: var(--cover-url) center/cover`),
`--vibrant` `--dominant` `--card` `--deep` `--dark` `--light` `--muted` `--paper` `--onDominant`,
`--p0` … `--p5` (palette), and `--param-<key>` for every setting.

Time-based variables, updated every frame **only if your CSS uses them** (each costs a style pass per frame):
`--song-time`, `--line-time` (seconds), `--time` (seconds since the page loaded), `--hour`, `--minute`, `--second`.

`data-cover-blur="<px>"` (with optional `data-cover-saturate="1.2"`) on an element gives it the cover, blurred once by
the app, as a background. Use it instead of `filter: blur()` on the cover: it costs nothing per frame.

Classes on `<html>`: `is-playing`, `has-lyrics`, `synced`, `instrumental`, `ultrawide`, and `param-<key>` for every
true bool setting. Plus, for the moment you're in (kept up to date on the live layer):

- `sw-phase-night` / `sw-phase-dawn` / `sw-phase-day` / `sw-phase-dusk`: the time of day
- `sw-weather-<condition>`, e.g. `sw-weather-rain` (only when the weather is known)
- `sw-duet` while the song is a duet
- `sw-focus` while lyrics should stay private: `<lyrics-block>` and anything marked `data-lyrics` fade out by default.
  Use `.sw-focus` to show something else instead, or override the default for a template that has no private text.

Fields the app doesn't send (older versions, the preview, no location access) are simply missing, so treat every one
of them as optional.

**Beat sync.** When beat sync is on, the live layer also gets `--beat`, a pulse that jumps to each beat's strength
(0–1) and fades back to 0 in about half a second, and `--level`, the music's loudness (0–1). Like the time-based
variables they're only updated if your CSS uses them, and they stay 0 in stills and when beat sync is off, so use them
for small touches: `transform: scale(calc(1 + var(--beat) * 0.01))`. In JavaScript, `Wallpaper.on("beat", (b) => …)`
runs on each beat with `{ strength, bpm, last, level }`, and `Wallpaper.beat` always holds the latest values.

## Components

- `<lyrics-block before="2" after="3" layout="flow|top|center" empty="• • •">`
  renders every line as `.line` with `.past` / `.current` / `.next`, plus `--offset` (−2, −1, 0, 1 …) and `--dist`
  (distance from the current line) for fades like `opacity: calc(1 - var(--dist) * .2)`. Instrumental gaps and the
  intro before the first lyric show the `empty` text with a `.gap` class.
  `flow` grows with its lines; `top` and `center` scroll inside a fixed height (give it a height).
  Add `translations` to show each line's translation under it as `<span class="tr">` (smaller and dimmer by default),
  and `duet` to lay a duet out like a conversation: voice A on the left, B on the right, both together centered. Each
  sung line has `data-singer="A|B|both"` for your own styling. Both can be bound to settings:
  `data-attr-translations="params.translations" data-attr-duet="params.duet"` (`"false"` turns them off).
- `<fit-text max-lines="2" min="4vmin" max="15vmin">` shrinks or grows its text to fit its box.
- `<swatch-row count="5" labels>` shows cover colors (`.chip`, `.hex`).
- `<wave-form bars="56">` draws a waveform that changes with every line (`.bar`, uses `currentColor`).
- `<progress-bar>` is a bar filled to `--progress` (`.fill`, uses `currentColor`).
- `<div class="sw-grain">` adds a film-grain overlay.

## Playback controls

Mark an element with `data-control` and it becomes a real, working control for the Spotify app:

```html
<progress-bar data-control="seek" data-show="params.controls"></progress-bar>
<div data-control="previous">‹‹</div>
<div data-control="playPause">⏯</div>
<div data-control="next">››</div>
```

| `data-control` | What it does |
|---|---|
| `playPause` | a click toggles play/pause |
| `next` / `previous` | a click skips a track |
| `seek` | a click or drag across the element seeks to that point in the song |
| `volume` | scrolling over the element (or anything inside it) steps the volume like the volume keys |

On the desktop the live layer sits behind everything and normally gets no clicks at all. The app watches the
pointer and lets the page take a click only while it's over one of these elements — everywhere else your icons,
right-clicks and drags behave as usual, and the app never activates or takes the keyboard. In the preview window
and the template builder the controls are simply clickable.

A few things worth knowing:

- The element's whole box is the target, so give small glyphs a padded wrapper.
- Swap play/pause glyphs with `html.is-playing` (`html:not(.is-playing)` while paused), as Minimal and Glow do.
- Gate them with a bool setting: `data-show="params.controls"`.
- From your own JS, `Wallpaper.control("next")`, `("playPause")`, `("previous")`, `("seek", 0.5)` (0–1 of the
  song), `("volume", 0.4)` (0–1) or `("volumeBy", ±1)` (±100%). Every command also reaches
  `Wallpaper.on("control", ({ command, value }) => { … })`.
- Controls never launch Spotify (the wallpaper isn't on screen unless Spotify is running) and can be switched
  off app-wide under **Wallpaper Controls** in the menu.

## Animation

- Lyric lines get transitions automatically on the live layer: `layout="center"`/`"top"` blocks scroll smoothly,
  and in `flow` blocks the new current line rises in.
- `data-animate` on any element replays a fade/blur-in (`.sw-enter`) every time the line changes.
- Add class `karaoke` to a `<lyrics-block>` to sweep a fill across the current line in time with the song
  (`--karaoke-on` / `--karaoke-off` set the colors). Stills show the whole line lit. Or use `--line-progress` (0–1) in your own CSS.
- `--progress` and `--line-progress` update every frame on the live layer.
- Anything under `.sw-live` can use regular CSS `@keyframes`; e.g. `.sw-live .bg { animation: drift 20s infinite alternate }`.

## Settings (manifest.json)

```json
{
  "name": "My Template",
  "description": "Shown in the gallery and the template's sheet.",
  "category": "calm",
  "params": [
    { "key": "accent", "type": "color", "label": "Accent", "default": "auto:vibrant" },
    { "key": "size", "type": "number", "label": "Lyric size", "min": 2, "max": 8, "step": 0.1, "unit": "vmin", "default": 4 },
    { "key": "lines", "type": "int", "label": "Lines after", "min": 0, "max": 8, "default": 3 },
    { "key": "grain", "type": "bool", "label": "Film grain", "default": true },
    { "key": "font", "type": "font", "label": "Font", "default": "New York" },
    { "key": "align", "type": "select", "label": "Align", "default": "left",
      "options": [{ "value": "left", "label": "Left" }, { "value": "center", "label": "Center" }] },
    { "key": "tagline", "type": "text", "label": "Tagline", "default": "now playing" }
  ]
}
```

`category` files the template in the gallery: `lyrics`, `painting`, `print` (Print & paper), `objects` or `calm`.
Without one it shows under Yours. Color params appear as swatches (the auto colors, the cover's palette and a custom
picker), short selects and bools as segmented controls, numbers as sliders and fonts as a menu; the first few show up
front and the rest under "More settings".

Colors can default to `auto:<name>` (any color name above), so they follow each song's cover. Numbers with a `unit`
become CSS values directly: `font-size: var(--param-size)`.

Fonts: SF Pro, SF Pro Variable (supports `font-stretch: 30%–150%` for compressed and expanded widths),
SF Pro Rounded, SF Mono, New York, Helvetica Neue, Avenir Next, Futura, Gill Sans, Optima, Didot, Bodoni 72,
Baskerville, Georgia, American Typewriter, Courier New, Snell Roundhand, Marker Felt, and the handwriting faces
Bradley Hand, Noteworthy and Chalkboard SE. A `text` param can also hold
any installed font's name.

## Custom JavaScript

```js
Wallpaper.on("render", (ctx) => { /* runs after bindings, before layout. ctx has everything above */ });
Wallpaper.on("layout", (ctx) => { /* runs after fonts/images load and components lay out */ });
Wallpaper.on("line", (ctx) => { /* live layer: a new lyric line just started */ });
Wallpaper.on("tick", (ctx) => { /* live layer: once a second (clocks, counters) */ });
Wallpaper.on("frame", (ctx) => { /* live layer: every frame; only add this if you really need it */ });
Wallpaper.on("track", (ctx) => { /* live layer: a new song started */ });
Wallpaper.on("pause", () => { /* live layer: the desktop got covered; stop everything */ });
Wallpaper.on("resume", () => { /* live layer: the desktop is visible again */ });
Wallpaper.on("beat", (b) => { /* live layer, beat sync on: a beat landed. b = { strength, bpm, last, level } */ });
```

`Wallpaper.live` is true on the animated layer and false while a still is rendered, `Wallpaper.paused` is true while
the desktop is covered, and `Wallpaper.fps` is the app's Refresh Rate setting (0 = display maximum).
`Wallpaper.hold(promise)` makes the current render wait for the promise before layout and the still snapshot, e.g.
while a sketch loads the cover and paints.

### Canvas and p5.js

The runtime ships [p5.js](https://p5js.org) 1.9.4 and a painterly brush, so templates can draw generative art. The
cover is served from the page's own origin, so a canvas can read its pixels.

```html
<script src="/runtime/vendor/p5.min.js"></script>
<script src="/runtime/brush.js"></script>
<script>
  let studio, cover;
  new p5((p) => {
    p.setup = () => { p.createCanvas(innerWidth, innerHeight); studio = Brush.studio(p); };
    p.draw = () => studio.update(p.deltaTime / 1000);
  });
  Wallpaper.on("render", (ctx) => Wallpaper.hold(Brush.cover(ctx.track.cover).then((c) => { cover = c; })));
  Wallpaper.on("line", () => studio.stroke({ x: 200, y: 200, size: 40, color: cover.at(0.5, 0.5), len: 20, field: () => 0.3 }));
</script>
```

- `Brush.studio(p)` returns a painter. `studio.stroke({ x, y, a, size, color, len, step, turn, field, alpha, dry,
  delay, duration, ease })` queues a bristle stroke that paints itself over `duration` seconds with an ease-in-out
  hand (`ease`: `hand`, `inOut`, `out`, `in`, `linear`). `field(x, y)` returns the direction at each step;
  `studio.dab(x, y, size, color)` is a short touch. Call `studio.update(dt)` from `draw`; it is time-based, so the
  pace is the same at any refresh rate. `studio.tempo = 2` halves the speed of everything queued after it.
- `studio.finish()` paints everything queued right away. Use it for stills: they're one frame, so paint the whole
  picture inside a `Wallpaper.hold(...)`.
- `studio.knife({ x, y, a, len, width, color, ridge, delay, duration })` is a sharp, flat palette-knife stroke.
- `studio.mask = (x, y) => bool` keeps strokes out of an area (they lift at its edge; `free: true` strokes ignore it),
  and `studio.clip = { x, y, w, h }` draws everything inside a rectangle.
- `Brush.cover(url, size)` resolves to a sampler of the cover: `at(fx, fy)` → `[r, g, b]`, `box(fx0, fy0, fx1, fy1)` →
  `{ color, dev }` (average and how much detail), `grad(fx, fy)` → the edge direction. `Brush.rgb`, `mix`, `shade`
  help with the palette.
- `/runtime/cover-painter.js` repaints the cover as a knife painting; see the **Painted Cover** templates.
- Stop the loop when `Wallpaper.live` is false or `Wallpaper.paused` is true (`p.noLoop()`), and cap it with
  `p.frameRate(Math.min(Wallpaper.fps || 30, 30))`. The **Brushwork** template is a full example.

### Animating with time

**`data-follow`** maps an element's CSS animation onto time. 0% of the animation is the start and 100% the end of:
`song` (the song; pauses with the music), `line` (the current lyric line; restarts each line), or the real clock:
`seconds` (every minute), `minutes` (every hour), `hours` (every 12 hours), `day`. It runs on the GPU, so it's free.

```html
<div class="second-hand" data-follow="seconds"></div>
<div class="progress-dot" data-follow="song"></div>
<style>
  .second-hand { animation: turn 1s linear both paused; transform-origin: 50% 100%; }
  .progress-dot { animation: across 1s linear both paused; }
  @keyframes turn { to { transform: rotate(360deg); } }
  @keyframes across { from { transform: translateX(0); } to { transform: translateX(80vw); } }
</style>
```

- Loops: plain CSS `@keyframes` under `.sw-live`. Pause them with the music using
  `.sw-live:not(.is-playing) .thing { animation-play-state: paused; }`.
- Follow the song's timeline: give an element a paused animation as long as the song and drive it from the clock:
  `.thing { animation: grow 1s linear paused; animation-delay: calc(var(--song-time) * -1s / var(--length, 200)); }`
  (set `--length` from `ctx.track.duration` in a `render` hook).
- Per line: `data-animate` replays an entrance on every new line; `Wallpaper.on("line")` for anything custom.
- Clock or countdowns: bind `time.clock` / `time.date`, or update in `Wallpaper.on("tick")`.

### Keeping it fast

The live layer is built to cost almost nothing: lines change on a timer set for their exact timestamp, and the
progress bar, karaoke sweep, waveform and CSS animations run on the GPU compositor. To keep it that way:

- Animate `transform` and `opacity`. Avoid animating `width`, `height`, `top`/`left`, `filter`, `background` or
  `box-shadow`; those repaint every frame.
- Don't blur things live (`filter: blur()` on large elements, `backdrop-filter` over moving content); use
  `data-cover-blur` for the cover.
- Avoid `mix-blend-mode` on full-screen layers above moving content.
- Use `tick` (once a second) instead of `frame` whenever you can.
```
