# Changelog

All notable changes to Lirica. Versions follow [semantic versioning](https://semver.org).

## 1.7.3 — 2026-10-16

### Added
- **Choose exactly which music apps Lirica may follow.** Settings now lists Spotify, Apple Music, installed browsers,
  recognized music apps and anything newly detected through macOS Now Playing. Known music apps start on; unknown apps
  start off. Arc, Chrome, Brave, Edge, Vivaldi, Opera and Chromium share one **Chromium browsers** switch.
- **Browser music without an extension.** Lirica can read tabs from Safari, Arc, Chrome and other scriptable Chromium
  browsers, match the Now Playing title and artist to one unambiguous tab, and allow recognized music websites such as
  YouTube Music while rejecting X, ordinary YouTube and unknown sites by default. Browser sites are configurable too.
  Matching stays local; full addresses and tab titles are never saved, and uncertain matches are ignored.

### Fixed
- Spotify durations are now converted from milliseconds correctly, fixing wildly long end times and lyric matches
  rejected as the wrong recording. Lyric caches also retry immediately when corrected track metadata arrives.
- Paused X and other short social-media clips no longer pin the wallpaper after browser playback ends or displace
  music just because **YouTube Music** is the default player.

## 1.7.2 — 2026-10-15

### Changed
- Every release now checks the zip that copies older than 1.7.1 update from — unzipped, identifier matched,
  signature verified — so that path can't break silently while older copies are around.

## 1.7.1 — 2026-10-15

### Changed
- **Releases now ship a disk image.** Open **Lirica-1.7.1.dmg** and drag Lirica into the Applications alias on the
  card. The zip stays beside it for copies of the app that still expect one.

### Fixed
- **Automatic updates work on networks where GitHub's anonymous API is rate-limited.** Shared addresses, VPNs and
  proxies can exhaust the API's budget of 60 requests an hour, and the app used to give up with "The latest release
  doesn't have a downloadable app." It now falls back to the releases page, which has no such limit, and a failed
  check is retried in 15 minutes instead of six hours. Updates install from the disk image, verified the same way.

## 1.7.0 — 2026-10-15

### Changed
- **The app is now Lirica.** Your templates, settings and history stay where they were.
- **Wallpaper controls now live in Settings.** Small transparent hit windows sit over visible controls at Finder's
  desktop-icon level, so they receive normal clicks while every application window remains safely above them.

### Added
- **Control playback from the wallpaper.** Templates can now put real playback controls on your desktop: click
  play/pause and skip, drag a progress bar to seek. In **Classic** the iPod's click wheel works — scroll it for the
  volume, click its edges to skip and its centre to play or pause — and **Minimal**, **Glow** and **Classic** carry
  transports and a seekable progress bar.
- Clicks reach the page only while the pointer is over a control of a template that has them, so icons, right-clicks
  and drags on the rest of the desktop behave exactly as before; the wallpaper never activates and never takes the
  keyboard. Templates choose what to offer with `data-control="playPause | next | previous | seek | volume"` — the
  template guide has the details — and it can be turned off app-wide under **Wallpaper controls** in Settings.
- **Apple Music works too.** The wallpaper follows whichever player is playing, Spotify or Apple Music, and the
  controls go to that one. The first time, macOS asks whether Lirica may control Music.
- **Other music apps:** the wallpaper also follows YouTube Music, browsers and any other app that shows in the Mac's
  Now Playing feed, and the controls work for them too. Settings has a **Default music player**: Lirica follows it when it
  starts playing, and switches to whatever plays after an hour of silence. Clicking controls never switches the player.
  Turn **Other players** off there if you don't want the feed.
- **Click feedback:** a control shrinks and dims while it's held and bounces with a flash when clicked.
- **Three control templates:** **Remote** (a glass remote: scroll the pad for volume, the centre plays and pauses, the
  sides skip), **Jukebox** (an arcade cabinet with coloured buttons, a volume knob and a neon seek bar) and **Island**
  (a floating pill over the blurred cover, with the lyric above it).

### Fixed
- The live wallpaper now stays at the real macOS desktop level. It no longer covers the focused app when playback
  changes or while switching Spaces, and Space changes no longer force the wallpaper window to the front.
- Lirica now tracks each Now Playing app independently, so the selected default wins when Spotify and YouTube Music
  play at the same time. Browser playback follows the **YouTube Music** default instead of being mistaken for
  **Other Apps**, and controls remain scoped to the player shown on the wallpaper.
- Quitting no longer asks for access to Downloads or Pictures when the original wallpaper lives there.

## 1.6.0 — 2026-10-09

### Added
- **Six more templates:** **One Bit** (the cover Atkinson-dithered to two inks, the lyric in a System 7 window that
  redraws the picture top to bottom each line), **Teletext** (Page 888, the cover rebuilt from mosaic blocks in the
  eight teletext colours), **Text Mode** (the cover as coloured ASCII that brightens on the beat, the lyric typed at a
  shell prompt), **Contour Map** (the cover's brightness surveyed as slowly drifting terrain, its summit named after
  the song), **Classic** (an iPod classic showing the song on its Now Playing screen) and **Stained Glass** (the cover
  cut into leaded panes, one lighting up each line, the lyric on a parchment banner).

### Fixed
- Windows no longer go blank: if macOS ends a web page's process (memory pressure, a crash), Home, the Builder, What's
  New, the Quick Switcher and the live wallpaper reload themselves. The off-screen renderers for the wallpaper still no
  longer pile up after display changes.
- Dry brush in Painted Cover is a real dry drag now: dozens of fine bristles that skip and run out unevenly, instead of
  blocky faceted strokes, and the cover underneath is a soft wash instead of a grid of squares that showed between the
  bristles.

## 1.5.0 — 2026-10-07

### Added
- **Lirica has a home.** "Open Lirica…" (⌘O, or open the app again from Finder or the Dock)
  shows your wallpaper live with its settings beside it as colour swatches, segmented controls and sliders, plus a
  shelf of recent and favourite templates. It replaces the Customize window and the menu's Template list.
- **Browse all:** every template in a gallery grouped by feel (Lyrics, Painting, Print & paper, Objects, Calm, Yours),
  with search, thumbnails of the song that's playing, and a record-crate view you flip through with the arrow keys.
- **A template per display:** the Displays tab shows your screens as they're arranged; drop a template onto one to give
  that screen its own wallpaper. It's remembered per display, even after unplugging it.
- **Quick Switcher** (⌃⌥⌘W): a search panel over your desktop to switch templates and run actions (Share Lyric Card,
  Focus Mode, lyrics ±0.5 s, Pause, History Wall). ↩ puts a template on every screen, ⌥↩ on the screen under the pointer.
- The History Wall and the lyrics source and timing controls now live in tabs in the app's window.
- **Settings** (⌘,): a tab in the app's window for everything app-wide (launch at login, frame rate, Focus Mode and
  screen sharing, weather, beat sync, lyric card size, history, templates folder, updates, keyboard shortcuts). The menu
  bar menu now holds only everyday actions.
- The Template Builder and What's New use the same frosted dark look as the app's window.
- **Three new templates:** **Cassette** (a mixtape whose reels wind through the song, with the current line handwritten
  on the label), **Liner Notes** (the CD booklet, with the whole song typeset beside the cover) and **Weather & Time**
  (a sky that follows the time of day and your local weather, with rain running down the glass).
- **Eight more templates:** **Departure Board** (split-flap lyrics under a dot-matrix title), **Riso Print** (the
  cover as two-ink halftone that slips out of register each line), **Swiss Grid** (the lyric set huge on a
  twelve-column grid, words rising one by one), **Hardware Panel** (the cover behind a speaker grille, the lyric on an
  OLED, knobs that turn with the song and a grille that thumps on the beat), **Film Strip** (the cover as 35 mm
  frames advancing a frame per line, under a yellow subtitle), **Albers** (the cover's four strongest colours as
  nested squares that trade places each line), **Breathing Type** (the line's key word swelling with the beat in SF
  Pro's variable width) and **Receipt** (the song printing on a thermal slip, with a total and barcode at the end).
- **Painted Cover comes alive:** the most striking word of each lyric line is lettered into the painting in brush
  strokes, then painted over; before a new cover goes on, the last painting replays as a ~4-second timelapse; fresh
  paint looks wet and dries to matte; a new "Match the genre" stroke style (rock in heavy impasto and knife,
  electronic in crisp horizontal slabs, jazz in warm dry brush, classical and ambient in long soft sweeps); and an
  optional "Keep earlier songs around the edges" mode that builds a collage of the session.
- **Sync to the Beat** (off by default, needs Screen Recording): Spotify's sound is analysed live (nothing is
  recorded) so paintings land strokes on the beat and templates can pulse with the music.
- **History Wall:** every song's wallpaper is kept in a gallery grouped by month. Filter it, flip through it with the
  arrow keys, and export a month as a contact sheet or an animated GIF. Turn it off or clear it from the menu.
- **Share Lyric Card** (⌃⌥⌘L): the current template with the line being sung, as a 9:16 Story or a square image,
  saved to Pictures and copied to the clipboard.
- **Focus Mode:** lyrics hide themselves while you share your screen (Zoom, Google Meet, Teams, Slack, Discord,
  FaceTime, Webex, Screen Sharing), or whenever you press ⌃⌥⌘F.
- **Translations:** lyrics from NetEase and QQ Music can show a translation under each line, for songs in a language
  you don't read (Lyric Card, Glow, Minimal and Painted Cover).
- **Duets:** each line knows who sings it; Lyric Card and Glow lay a duet out voice by voice.
- **Share templates:** export any template as a `.swtemplate` file, double-click one to install it, or install from a
  `spotify-wallpaper://install?url=…` link.
- For template authors: `track.genre` (from Apple's iTunes catalogue), `weather`, `time.dayPhase`/`sunProgress`,
  `focus`, per-line `translation` and `singer`, a `beat` event with `--beat` and `--level`, and the handwriting fonts
  Bradley Hand, Noteworthy and Chalkboard SE. See TEMPLATE_GUIDE.

### Changed
- What's New no longer breaks a wrapped list item into separate paragraphs.
- Weather uses your approximate location (asked once); turn it off with "Use Weather" in the menu.

## 1.4.1 — 2026-10-07

### Added
- **More kinds of stroke in Painted Cover:** curved sweeps, raised impasto dabs, dry brush and hatching join the knife
  slabs. A new **Strokes** setting mixes them (slabs and sweeps block in, dry brush models, impasto and hatching pick
  out detail) or uses one kind throughout. The brush library gains `studio.sweep`, `studio.impasto`, `studio.hatch`
  and `studio.dry`.

### Changed
- Painted Cover and Brushwork only start a new painting when the **cover** changes, so the next song from the same
  album keeps painting the same canvas instead of starting over.
- Painted Cover Wide: film grain sits on the song card only (on by default), never over the painting; the lyrics fill
  whatever height the title leaves, so the "Lines after" setting is gone. Painted Cover's grain sits behind the
  painting, on the background.

### Fixed
- Skipping or seeking a song sometimes put your own wallpaper back for a moment. A single empty reading from Spotify
  no longer counts as "stopped"; your wallpaper comes back once nothing has played for about 5 seconds.

## 1.4.0 — 2026-10-04

### Added
- **Brushwork** template: a living oil painting made from the cover with p5.js bristle brushes, in four styles
  (Swirling Night, Impasto Jungle, Ink, Wave & Gold, Paisley Tapestry). The title, artist and synced lyrics sit on a
  calm field of paint that the busy strokes stop at, so the text reads on any cover; every new lyric line adds a
  star, a flower, an ink splash or a paisley. A new song is painted over the
  old one slowly, and the still wallpaper is the finished painting. Settings for painting speed, text side and fonts.
- **Painted Cover** and **Painted Cover Wide** templates: the cover itself repainted as a coarse knife painting in
  sharp, flat strokes that follow the image's edges, with the song set in Helvetica Neue beside it (or on a solid
  panel over a full-screen painting). Detail grows as the song plays (or stays fixed), a new song is painted over the
  last one coarse to fine, and each lyric line repaints a band.
- For code templates: p5.js 1.9.4 (`/runtime/vendor/p5.min.js`), a brush library (`/runtime/brush.js`) with eased,
  time-based bristle and knife strokes, masks and clipping, and cover sampling (colour, detail, edge direction), and
  `/runtime/cover-painter.js`, the engine behind the Painted Cover templates.
- Runtime hooks: `track`, `pause` and `resume` events, `Wallpaper.live`, `Wallpaper.paused`, `Wallpaper.fps`, and
  `Wallpaper.hold(promise)` to make a still wait for async work such as painting.

## 1.3.2 — 2026-10-03

### Added
- **What's New** window (menu → What's New…) showing this changelog. It opens once after the app updates itself.
- `CHANGELOG.md` in the repository.

## 1.3.1 — 2026-10-03

### Added
- **Follow time** in the Template Builder: make any layer rotate, move, grow or fade with the song's progress, each lyric line, or the real clock (seconds, minutes, hours, day), around a pivot you choose. Runs on the GPU.
- **Analog Clock** starter, with hands that follow the real time.
- **Variables in text**: write `Now playing {{track.title}} · {{time.clock}}`, or use the **＋** next to a Text layer's text to insert song, lyric and time variables.
- **More display sizes** to preview designs at: your own screens plus MacBook Air/Pro, iMac, Studio Display, Pro Display XDR, 1080p, 1440p, 1600p, 4K, ultrawide, super-ultrawide and portrait.
- For code templates: `data-follow` maps any CSS animation onto the song, the current line or the clock; `data-template` mixes variables into text. Templates made with **Edit Code** start with a reference of every variable, attribute and hook.

## 1.3.0 — 2026-10-03

### Added
- **Template Builder**, a Figma-style editor for making templates without code: draw text, lyrics, the album cover, images, shapes (rectangle, ellipse, line, triangle, star, polygon, arrow), a vinyl record, a progress bar, a waveform and color swatches on a live canvas.
- Builder layers panel (reorder, rename, hide, lock), right-click menu, copy/paste, undo/redo, snapping and autosave.
- Builder design panel: alignment, rotation, opacity, corner radius, blend modes, typography, fills (solid, gradient, album cover, image), colors that follow each song's cover, stroke, drop shadow, blur, frosted glass and looping motion.
- **Edit Code**: turns a Builder design into an HTML/CSS template and opens it in your code editor.
- Four new animated templates: **Vinyl**, **Typewriter**, **Lock Screen** and **Visualizer**.
- Time variables for code templates (`time.song`, `time.line`, `time.clock`, `time.date`, `--song-time`, `--line-time`), plus `tick` and `line` events.

### Changed
- Redesigned the Customize window and the Builder with a shared design system. Their title bars now hold the window controls.
- **Much lighter**: CPU use while animating dropped from ~30–60% to ~1–5% at a steady 60 fps.
  - Spotify is read on a background thread, driven by its playback notifications.
  - Lyric lines change on timers set for their exact timestamps.
  - The progress bar, karaoke sweep and waveform run on the GPU compositor.
  - The cover is blurred once per song.
  - Film grain is a precomputed image.
  - Everything pauses when windows cover the desktop.

## 1.2.0 — 2026-10-03

### Added
- **Automatic updates** from GitHub releases. The download is checked against GitHub's SHA-256 checksum and the app's signature before installing. Menu items: **Check for Updates…** and **Automatically Install Updates**.

### Fixed
- The Customize window can be moved by dragging its title bar again.

## 1.1.1 — 2026-10-02

### Fixed
- Better lyrics for non-English songs: a remix, live, acoustic or language version only matches the same kind of version, and a source has to match a good share of lines to count.
- Credit lines in Japanese, traditional Chinese, Korean and English are filtered out.
- Right-to-left lyrics (Arabic, Hebrew) flow and align correctly.

## 1.1.0 — 2026-10-02

### Added
- Lyrics from four sources: **LRCLIB, NetEase Cloud Music, QQ Music and Kugou**, searched in parallel.
- **Consensus timing**: lines are matched across sources and each one uses the median timestamp.
- **Lyrics** menu: see which sources were used, pick one source, nudge timing earlier or later per song, or search again.

## 1.0.0 — 2026-10-02

### Added
- First release: a menu bar app that turns your desktop into what Spotify is playing, with the album cover and live, synced lyrics on every Space and every monitor.
- Animated layer above the wallpaper, plus the real wallpaper kept in sync with a still of each song.
- Templates: Lyric Card, Album Poster, Minimal and Glow.
- Customize window with a live preview and per-template settings, plus Duplicate & edit code.
- Refresh rate setting, Launch at Login and Pause.
