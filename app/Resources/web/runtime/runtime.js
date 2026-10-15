/*
 * Lirica template runtime. Every template includes this. It:
 *   - binds data to the page:      data-bind="track.title|upper"  data-src="track.cover"
 *                                  data-show="lyrics.hasLyrics"    data-attr-after="params.linesAfter"
 *   - exposes CSS variables:       --progress --line-progress --cover-url --vibrant --p0… --param-<key>
 *   - drives smart components:     <lyrics-block> <fit-text> <swatch-row> <wave-form> <progress-bar>
 *   - offers hooks for custom JS:  Wallpaper.on('render', ctx => …)
 *   - tags <html> with the moment: sw-focus, sw-duet, sw-weather-<condition>, sw-phase-<night|dawn|day|dusk>
 *   - relays beats from the app:   Wallpaper.on('beat', b => …), --beat (decaying pulse) and --level
 *   - playback controls:           data-control="playPause|next|previous|seek|volume" click, drag or scroll
 * See TEMPLATE_GUIDE.md in the templates folder for the full reference.
 */
(function () {
  const FONTS = {
    "SF Pro": "-apple-system, system-ui, sans-serif",
    "SF Pro Variable": "'SF Var', -apple-system, sans-serif",
    "SF Pro Rounded": "ui-rounded, -apple-system, sans-serif",
    "SF Mono": "ui-monospace, Menlo, monospace",
    "New York": "ui-serif, 'New York', Georgia, serif",
    "Helvetica Neue": "'Helvetica Neue', Helvetica, sans-serif",
    "Avenir Next": "'Avenir Next', Avenir, sans-serif",
    "Futura": "Futura, sans-serif",
    "Gill Sans": "'Gill Sans', sans-serif",
    "Optima": "Optima, sans-serif",
    "Didot": "Didot, serif",
    "Bodoni 72": "'Bodoni 72', serif",
    "Baskerville": "Baskerville, serif",
    "Georgia": "Georgia, serif",
    "American Typewriter": "'American Typewriter', serif",
    "Courier New": "'Courier New', monospace",
    "Snell Roundhand": "'Snell Roundhand', cursive",
    "Marker Felt": "'Marker Felt', fantasy",
    "Bradley Hand": "'Bradley Hand', 'Noteworthy', cursive",
    "Noteworthy": "Noteworthy, 'Marker Felt', cursive",
    "Chalkboard SE": "'Chalkboard SE', 'Marker Felt', cursive",
  };
  const AUTO_COLORS = ["vibrant", "dominant", "card", "deep", "dark", "light", "muted", "paper", "onDominant"];

  const listeners = {};
  const Wallpaper = (window.Wallpaper = {
    fonts: FONTS,
    autoColors: AUTO_COLORS,
    manifest: null,
    ctx: null,
    /// the latest beat-sync state from the app: tempo, time of the last onset (ms since 1970), smoothed loudness 0–1
    beat: { bpm: 0, last: 0, level: 0, strength: 0 },
    /// Promises the first render waits for (e.g. the Builder renderer building the page from design.json).
    waits: [],
    /// Promises the current render waits for before layout and the still snapshot (e.g. a sketch loading the cover).
    holds: [],
    hold(promise) { Wallpaper.holds.push(Promise.resolve(promise).catch(() => {})); return promise; },
    /// true on the animated desktop layer, false while rendering a still
    get live() { return !!live; },
    /// true while the desktop is covered (everything should stop)
    get paused() { return paused; },
    /// the app's Refresh Rate setting; 0 = every display frame
    get fps() { return (live && +live.fps) || 0; },
    on(event, fn) { (listeners[event] = listeners[event] || []).push(fn); },
    /// Re-apply the current state after the page's DOM was rebuilt.
    refresh() {
      if (live) { liveDirty = true; liveUpdate(); }
      else if (lastPayload) schedule(lastPayload);
    },
  });
  const emit = (event, ...args) =>
    (listeners[event] || []).forEach((fn) => { try { fn(...args); } catch (e) { console.error(e); } });

  // ---------- helpers ----------

  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const fmtTime = (s) => {
    s = Math.max(0, Math.floor(s || 0));
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  };
  const get = (obj, path) => path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);
  const PIPES = {
    upper: (v) => String(v ?? "").toUpperCase(),
    lower: (v) => String(v ?? "").toLowerCase(),
    note: (v) => (String(v ?? "").trim() ? v : "• • •"),
    time: (v) => fmtTime(v),
    pct: (v) => Math.round((v || 0) * 100) + "%",
    hex: (v) => String(v ?? "").toUpperCase(),
    kclass: (v) => (v ? "karaoke" : ""),
    isBlur: (v) => v === "blur",
  };
  function evaluate(expr, ctx) {
    expr = expr.trim();
    let negate = false;
    if (expr.startsWith("!")) { negate = true; expr = expr.slice(1); }
    const [path, ...pipes] = expr.split("|").map((s) => s.trim());
    let v = /^-?[\d.]+$/.test(path) ? +path : get(ctx, path);
    for (const p of pipes) if (PIPES[p]) v = PIPES[p](v);
    return negate ? !v : v;
  }
  function toPx(v, fallback) {
    if (v == null || v === "") return fallback;
    const m = String(v).match(/^([\d.]+)\s*(px|vmin|vmax|vw|vh)?$/);
    if (!m) return fallback;
    const n = parseFloat(m[1]), W = innerWidth, H = innerHeight;
    return { px: n, vmin: (n * Math.min(W, H)) / 100, vmax: (n * Math.max(W, H)) / 100, vw: (n * W) / 100, vh: (n * H) / 100 }[m[2] || "px"];
  }
  function hash(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) h = Math.imul(h ^ str.charCodeAt(i), 16777619);
    return h >>> 0;
  }

  // ---------- time ----------

  const pageStart = performance.now();
  // formatters are expensive to create, so make them once
  const FMT = {
    clock: new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }),
    date: new Intl.DateTimeFormat([], { weekday: "long", month: "long", day: "numeric" }),
    day: new Intl.DateTimeFormat([], { weekday: "long" }),
  };
  let textCache = { minute: -1 };
  /** Where the day is: from the weather's sunrise/sunset when known (times of day, so yesterday's still work), else the
   *  clock (dawn 5–8, day 8–17, dusk 17–20). sunProgress runs 0→1 from sunrise to sunset. */
  function dayPhase(d, w) {
    const mins = (x) => x.getHours() * 60 + x.getMinutes() + x.getSeconds() / 60;
    const now = mins(d);
    let rise = 390, set = 1110, dawn = [300, 480], dusk = [1020, 1200];
    if (w && w.sunrise && w.sunset) {
      rise = mins(new Date(w.sunrise)); set = mins(new Date(w.sunset));
      if (set <= rise) set += 1440;
      dawn = [rise - 50, rise + 70]; dusk = [set - 70, set + 50];
    }
    const at = (r) => (now >= r[0] && now < r[1]) || (now + 1440 >= r[0] && now + 1440 < r[1]);
    const phase = at(dawn) ? "dawn" : at(dusk) ? "dusk" : at([dawn[1], dusk[0]]) ? "day" : "night";
    return { dayPhase: phase, sunProgress: clamp((now - rise) / (set - rise), 0, 1) };
  }
  function timeInfo(song, line, weather) {
    const d = new Date();
    const minuteKey = Math.floor(d.getTime() / 60000);
    if (textCache.minute !== minuteKey) {
      textCache = {
        minute: minuteKey,
        clock: FMT.clock.format(d),
        clock24: String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"),
        date: FMT.date.format(d),
        day: FMT.day.format(d),
      };
    }
    return {
      song, line,
      now: (performance.now() - pageStart) / 1000,
      hour: d.getHours(), minute: d.getMinutes(), second: d.getSeconds() + d.getMilliseconds() / 1000,
      clock: textCache.clock, clock24: textCache.clock24, date: textCache.date, day: textCache.day,
      ...dayPhase(d, weather),
    };
  }

  /** Per-frame CSS variables cost a style pass over the whole page, so only update the ones a template uses. */
  const FRAME_VARS = ["--progress", "--line-progress", "--song-time", "--line-time", "--time", "--hour", "--minute", "--second"];
  /** --beat / --level change with the music, not the clock: set only when beats arrive (and only if used). */
  const BEAT_VARS = ["--beat", "--level"];
  let usedVars = new Set(), usedBeatVars = new Set();
  function scanUsedVars() {
    let text = "";
    for (const sheet of document.styleSheets) {
      if (sheet.href && sheet.href.includes("/runtime/runtime.css")) continue;
      try { for (const r of sheet.cssRules) text += r.cssText; } catch (e) {}
    }
    // inline styles written by templates (not the root element, where the runtime itself sets every variable)
    for (const el of document.body.querySelectorAll("[style]")) text += el.getAttribute("style");
    usedVars = new Set(FRAME_VARS.filter((v) => text.includes(v)));
    usedBeatVars = new Set(BEAT_VARS.filter((v) => text.includes(v)));
  }

  function frameVars(ctx) {
    const s = document.documentElement.style, t = ctx.time;
    const values = { "--progress": ctx.track.progress, "--line-progress": ctx.lyrics.lineProgress, "--song-time": t.song,
      "--line-time": t.line, "--time": t.now, "--hour": t.hour, "--minute": t.minute, "--second": t.second };
    for (const v of usedVars) s.setProperty(v, values[v]);
  }

  // ---------- state → template context ----------

  function resolveParams(raw, colors) {
    const out = {};
    for (const p of (Wallpaper.manifest && Wallpaper.manifest.params) || []) {
      let v = raw[p.key] !== undefined ? raw[p.key] : p.default;
      if (p.type === "color" && typeof v === "string" && v.startsWith("auto:")) v = colors[v.slice(5)] || "#888888";
      out[p.key] = v;
    }
    for (const k in raw) if (!(k in out)) out[k] = raw[k];
    return out;
  }

  // Regions that read temperatures in Fahrenheit.
  const FAHRENHEIT = /-(US|LR|MM|BS|BZ|KY|PW|FM|MH)\b/i.test(navigator.language || "");
  function weatherInfo(w) {
    const c = +w.temperature, has = isFinite(c) && w.temperature !== null && w.temperature !== "";
    const f = c * 9 / 5 + 32;
    return {
      ...w,
      condition: String(w.condition).toLowerCase(),
      isDay: w.isDay !== undefined ? !!w.isDay : undefined,
      tempC: has ? Math.round(c) + "°" : "",
      tempF: has ? Math.round(f) + "°" : "",
      temp: has ? Math.round(FAHRENHEIT ? f : c) + "°" : "",
    };
  }

  function derive(payload) {
    const t = payload.track || {};
    const L = payload.lyrics || {};
    const lines = L.lines || [];
    const i = L.index ?? -1;
    const text = (k) => (k >= 0 && k < lines.length ? lines[k].text : "");
    const colors = payload.colors || {};
    const lineStart = i >= 0 ? lines[i].t : 0;
    const lineEnd = i + 1 < lines.length ? lines[i + 1].t : t.duration || lineStart + 4;
    const prev = [], next = [];
    for (let k = 1; k <= 8; k++) { prev.push(text(i - k)); next.push(text(i + k)); }
    const current = text(i);
    const cur = i >= 0 && i < lines.length ? lines[i] : {};
    const singers = Array.isArray(L.singers) ? L.singers.filter(Boolean) : [];
    const w = payload.weather && typeof payload.weather === "object" && payload.weather.condition ? payload.weather : null;
    return {
      track: {
        ...t,
        genre: t.genre || "",
        progress: t.duration ? clamp(t.position / t.duration, 0, 1) : 0,
        elapsed: fmtTime(t.position),
        remaining: "-" + fmtTime((t.duration || 0) - (t.position || 0)),
        length: fmtTime(t.duration),
      },
      lyrics: {
        lines, index: i, current, prev, next,
        prev1: prev[0], next1: next[0], next2: next[1], next3: next[2],
        lineProgress: i >= 0 ? clamp((t.position - lineStart) / Math.max(0.1, lineEnd - lineStart), 0, 1) : 0,
        synced: !!L.synced,
        hasLyrics: lines.length > 0,
        isInstrumental: lines.length > 0 && !current.trim(),
        translation: (current.trim() && cur.translation) || "",
        singer: cur.singer || "",
        singers,
        isDuet: singers.length > 1,
        hasTranslation: !!L.hasTranslation || lines.some((l) => l.translation),
      },
      weather: w && weatherInfo(w),
      focus: !!payload.focus,
      colors,
      time: timeInfo(t.position || 0, i >= 0 ? (t.position || 0) - lineStart : 0, w),
      params: resolveParams(payload.params || {}, colors),
      screen: payload.screen || { width: innerWidth, height: innerHeight, scale: devicePixelRatio },
    };
  }

  // ---------- applying the context ----------

  function applyVariables(ctx) {
    const root = document.documentElement, s = root.style;
    s.setProperty("--progress", ctx.track.progress);
    s.setProperty("--line-progress", ctx.lyrics.lineProgress);
    s.setProperty("--cover-url", ctx.track.cover ? `url("${ctx.track.cover}")` : "none");
    for (const name of AUTO_COLORS) if (ctx.colors[name]) s.setProperty("--" + name, ctx.colors[name]);
    (ctx.colors.palette || []).forEach((c, k) => s.setProperty("--p" + k, c));

    for (const p of (Wallpaper.manifest && Wallpaper.manifest.params) || []) {
      let v = ctx.params[p.key];
      if (p.type === "font") v = FONTS[v] || v;
      else if (p.type === "bool") { root.classList.toggle("param-" + p.key, !!v); v = v ? 1 : 0; }
      else if ((p.type === "number" || p.type === "int") && p.unit) v = v + p.unit;
      s.setProperty("--param-" + p.key, v);
    }
    const flags = {
      "is-playing": ctx.track.isPlaying, "has-lyrics": ctx.lyrics.hasLyrics, synced: ctx.lyrics.synced,
      instrumental: ctx.lyrics.isInstrumental, ultrawide: ctx.screen.width / ctx.screen.height > 2,
    };
    for (const k in flags) root.classList.toggle(k, !!flags[k]);
    momentClasses(ctx);
  }

  /** <html> classes for the moment: focus, duet, weather, time of day. Called on render and every live tick. */
  function momentClasses(ctx) {
    const root = document.documentElement;
    root.classList.toggle("sw-focus", ctx.focus);
    root.classList.toggle("sw-duet", ctx.lyrics.isDuet);
    const want = ["sw-phase-" + ctx.time.dayPhase];
    if (ctx.weather) want.push("sw-weather-" + ctx.weather.condition);
    for (const c of [...root.classList]) if (/^sw-(phase|weather)-/.test(c) && !want.includes(c)) root.classList.remove(c);
    for (const c of want) root.classList.add(c);
  }

  function applyBindings(ctx) {
    for (const el of document.querySelectorAll("*")) {
      for (const attr of [...el.attributes]) {
        if (!attr.name.startsWith("data-attr-")) continue;
        const name = attr.name.slice(10), v = String(evaluate(attr.value, ctx) ?? "");
        if (el.getAttribute(name) !== v) el.setAttribute(name, v);
      }
    }
    for (const el of document.querySelectorAll("[data-bind]")) {
      const raw = evaluate(el.dataset.bind, ctx), v = raw == null ? "" : String(raw);
      if (el.textContent !== v) el.textContent = v;
    }
    // data-template="Now playing {{track.title}} · {{time.clock}}": text with variables (pipes work too)
    for (const el of document.querySelectorAll("[data-template]")) {
      const v = el.dataset.template.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_, expr) => { const r = evaluate(expr, ctx); return r == null ? "" : String(r); });
      if (el.textContent !== v) el.textContent = v;
    }
    // data-cover-blur="<px>" (+ optional data-cover-saturate): the cover, blurred once by the app, as a background
    for (const el of document.querySelectorAll("[data-cover-blur]")) {
      const r = Math.max(0, Math.round(+evaluate(el.dataset.coverBlur, ctx) || 0));
      const sat = el.dataset.coverSaturate ? +evaluate(el.dataset.coverSaturate, ctx) || 1 : 1;
      const url = `url("/coverblur/${r}/${sat}/${encodeURIComponent(ctx.track.id || "none")}.jpg")`;
      if (el._coverBlur !== url) { el._coverBlur = url; el.style.backgroundImage = url; }
    }
    for (const el of document.querySelectorAll("[data-src]")) {
      const v = evaluate(el.dataset.src, ctx);
      if (v && el.getAttribute("src") !== v) {
        const replacing = el.hasAttribute("src");
        el.setAttribute("src", v);
        if (replacing && el.animate) el.animate([{ opacity: 0.2 }, { opacity: 1 }], { duration: 420, easing: "ease-out" });
      }
    }
    for (const el of document.querySelectorAll("[data-show]")) {
      const hide = !evaluate(el.dataset.show, ctx);
      if (el.hidden !== hide) {
        el.hidden = hide;
        if (!hide && el.animate) el.animate([{ opacity: 0, transform: "translateY(0.3em)" }, { opacity: 1, transform: "none" }], { duration: 340, easing: "ease-out" });
      }
    }
  }

  // ---------- components ----------

  /** A boolean attribute that templates may also bind (data-attr-x="params.x" writes "true"/"false"). */
  const flagAttr = (el, name, fallback) => el.hasAttribute(name) ? !/^(false|0)$/.test(el.getAttribute(name)) : !!fallback;

  // Children are an intro line ("• • •" before the first lyric) followed by one .line per lyric. A line's text is its
  // first child (a text node); with `translations` on, its translation follows as <span class="tr">. Duets add
  // data-singer="A|B|both" on each sung line.
  function lyricsBlock(el, ctx) {
    const { lines, index } = ctx.lyrics;
    const before = +(el.getAttribute("before") ?? 2), after = +(el.getAttribute("after") ?? 3);
    const layout = el.getAttribute("layout") || "flow";
    const empty = el.getAttribute("empty") ?? "• • •";
    const tr = flagAttr(el, "translations", ctx.params.translations === true) && ctx.lyrics.hasTranslation;
    const sig = ctx.track.id + ":" + lines.length + ":" + empty + ":" + tr + ":" + ctx.lyrics.isDuet;
    let inner = el.querySelector(":scope > .lines");
    if (!inner || el._sig !== sig) {
      el.innerHTML = "";
      inner = document.createElement("div");
      inner.className = "lines";
      el.appendChild(inner);
      if (lines.length) [{ text: "" }, ...lines].forEach((l, k) => {
        const d = document.createElement("div"), sung = k > 0 && l.text.trim();
        d.appendChild(document.createTextNode(sung ? l.text : empty));
        if (sung && l.singer) d.dataset.singer = l.singer;
        if (sung && tr && l.translation) d.appendChild(Object.assign(document.createElement("span"), { className: "tr", textContent: l.translation }));
        inner.appendChild(d);
      });
      el._sig = sig;
    }
    el.classList.toggle("has-translations", tr);
    el.dataset.layout = layout;
    [...inner.children].forEach((d, k) => {
      const isIntro = k === 0;
      const off = k - 1 - index;
      const state = off < 0 ? "past" : off === 0 ? "current" : "next";
      const out = off < -before || off > after || (isIntro && index >= 0);
      const gap = isIntro || !lines[k - 1].text.trim();
      d.className = "line " + state + (out ? " out" : "") + (gap ? " gap" : "");
      d.dataset.offset = off;
      d.style.setProperty("--offset", off);
      d.style.setProperty("--dist", Math.abs(off));
    });
  }

  function positionLyrics(el, ctx) {
    const inner = el.querySelector(":scope > .lines");
    if (!inner || el.dataset.layout === "flow" || !inner.children.length) return;
    const kids = inner.children;
    const cur = Math.min(kids.length - 1, ctx.lyrics.index + 1);
    let y;
    if (el.dataset.layout === "top") {
      const first = [...kids].findIndex((d) => !d.classList.contains("out"));
      y = -kids[Math.max(0, first)].offsetTop;
    } else {
      y = el.clientHeight / 2 - (kids[cur].offsetTop + kids[cur].offsetHeight / 2);
    }
    inner.style.transform = `translateY(${y}px)`;
  }

  function fitText(el) {
    const maxLines = +(el.getAttribute("max-lines") || 1);
    let lo = toPx(el.getAttribute("min"), 8), hi = toPx(el.getAttribute("max"), 400), best = lo;
    const fits = () => {
      const cs = getComputedStyle(el);
      let lh = parseFloat(cs.lineHeight);
      if (isNaN(lh)) lh = parseFloat(cs.fontSize) * 1.2;
      return el.scrollHeight <= lh * maxLines + 1 && el.scrollWidth <= el.clientWidth + 1;
    };
    for (let n = 0; n < 16; n++) {
      const mid = (lo + hi) / 2;
      el.style.fontSize = mid + "px";
      if (fits()) { best = mid; lo = mid; } else hi = mid;
    }
    el.style.fontSize = best + "px";
  }

  function swatchRow(el, ctx) {
    const n = +(el.getAttribute("count") || 5);
    const labels = el.hasAttribute("labels") && el.getAttribute("labels") !== "false";
    el.innerHTML = (ctx.colors.palette || []).slice(0, n).map((c) =>
      `<div class="swatch"><div class="chip" style="background:${c}"></div>${labels ? `<div class="hex">${c.toUpperCase()}</div>` : ""}</div>`
    ).join("");
  }

  // Each bar is .bar > i: the bar's scaleY is its height for the current line (eased by a CSS transition), and
  // the inner i bobs with a Web Animation that runs on the compositor; no per-frame script.
  function waveForm(el, ctx) {
    const n = +(el.getAttribute("bars") || 56);
    let seed = hash(ctx.track.id + ":" + ctx.lyrics.index);
    const rnd = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 4294967296);
    if (el.children.length !== n) {
      el.innerHTML = "";
      for (let k = 0; k < n; k++) {
        const bar = Object.assign(document.createElement("div"), { className: "bar" });
        bar.appendChild(document.createElement("i"));
        el.appendChild(bar);
      }
      el._bob = null;
    }
    [...el.children].forEach((bar, k) => {
      const env = 0.25 + 0.75 * Math.pow(1 - Math.abs(k - n / 2) / (n / 2), 0.6);
      bar.style.transform = `scaleY(${(Math.max(8, env * (25 + 75 * rnd())) / 100).toFixed(3)})`;
    });
    if (live) bobWaves(el, ctx.track.isPlaying);
  }

  function bobWaves(el, playing) {
    const motion = +(el.getAttribute("motion") || 0.18);
    if (!el._bob || el._bobMotion !== motion) {
      (el._bob || []).forEach((a) => a.cancel());
      el._bobMotion = motion;
      el._bob = [...el.children].map((bar, k) => bar.firstChild.animate(
        [{ transform: `scaleY(${(1 - motion).toFixed(3)})` }, { transform: "scaleY(1)" }],
        { duration: 340 + ((k * 137) % 260), delay: -((k * 89) % 400), iterations: Infinity, direction: "alternate", easing: "ease-in-out" }));
    }
    for (const a of el._bob) playing && !paused ? a.play() : a.pause();
  }

  function progressBar(el) {
    if (!el.querySelector(":scope > .fill")) el.appendChild(Object.assign(document.createElement("div"), { className: "fill" }));
  }

  // ---------- time-driven animations ----------
  // An element with data-follow="song|line|seconds|minutes|hours|day" and a CSS animation gets that animation's
  // timeline mapped onto the song, the current line, or the clock: 0% at the start, 100% at the end. The browser
  // plays it on the compositor between syncs, so it costs nothing per frame.

  const CLOCK_PERIOD = { seconds: 60, minutes: 3600, hours: 43200, day: 86400 };
  function syncFollow(ctx, playing) {
    const lines = ctx.lyrics.lines, i = ctx.lyrics.index;
    const lineLength = i >= 0 && i + 1 < lines.length ? lines[i + 1].t - lines[i].t : Math.max(1, (ctx.track.duration || 0) - (lines[i] ? lines[i].t : 0));
    const now = new Date(), wall = (now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds() + now.getMilliseconds() / 1000);
    for (const el of document.querySelectorAll("[data-follow]")) {
      const mode = el.dataset.follow;
      for (const anim of el.getAnimations()) {
        let duration, at, loop = false, run = playing;
        if (mode === "song") { duration = ctx.track.duration || 1; at = ctx.track.position || 0; }
        else if (mode === "line") { duration = lineLength; at = i >= 0 ? ctx.time.line : 0; }
        else if (CLOCK_PERIOD[mode]) { duration = CLOCK_PERIOD[mode]; at = wall % duration; loop = true; run = !paused; }
        else continue;
        anim.effect.updateTiming({ duration: Math.max(1, duration * 1000), iterations: loop ? Infinity : 1, fill: "both", easing: "linear" });
        anim.currentTime = Math.max(0, at * 1000);
        if (run && live) anim.play(); else anim.pause();
      }
    }
  }

  // ---------- playback controls ----------
  // Elements with data-control control the real Spotify: playPause | next | previous | seek | volume.
  // A click sends the command to the app; seek (and volume) also follow a drag, volume follows the wheel.
  // The app lets clicks through to the page only while the pointer is over one of these elements, so the
  // runtime keeps it told where they are (reportControlRects, below) and nothing intercepts the rest of
  // the desktop.

  function sendControl(command, value) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.swCommand;
    if (handler) handler.postMessage(value == null ? { command } : { command, value });
    emit("control", { command, value });
  }
  Wallpaper.control = sendControl;

  const controlOf = (e) => (e.target && e.target.closest ? e.target.closest("[data-control]") : null);

  document.addEventListener("click", (e) => {
    const el = controlOf(e), command = el && el.dataset.control;
    if (!el) return;
    el.classList.remove("sw-tap");
    void el.offsetWidth;  // restart the bounce if it's clicked again mid-way
    el.classList.add("sw-tap");
    if (command === "playPause" || command === "next" || command === "previous") sendControl(command);
  });
  document.addEventListener("animationend", (e) => { if (e.target.classList) e.target.classList.remove("sw-tap"); });

  // a control dims and shrinks while it's held (sw-pressed); the click then bounces it back (sw-tap)
  let pressed = null;
  document.addEventListener("pointerdown", (e) => {
    const el = controlOf(e);
    if (!el || e.button !== 0) return;
    pressed = el;
    el.classList.add("sw-pressed");
  });
  const releasePress = () => {
    if (pressed) pressed.classList.remove("sw-pressed");
    pressed = null;
  };
  document.addEventListener("pointerup", releasePress);
  document.addEventListener("pointercancel", releasePress);

  // a long press on a control shouldn't pop the page's (empty) context menu over the desktop
  document.addEventListener("contextmenu", (e) => { if (controlOf(e)) e.preventDefault(); });

  // Drag to seek (or set the volume): throttled while dragging, then once more on release.
  const CONTROL_EVERY = 120;  // ms
  let scrub = null;
  function scrubTo(e) {
    const r = scrub.el.getBoundingClientRect();
    scrub.value = clamp((e.clientX - r.left) / Math.max(1, r.width), 0, 1);
    const now = Date.now();
    if (now - scrub.last >= CONTROL_EVERY) { scrub.last = now; sendControl(scrub.mode, scrub.value); }
  }
  document.addEventListener("pointerdown", (e) => {
    const el = controlOf(e), mode = el && el.dataset.control;
    if (mode !== "seek" || e.button !== 0) return;
    e.preventDefault();
    if (el.setPointerCapture) el.setPointerCapture(e.pointerId);
    scrub = { mode, el, id: e.pointerId, last: 0, value: null };
    scrubTo(e);
  });
  document.addEventListener("pointermove", (e) => { if (scrub && e.pointerId === scrub.id) scrubTo(e); });
  const endScrub = (e) => {
    if (!scrub || (e && e.pointerId !== scrub.id)) return;
    if (scrub.value != null) sendControl(scrub.mode, scrub.value);
    scrub = null;
  };
  document.addEventListener("pointerup", endScrub);
  document.addEventListener("pointercancel", endScrub);

  // The wheel over a volume control (or anything inside it) steps it like the volume keys (1/16th each).
  let wheelAccum = 0, wheelTimer = null;
  document.addEventListener("wheel", (e) => {
    const el = e.target && e.target.closest ? e.target.closest('[data-control="volume"]') : null;
    if (!el) return;
    e.preventDefault();
    wheelAccum += e.deltaY;
    if (wheelTimer) return;
    wheelTimer = setTimeout(() => {
      wheelTimer = null;
      const raw = -wheelAccum;
      if (Math.abs(raw) < 2) return;  // tiny trackpad deltas keep accumulating
      wheelAccum = 0;
      const steps = clamp(raw > 0 ? Math.max(1, Math.round(raw / 12)) : Math.min(-1, Math.round(raw / 12)), -3, 3);
      sendControl("volumeBy", steps / 16);
    }, 150);
  }, { passive: false });

  /** Tell the app where the controls are, so it knows where the pointer may take clicks from the desktop. */
  let controlRectSig = "";
  function reportControlRects() {
    if (!live) return;
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.swControls;
    if (!handler) return;
    const rects = [];
    for (const el of document.querySelectorAll("[data-control]")) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) rects.push([+r.left.toFixed(1), +r.top.toFixed(1), +r.width.toFixed(1), +r.height.toFixed(1)]);
    }
    const sig = JSON.stringify(rects);
    if (sig === controlRectSig) return;
    controlRectSig = sig;
    handler.postMessage({ rects });
  }
  addEventListener("resize", reportControlRects);

  // ---------- render ----------

  function applyAll(ctx) {
    Wallpaper.ctx = ctx;
    applyVariables(ctx);
    applyBindings(ctx);
    document.querySelectorAll("lyrics-block").forEach((el) => lyricsBlock(el, ctx));
    document.querySelectorAll("swatch-row").forEach((el) => swatchRow(el, ctx));
    document.querySelectorAll("wave-form").forEach((el) => waveForm(el, ctx));
    document.querySelectorAll("progress-bar").forEach(progressBar);
    reportControlRects();
    emit("render", ctx);
  }

  function layoutAll(ctx) {
    document.querySelectorAll("fit-text").forEach(fitText);
    document.querySelectorAll("lyrics-block").forEach((el) => positionLyrics(el, ctx));
    reportControlRects();
    emit("layout", ctx);
  }

  async function settle(ctx) {
    try { await document.fonts.ready; } catch (e) {}
    const waits = [...document.images].filter((i) => i.getAttribute("src")).map((i) => i.decode().catch(() => {}));
    if (ctx.track.cover) {
      const img = new Image();
      img.src = ctx.track.cover;
      waits.push(img.decode().catch(() => {}));
    }
    await Promise.all(waits);
    while (Wallpaper.holds.length) await Promise.all(Wallpaper.holds.splice(0));
  }

  const ready = new Promise((resolve) => {
    const boot = async () => {
      await Promise.all(Wallpaper.waits);
      try {
        const res = await fetch("manifest.json", { cache: "no-store" });
        Wallpaper.manifest = await res.json();
      } catch (e) {
        Wallpaper.manifest = { params: [] };
      }
      resolve();
    };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
    else boot();
  });

  // One-off render, used for the still that becomes the real wallpaper.
  let lastPayload = null;
  async function render(payload) {
    lastPayload = payload;
    await ready;
    const ctx = derive(payload);
    applyAll(ctx);
    syncFollow(ctx, false);  // stills show time-driven animations at this moment
    await settle(ctx);
    layoutAll(ctx);
    await sleep(30);
  }

  // Renders are serialized; if several arrive while one runs, only the newest is drawn.
  let running = null, queued = null;
  function schedule(payload) {
    if (running) {
      queued = payload;
      return running.then(() => (queued ? schedule(queued) : null));
    }
    queued = null;
    running = render(payload).finally(() => { running = null; });
    return running;
  }

  // ---------- live mode (desktop layer + preview) ----------
  // The app sends full state when the song/settings change and a playback clock about once a second. Nothing runs
  // per frame by default: the next lyric line is a timer set for its exact timestamp, and the moving parts
  // (progress bar, karaoke sweep, waveform) are Web Animations / CSS animations the compositor plays on its own.
  // A per-frame loop only runs for templates that ask for it (Wallpaper.on("frame") or per-frame CSS variables).

  const LEAD = 0.1;  // seconds a line shows before its timestamp
  let live = null, liveDirty = false, liveIdx = null, paused = false, liveTrackID = null;
  let lineTimer = null, tickTimer = null, looping = false, lastFrame = 0;
  const liveAnims = [];

  function livePosition() {
    const t = live.track;
    const p = (t.position || 0) + (t.isPlaying && !paused ? (Date.now() - (t.stamp || Date.now())) / 1000 : 0);
    return t.duration ? Math.min(p, t.duration) : p;
  }

  function indexAt(lines, pos) {
    let i = -1;
    for (let k = 0; k < lines.length; k++) {
      if (lines[k].t <= pos + LEAD) i = k; else break;
    }
    return i;
  }

  function liveContext() {
    const pos = livePosition();
    const lines = (live.lyrics && live.lyrics.lines) || [];
    return derive({ ...live, track: { ...live.track, position: pos }, lyrics: { ...live.lyrics, index: indexAt(lines, pos) } });
  }

  function restartEnterAnimations() {
    for (const el of document.querySelectorAll("[data-animate]")) {
      el.classList.remove("sw-enter");
      void el.offsetWidth;
      el.classList.add("sw-enter");
    }
  }

  /** Re-syncs everything to the playback clock. Runs on new state, each clock sync, and each line change. */
  function liveUpdate() {
    if (!live || paused) return;
    const ctx = liveContext();
    const lineChanged = ctx.lyrics.index !== liveIdx;
    if (liveDirty || lineChanged) {
      const firstForTrack = liveDirty;
      liveDirty = false;
      liveIdx = ctx.lyrics.index;
      applyAll(ctx);
      layoutAll(ctx);
      scanUsedVars();
      if (firstForTrack && ctx.track.id !== liveTrackID) { liveTrackID = ctx.track.id; emit("track", ctx); }
      if (lineChanged) { restartEnterAnimations(); emit("line", ctx); }
      if (firstForTrack) settle(ctx).then(() => live && layoutAll(Wallpaper.ctx));
    } else {
      Wallpaper.ctx = ctx;
      applyBindings(ctx);
    }
    frameVars(ctx);
    syncAnimations(ctx);
    scheduleNextLine(ctx);
    ensureFrameLoop();
  }

  /** Progress bars and the karaoke sweep: start from where the song is, animate to the end, on the compositor. */
  function syncAnimations(ctx) {
    liveAnims.splice(0).forEach((a) => a.cancel());
    const playing = ctx.track.isPlaying && !paused;
    const songLeft = Math.max(0, (ctx.track.duration || 0) - ctx.track.position);
    for (const fill of document.querySelectorAll("progress-bar > .fill")) {
      const from = `translateX(${((ctx.track.progress - 1) * 100).toFixed(3)}%)`;
      fill.style.transform = from;
      if (playing && songLeft > 0) {
        liveAnims.push(fill.animate([{ transform: from }, { transform: "translateX(0%)" }], { duration: songLeft * 1000, easing: "linear", fill: "forwards" }));
      }
    }
    const lines = ctx.lyrics.lines, i = ctx.lyrics.index;
    const lineEnd = i + 1 < lines.length ? lines[i + 1].t : ctx.track.duration;
    const lineLeft = Math.max(0, (lineEnd || 0) - ctx.track.position);
    // Karaoke without repainting: a bright copy of the line sits in a clip box; the box slides right-to-left while
    // the copy slides the opposite way, so the lit edge sweeps across while nothing is redrawn.
    document.querySelectorAll(".sw-kara").forEach((k) => { if (!k.parentElement.matches(".karaoke .line.current, .karaoke-text")) k.remove(); });
    for (const el of document.querySelectorAll(".karaoke .line.current, .karaoke-text")) {
      let clip = el.querySelector(":scope > .sw-kara");
      if (!clip || clip._text !== el.firstChild.textContent) {
        if (clip) clip.remove();
        clip = Object.assign(document.createElement("span"), { className: "sw-kara" });
        const copy = Object.assign(document.createElement("span"), { className: "sw-kara-text", textContent: el.firstChild.textContent });
        clip.appendChild(copy);
        clip._text = el.firstChild.textContent;
        el.appendChild(clip);
      }
      const copy = clip.firstChild, left = (1 - ctx.lyrics.lineProgress) * 100;
      const a = [`translateX(${-left}%)`, "translateX(0%)"], b = [`translateX(${left}%)`, "translateX(0%)"];
      clip.style.transform = a[0];
      copy.style.transform = b[0];
      if (playing && lineLeft > 0) {
        const timing = { duration: lineLeft * 1000, easing: "linear", fill: "forwards" };
        liveAnims.push(clip.animate(a.map((t) => ({ transform: t })), timing), copy.animate(b.map((t) => ({ transform: t })), timing));
      }
    }
    for (const w of document.querySelectorAll("wave-form")) bobWaves(w, playing);
    syncFollow(ctx, playing);
    document.documentElement.classList.toggle("sw-paused", paused);
  }

  function scheduleNextLine(ctx) {
    clearTimeout(lineTimer);
    if (!ctx.track.isPlaying || paused) return;
    const lines = ctx.lyrics.lines, next = lines[ctx.lyrics.index + 1];
    if (!next) return;
    const wait = (next.t - LEAD - ctx.track.position) * 1000;
    lineTimer = setTimeout(liveUpdate, Math.max(0, wait) + 5);
  }

  function ensureFrameLoop() {
    const wanted = !paused && (usedVars.size > 0 || (listeners.frame || []).length > 0);
    if (wanted && !looping) { looping = true; requestAnimationFrame(frame); }
  }

  function frame(now) {
    if (!live || paused || !(usedVars.size > 0 || (listeners.frame || []).length > 0)) { looping = false; return; }
    const fps = +live.fps || 0;  // the app's Refresh Rate setting; 0 = every display frame
    if (!fps || now - lastFrame >= 1000 / fps - 2) {
      lastFrame = now;
      const ctx = liveContext();
      frameVars(ctx);
      emit("frame", ctx);
    }
    requestAnimationFrame(frame);
  }

  function startLive(payload) {
    live = payload;
    liveDirty = true;
    document.documentElement.classList.add("sw-live");
    ready.then(() => {
      liveUpdate();
      if (!tickTimer) tickTimer = setInterval(() => {
        if (!live || paused) return;
        const ctx = liveContext();
        Wallpaper.ctx = ctx;
        applyBindings(ctx);  // elapsed time, clock
        momentClasses(ctx);  // the time of day moves on
        reportControlRects();  // drift of animated controls
        emit("tick", ctx);
      }, 1000);
    });
  }

  function setClock(c) {
    if (!live) return;
    live.track = { ...live.track, position: c.position, isPlaying: c.isPlaying, stamp: c.stamp };
    liveUpdate();
  }

  /** The desktop is fully covered (or uncovered): stop everything, then pick up where the song is. */
  function setPaused(p) {
    if (paused === !!p) return;
    paused = !!p;
    clearTimeout(lineTimer);
    if (paused) {
      liveAnims.forEach((a) => a.pause());
      document.getAnimations().forEach((a) => a.pause());
      document.documentElement.classList.add("sw-paused");
      emit("pause");
    } else {
      document.documentElement.classList.remove("sw-paused");
      document.getAnimations().forEach((a) => a.play());
      liveUpdate();
      emit("resume");
    }
  }

  // ---------- beat sync ----------
  // The app sends onsets ({strength, bpm, t}) and loudness ({level}) while beat sync is on. --beat is a pulse that
  // jumps to the onset's strength and decays to 0 in ~0.4 s; its short frame loop only runs while it decays, and only
  // for templates whose CSS uses --beat. Nothing here depends on beats arriving.
  const BEAT_DECAY = 0.16;  // seconds per e-fold
  let beatLooping = false, beatFrame = 0;
  function onBeat(m) {
    if (!m || typeof m !== "object") return;
    const b = Wallpaper.beat, s = document.documentElement.style;
    if (m.bpm) b.bpm = +m.bpm || 0;
    if (m.level != null && isFinite(+m.level)) {
      b.level = clamp(+m.level, 0, 1);
      if (live && !paused && usedBeatVars.has("--level")) s.setProperty("--level", b.level.toFixed(3));
    }
    if (m.strength == null || !live || paused) return;
    b.strength = clamp(+m.strength || 0, 0, 1);
    b.last = +m.t || Date.now();
    b.at = performance.now();
    emit("beat", { ...b });
    if (usedBeatVars.has("--beat") && !beatLooping) { beatLooping = true; requestAnimationFrame(beatPulse); }
  }
  function beatPulse(now) {
    const b = Wallpaper.beat, s = document.documentElement.style;
    const v = paused || !live ? 0 : b.strength * Math.exp(-(now - b.at) / 1000 / BEAT_DECAY);
    const fps = (live && +live.fps) || 0;
    if (v < 0.01) { s.setProperty("--beat", 0); beatLooping = false; return; }
    if (!fps || now - beatFrame >= 1000 / fps - 2) { beatFrame = now; s.setProperty("--beat", v.toFixed(3)); }
    requestAnimationFrame(beatPulse);
  }

  window.__sw = { render: schedule, live: startLive, clock: setClock, pause: setPaused, beat: onBeat };
  // The Customize window's preview talks over postMessage.
  window.addEventListener("message", (e) => {
    const m = e.data || {};
    if (m.type === "sw:update") schedule(m.payload);
    else if (m.type === "sw:live") startLive(m.payload);
    else if (m.type === "sw:clock") setClock(m.clock);
    else if (m.type === "sw:beat") onBeat(m.beat || m.payload);
  });
})();
