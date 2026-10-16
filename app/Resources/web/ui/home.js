// Home. Talks to the app through webkit.messageHandlers.app; the app calls App.receive().
// Only the stage preview (or the open sheet's) is a live template; everything else is a thumbnail
// (/thumb/<id>.jpg?v=…, drawn by the app's ThumbnailService).

const S = {
  templates: [], byId: {}, values: {}, state: null, displays: [], defaultID: null, overrides: {},
  recents: [], favorites: new Set(), thumbs: {}, shown: {}, lyrics: null, prefs: { galleryMode: "grid" },
  tab: "wallpaper", view: "stage", stageID: null, stageFollows: true, target: "all", cat: "all", query: "",
  crate: 0, sheet: null, disp: null, moreOpen: false, visible: true, collapsed: false, clockAt: 0,
};
const $ = (id) => document.getElementById(id);
const post = (msg) => window.webkit?.messageHandlers?.app?.postMessage(msg);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const enc = encodeURIComponent;
const P = (d, w = 1.5) => `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
const ICON = {
  more: P('<circle cx="3.5" cy="8" r=".6"/><circle cx="8" cy="8" r=".6"/><circle cx="12.5" cy="8" r=".6"/>', 2),
  star: P('<path d="M8 2.2l1.7 3.6 3.9.5-2.9 2.7.8 3.9L8 11l-3.5 1.9.8-3.9-2.9-2.7 3.9-.5z"/>', 1.4),
  starOn: '<svg viewBox="0 0 16 16"><path d="M8 2.2l1.7 3.6 3.9.5-2.9 2.7.8 3.9L8 11l-3.5 1.9.8-3.9-2.9-2.7 3.9-.5z" fill="currentColor"/></svg>',
  search: P('<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2L13.5 13.5"/>'),
  chev: P('<path d="M6 3.5L10.5 8 6 12.5"/>', 1.6),
  collapse: P('<path d="M4 6l4 4 4-4"/>', 1.6),
  expand: P('<path d="M4 10l4-4 4 4"/>', 1.6),
};
const CATS = [["all", "All"], ["lyrics", "Lyrics"], ["painting", "Painting"], ["print", "Print & paper"], ["objects", "Objects"], ["calm", "Calm"], ["yours", "Yours"]];
const CAT_NAME = Object.fromEntries(CATS);
const AUTO_LABELS = { vibrant: "Vibrant", dominant: "Dominant", card: "Card", deep: "Deep", dark: "Dark", light: "Light", muted: "Muted", paper: "Paper", onDominant: "On dominant" };
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

// ================================================================== bridge

window.App = {
  receive(msg) {
    switch (msg.type) {
      case "init": init(msg); break;
      case "state": applyStatus(msg); renderLive(); break;
      case "thumbs": applyThumbs(msg.thumbs); break;
      case "clock": clock(msg.clock); break;
      case "reloadPreview": loadStage(true); if (S.sheet) loadSheetPreview(); break;
      case "visibility": S.visible = !!msg.visible; updatePause(); break;
      case "history": historyFrame()?.contentWindow?.App?.receive(msg.msg); break;
    }
  },
};
// The embedded History Wall posts through here (same origin), so all its messages come from the main frame.
window.HomeBridge = { history: (msg) => post({ type: "history", msg }) };

function init(msg) {
  const firstTime = !S.templates.length;
  S.templates = msg.templates;
  S.byId = Object.fromEntries(S.templates.map((t) => [t.id, t]));
  S.values = msg.values || {};
  if (msg.prefs) S.prefs = { ...S.prefs, ...msg.prefs };
  applyStatus(msg);
  if (!S.byId[S.stageID]) { S.stageID = currentFor(S.target); S.stageFollows = true; }
  if (msg.select && S.byId[msg.select]) { S.stageID = msg.select; S.stageFollows = false; S.view = "stage"; S.tab = "wallpaper"; }
  if (msg.tab) openTab(msg.tab, true);
  renderAll();
  if (firstTime || msg.select) loadStage(true);
  else sendStage();
  if (msg.sheet && S.byId[msg.sheet]) openSheet(msg.sheet);
  if (S.sheet && !S.byId[S.sheet]) closeSheet();
}

function applyStatus(msg) {
  const prevCurrent = S.defaultID ? currentFor(S.target) : null;
  S.state = msg.state || S.state;
  S.displays = msg.displays || S.displays;
  S.defaultID = msg.defaultID || S.defaultID;
  S.overrides = msg.overrides || {};
  S.recents = msg.recents || [];
  S.favorites = new Set(msg.favorites || []);
  S.lyrics = msg.lyrics || S.lyrics;
  S.settings = msg.settings || S.settings;
  if (S.target !== "all" && !S.displays.some((d) => d.id === S.target)) S.target = "all";
  if (S.disp == null || !S.displays.some((d) => d.id === S.disp)) S.disp = S.displays[0]?.id ?? null;
  if (msg.thumbs) applyThumbs(msg.thumbs);
  // the stage follows what's on screen unless the user picked something else to look at
  const now = currentFor(S.target);
  if (S.stageID && S.stageFollows && prevCurrent && now !== prevCurrent && S.byId[now]) { S.stageID = now; loadStage(); }
  if (S.state?.track?.position != null) S.clockAt = Date.now();
  setBackground();
}

// ================================================================== helpers

const tpl = (id) => S.byId[id];
const mainDisplay = () => S.displays.find((d) => d.main) || S.displays[0];
const displayName = (d) => d?.name || "Display";
function currentFor(target) {
  if (target === "all") { const m = mainDisplay(); return m?.template || S.defaultID; }
  return S.displays.find((d) => d.id === target)?.template || S.defaultID;
}
function inUse(id, target = S.target) {
  if (!S.displays.length) return S.defaultID === id;
  if (target === "all") return S.displays.every((d) => d.template === id);
  return S.displays.find((d) => d.id === target)?.template === id;
}
const onScreens = (id) => S.displays.filter((d) => d.template === id);
/// "In use" badge: on the stage's screen, or (for All screens) on any screen.
const shownOn = (id) => (S.target === "all" ? onScreens(id).length > 0 || (!S.displays.length && S.defaultID === id) : inUse(id));
function catKey(t) {
  const c = String(t.category || "").toLowerCase();
  if (c === "yours" || (!t.builtin && !CAT_NAME[c])) return "yours";
  const byName = CATS.find(([, n]) => n.toLowerCase() === c);
  return CAT_NAME[c] ? c : byName ? byName[0] : "lyrics";
}
function inCat(t, cat) {
  if (cat === "all") return true;
  if (cat === "yours") return !t.builtin || catKey(t) === "yours";
  return catKey(t) === cat;
}
const catLabel = (t) => (t.builtin ? CAT_NAME[catKey(t)] : catKey(t) === "yours" ? "Yours" : `${CAT_NAME[catKey(t)]} · Yours`);
function matches(t, q) {
  if (!q) return true;
  const hay = `${t.name} ${t.description} ${CAT_NAME[catKey(t)]}`.toLowerCase();
  return q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}
const fmt = (s) => { s = Math.max(0, Math.floor(s || 0)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };
const isSample = () => !S.state?.track || S.state.track.id === "sample";
function position() {
  const t = S.state?.track;
  if (!t) return 0;
  const p = (t.position || 0) + (t.isPlaying ? (Date.now() - (t.stamp || Date.now())) / 1000 : 0);
  return t.duration ? Math.min(p, t.duration) : p;
}
function setHTML(el, html) { if (el._html !== html) { el._html = html; el.innerHTML = html; } }
function targetDisplay() { return S.target === "all" ? null : S.target; }

// ================================================================== thumbnails

const thumbURL = (id, v = S.shown[id] ?? S.thumbs[id] ?? "0") => `/thumb/${enc(id)}.jpg?v=${enc(v)}`;
function thumb(id, extra = "") {
  if (S.shown[id] == null) S.shown[id] = S.thumbs[id] ?? "0";
  return `<div class="th" ${extra}><img data-thumb="${esc(id)}" src="${thumbURL(id)}" alt="" loading="lazy" decoding="async"></div>`;
}
// fade each thumbnail in once it has drawn
document.addEventListener("load", (e) => {
  if (e.target.tagName === "IMG" && e.target.dataset.thumb != null) { e.target.classList.add("ld"); e.target.parentElement?.classList.add("ld"); }
}, true);
const thumbTimers = {};
/// New versions (a new song, changed settings): swap each picture once the new one has loaded, a beat after the last change.
function applyThumbs(map) {
  for (const [id, v] of Object.entries(map || {})) {
    if (S.thumbs[id] === v) continue;
    S.thumbs[id] = v;
    if (S.shown[id] == null) continue;
    clearTimeout(thumbTimers[id]);
    thumbTimers[id] = setTimeout(() => {
      const want = S.thumbs[id], url = thumbURL(id, want), img = new Image();
      img.onload = () => {
        if (S.thumbs[id] !== want) return;
        S.shown[id] = want;
        document.querySelectorAll(`img[data-thumb="${CSS.escape(id)}"]`).forEach((el) => { el.src = url; });
      };
      img.src = url;
    }, 900);
  }
}

// ================================================================== segmented controls

function segThumb(seg, instant) {
  let t = seg.querySelector(":scope > .thumb");
  const on = seg.querySelector(":scope > button.on");
  if (!t) { t = document.createElement("i"); t.className = "thumb"; seg.prepend(t); instant = true; }
  if (!on || !on.offsetWidth) { t.style.width = "0"; return; }
  if (instant) seg.classList.add("instant");
  t.style.width = on.offsetWidth + "px";
  t.style.transform = `translateX(${on.offsetLeft}px)`;
  if (instant) requestAnimationFrame(() => requestAnimationFrame(() => seg.classList.remove("instant")));
}
const segObserver = new ResizeObserver((entries) => entries.forEach((e) => segThumb(e.target, true)));
function wireSeg(seg) { if (!seg._wired) { seg._wired = true; segObserver.observe(seg); } segThumb(seg, true); }
function setSeg(seg, pred) { [...seg.querySelectorAll(":scope > button")].forEach((b) => b.classList.toggle("on", pred(b))); segThumb(seg); }

// ================================================================== top bar

function renderTop() {
  const tr = S.state?.track, sample = isSample();
  $("np").innerHTML = `<span class="art" style="background-image:url('${esc(tr?.cover || "/ui/sample-cover.jpg")}')"></span>
    <span class="tx"><span class="t">${esc(sample ? "Nothing playing" : tr.title)}</span>
    <span class="a" id="npSub">${esc(sample ? "Previewing a sample song" : `${tr.artist} · ${fmt(position())}`)}</span></span>`;
  $("share").disabled = sample;
  reportTitlebarHoles();
}
function tickElapsed() {
  const sub = $("npSub");
  if (sub && !isSample() && S.visible) sub.textContent = `${S.state.track.artist} · ${fmt(position())}`;
}
setInterval(tickElapsed, 1000);

function setBackground() {
  const tr = S.state?.track;
  if (!tr) return;
  const url = `/coverblur/150/1.3/${enc(tr.coverKey || tr.id || "sample")}.jpg`;
  if (setBackground.url === url) return;
  setBackground.url = url;
  const a = $("bgA"), b = $("bgB"), next = a.classList.contains("on") ? b : a, prev = next === a ? b : a;
  const img = new Image();
  img.onload = () => { next.style.backgroundImage = `url("${url}")`; next.classList.add("on"); prev.classList.remove("on"); };
  img.src = url;
}

function reportTitlebarHoles() {
  const rects = [...$("topbar").querySelectorAll("button")].filter((el) => el.offsetParent).map((el) => {
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  });
  post({ type: "titlebarHoles", rects });
}
new ResizeObserver(reportTitlebarHoles).observe($("topbar"));

// ================================================================== tabs

function openTab(name, quiet) {
  if (name === "gallery") { S.tab = "wallpaper"; S.view = "gallery"; }
  else if (name === "wallpaper") { S.tab = "wallpaper"; if (!quiet) S.view = "stage"; }
  else S.tab = name;
  if (!quiet) renderTabs();
}
function renderTabs() {
  for (const sec of document.querySelectorAll("main > .tab")) sec.hidden = sec.id !== "tab-" + S.tab;
  $("stageView").hidden = S.view !== "stage";
  $("galleryView").hidden = S.view !== "gallery";
  setSeg($("tabs"), (b) => b.dataset.tab === S.tab);
  $("tabs").querySelectorAll("button").forEach((b) => b.setAttribute("aria-selected", b.dataset.tab === S.tab));
  if (S.tab === "history") loadHistory();
  if (S.tab === "wallpaper" && S.view === "stage") requestAnimationFrame(layoutStage);
  if (S.tab === "wallpaper" && S.view === "gallery") { renderGallery(); }
  if (S.tab === "displays") { renderDisplays(); requestAnimationFrame(layoutScreens); }
  if (S.tab === "lyrics") { renderLyrics(); scrollLines(true); }
  if (S.tab === "settings") renderSettings();
  updatePause();
}
$("tabs").addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) { closeSheet(); openTab(b.dataset.tab); } });

// ================================================================== live previews

/// Loads a template into a preview iframe, sized like a real screen and scaled to fit its box.
function loadFrame(frame, id, onload) {
  frame.classList.remove("ready");
  frame.onload = () => { onload(); frame.classList.add("ready"); updatePause(); };
  frame.src = `/template/${enc(id)}/index.html?preview=1&t=${Date.now()}`;
}
function screenFor(target) {
  const d = target === "all" ? mainDisplay() : S.displays.find((x) => x.id === target);
  return d ? { width: d.width, height: d.height, scale: d.scale || 2 } : S.state?.screen || { width: 1512, height: 982, scale: 2 };
}
function sendLive(frame, id) {
  if (!frame?.contentWindow || !S.state || !id) return;
  frame.contentWindow.postMessage({ type: "sw:live", payload: { ...S.state, screen: screenFor(S.target), params: S.values[id] || {} } }, "*");
}
function fitFrame(frame, box) {
  const scr = screenFor(S.target), k = Math.min(box.width / scr.width, box.height / scr.height);
  Object.assign(frame.style, { width: scr.width + "px", height: scr.height + "px",
    transform: `translate(${(box.width - scr.width * k) / 2}px, ${(box.height - scr.height * k) / 2}px) scale(${k})` });
}
function loadStage(force) {
  const f = $("preview");
  if (!S.stageID) return;
  if (!force && f.dataset.id === S.stageID) { sendStage(); return; }
  f.dataset.id = S.stageID;
  loadFrame(f, S.stageID, () => { layoutStage(); sendStage(); });
}
const sendStage = () => sendLive($("preview"), S.stageID);
function renderLive() {
  renderTop();
  sendStage();
  if (S.sheet) { sendLive(sheetFrame(), S.sheet); renderSheetHead(); }
  renderStageInsp();
  renderShelf();
  renderTarget();
  $("sampleNote").hidden = !isSample();
  if (S.tab === "displays") renderDisplays();
  if (S.tab === "lyrics") renderLyrics();
  if (S.tab === "settings") renderSettings();
  if (S.tab === "wallpaper" && S.view === "gallery") renderGallery();
}
function clock(c) {
  if (!S.state?.track || S.state.track.id === "sample") return;
  Object.assign(S.state.track, c);
  for (const f of liveFrames()) f.contentWindow?.postMessage({ type: "sw:clock", clock: c }, "*");
}
const sheetFrame = () => $("sheetPv").querySelector("iframe");
function liveFrames() { return [$("preview"), sheetFrame()].filter(Boolean); }
/// Only one live template runs, and only while it can be seen.
function updatePause() {
  const stageOn = S.visible && S.tab === "wallpaper" && S.view === "stage" && !S.sheet;
  const pairs = [[$("preview"), stageOn], [sheetFrame(), S.visible && !!S.sheet]];
  for (const [f, run] of pairs) { try { f?.contentWindow?.__sw?.pause(!run); } catch (e) {} }
}

// ================================================================== Stage

function layoutStage() {
  const stage = $("stage"), pv = $("pv"), ins = $("insp");
  const W = stage.clientWidth, H = stage.clientHeight;
  if (!W || !H) return;
  const scr = screenFor(S.target), k = Math.min(W / scr.width, H / scr.height);
  const w = Math.round(scr.width * k), h = Math.round(scr.height * k), top = Math.round((H - h) / 2);
  // keep the wallpaper clear of the inspector when there's room; otherwise the inspector floats over its edge
  const insW = ins.offsetWidth || 282, room = W - w - insW - 16;
  const left = Math.round(room >= 0 ? Math.min((W - w) / 2, room / 2 + 0) : Math.max(0, (W - w) / 2));
  Object.assign(pv.style, { left: left + "px", top: top + "px", width: w + "px", height: h + "px" });
  fitFrame($("preview"), { width: w, height: h });
  const insRight = room >= 0 ? Math.max(0, W - (left + w) - 16 - insW) : W - (left + w) + 12;
  Object.assign(ins.style, { right: insRight + "px", top: top + (room >= 0 ? 0 : 12) + "px", maxHeight: (room >= 0 ? h : h - 24) + "px" });
}
new ResizeObserver(() => { if (!$("stageView").hidden) layoutStage(); }).observe($("stage"));

function renderTarget() {
  const box = $("target");
  if (S.displays.length < 2) { box.hidden = true; return; }
  box.hidden = false;
  const opts = [["all", "All screens"], ...S.displays.map((d) => [d.id, displayName(d)])];
  setHTML(box, opts.map(([v, n]) => `<button type="button" data-v="${v}">${esc(n)}</button>`).join(""));
  wireSeg(box);
  setSeg(box, (b) => String(b.dataset.v) === String(S.target));
}
$("target").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-v]");
  if (!b) return;
  S.target = b.dataset.v === "all" ? "all" : +b.dataset.v;
  if (S.stageFollows) S.stageID = currentFor(S.target);
  renderTarget();
  loadStage();
  layoutStage();
  sendStage();
  renderStageInsp();
  renderShelf();
});

function selectStage(id) {
  if (!tpl(id)) return;
  S.stageID = id;
  S.stageFollows = id === currentFor(S.target);
  S.moreOpen = false;
  loadStage();
  renderStageInsp();
  renderShelf();
}

function renderStageInsp() {
  renderInspector($("insp"), S.stageID, { floating: true });
}

/// Activate a template on the stage's target (all screens, or one).
function use(id, target = S.target) {
  post({ type: "activate", id, display: target === "all" ? null : target });
  // optimistic: the app answers with fresh state
  if (target === "all") { S.defaultID = id; S.displays.forEach((d) => (d.template = id)); S.overrides = {}; }
  else { const d = S.displays.find((x) => x.id === target); if (d) d.template = id; }
  S.recents = [id, ...S.recents.filter((x) => x !== id)];
  if (id === S.stageID) S.stageFollows = true;
  const where = target === "all" ? (S.displays.length > 1 ? "on every screen" : "") : `on ${displayName(S.displays.find((d) => d.id === target))}`;
  toast(`${tpl(id)?.name} is your wallpaper ${where}`.trim());
  renderLive();
}

// ---------- inspector (stage, sheet, displays) ----------

/** Which settings show up front: a couple of colours, choices and sizes; the rest go under "More". */
function primaryKeys(params) {
  const want = [["color", 2], ["choice", 2], ["number", 1], ["font", 1]], picked = new Set();
  const kind = (p) => p.type === "color" ? "color" : p.type === "font" ? "font" : (p.type === "number" || p.type === "int") && !smallInt(p) ? "number"
    : (p.type === "select" || p.type === "bool" || smallInt(p)) ? "choice" : "other";
  for (const [k, n] of want) {
    let c = 0;
    for (const p of params) { if (picked.size >= 6 || c >= n) break; if (kind(p) === k && !picked.has(p.key)) { picked.add(p.key); c++; } }
  }
  return picked;
}
const smallInt = (p) => p.type === "int" && p.max != null && p.min != null && p.max - p.min <= 4;

function renderInspector(box, id, opt = {}) {
  const t = tpl(id);
  if (!t) { box.innerHTML = ""; return; }
  const partly = S.target === "all" && S.displays.length > 1 && onScreens(id).length > 0;
  const use = opt.noUse ? "" : inUse(id) ? `<button type="button" class="mbtn on use" data-act="use" aria-pressed="true">In use</button>`
    : `<button type="button" class="mbtn pri use" data-act="use">${partly ? "Use on all screens" : "Use as wallpaper"}</button>`;
  const head = opt.head ?? `<div class="insp-head"><div class="ttl"><h4>${esc(t.name)}</h4><span class="lbl">${esc(catLabel(t))}</span></div>
      ${opt.floating ? `<button type="button" class="ibtn ghost sm" data-act="collapse" title="${S.collapsed ? "Show settings" : "Hide settings"}" aria-label="${S.collapsed ? "Show settings" : "Hide settings"}">${S.collapsed ? ICON.expand : ICON.collapse}</button>` : ""}</div>`;
  let body = "";
  if (t.builder) {
    body = `<div class="msg">Made in the Template Builder. Open it there to change the design.<br><button type="button" class="mbtn sm" data-act="builder">Open in Builder</button></div>`;
  } else if (!t.params.length) {
    body = `<div class="msg">This template has no settings.</div>`;
  } else {
    const prim = primaryKeys(t.params), vals = S.values[id] || {};
    const val = (p) => (vals[p.key] !== undefined ? vals[p.key] : p.default);
    const front = t.params.filter((p) => prim.has(p.key)), rest = t.params.filter((p) => !prim.has(p.key));
    body = front.map((p) => fieldHTML(p, val(p))).join("");
    if (rest.length) {
      body += `<button type="button" class="more-btn" data-act="more" aria-expanded="${S.moreOpen}">${ICON.chev}<span>More settings · ${rest.length}</span></button>
        <div class="more ${S.moreOpen ? "open" : ""}"><div>${rest.map((p) => fieldHTML(p, val(p))).join("")}</div></div>`;
    }
  }
  const foot = `<div class="insp-foot">${opt.footExtra || ""}
    ${!t.builder && t.params.length ? `<button type="button" class="mbtn sm" data-act="reset" title="Reset to defaults">Reset</button>` : ""}
    <button type="button" class="ibtn ghost sm" data-act="menu" aria-haspopup="menu" title="More actions" aria-label="More actions">${ICON.more}</button>
    ${use}</div>`;
  const keepScroll = box.querySelector(".insp-body")?.scrollTop || 0;
  box.dataset.id = id;
  box.classList.toggle("collapsed", !!(opt.floating && S.collapsed));
  box.innerHTML = head + (opt.between || "") + `<div class="insp-body">${body}</div>` + foot;
  const b = box.querySelector(".insp-body");
  if (b && box._lastID === id) b.scrollTop = keepScroll;
  box._lastID = id;
  box._opt = opt;
  box.querySelectorAll(".seg").forEach(wireSeg);
  box.querySelectorAll("input[type=range]").forEach(paintRange);
}

function fieldHTML(p, v) {
  const label = esc(p.label || p.key), key = esc(p.key);
  if (p.type === "color") {
    const { html, text } = swatches(p, v);
    return `<div class="field" data-key="${key}" data-type="color"><div class="fl"><span class="lbl">${label}</span><span class="val">${esc(text)}</span></div><div class="sw">${html}</div></div>`;
  }
  if (p.type === "bool") {
    return `<div class="field" data-key="${key}" data-type="bool"><div class="fl"><span class="lbl">${label}</span></div>
      <div class="seg fill" role="radiogroup" aria-label="${label}"><button type="button" data-v="0" class="${!v ? "on" : ""}">Off</button><button type="button" data-v="1" class="${v ? "on" : ""}">On</button></div></div>`;
  }
  if (smallInt(p)) {
    const opts = []; for (let i = p.min; i <= p.max; i++) opts.push(i);
    return `<div class="field" data-key="${key}" data-type="int"><div class="fl"><span class="lbl">${label}</span></div>
      <div class="seg fill" role="radiogroup" aria-label="${label}">${opts.map((o) => `<button type="button" data-v="${o}" class="${+v === o ? "on" : ""}">${o}</button>`).join("")}</div></div>`;
  }
  if (p.type === "number" || p.type === "int") {
    const min = p.min ?? 0, max = p.max ?? 100, step = p.type === "int" ? 1 : p.step ?? 0.1;
    return `<div class="field" data-key="${key}" data-type="${p.type}"><div class="fl"><span class="lbl">${label}</span><span class="val">${esc(numText(p, v))}</span></div>
      <input type="range" min="${min}" max="${max}" step="${step}" value="${esc(v)}" aria-label="${label}"></div>`;
  }
  if (p.type === "select") {
    const opts = (p.options || []).map((o) => (typeof o === "string" ? { value: o, label: o } : o));
    const short = opts.length <= 4 && opts.reduce((n, o) => n + String(o.label).length, 0) <= 26 && opts.every((o) => String(o.label).length <= 12);
    if (short) {
      return `<div class="field" data-key="${key}" data-type="select"><div class="fl"><span class="lbl">${label}</span></div>
        <div class="seg fill" role="radiogroup" aria-label="${label}">${opts.map((o) => `<button type="button" data-v="${esc(o.value)}" class="${String(v) === String(o.value) ? "on" : ""}">${esc(o.label)}</button>`).join("")}</div></div>`;
    }
    return `<div class="field" data-key="${key}" data-type="select"><div class="fl"><span class="lbl">${label}</span></div>
      <label class="dd"><select aria-label="${label}">${opts.map((o) => `<option value="${esc(o.value)}" ${String(v) === String(o.value) ? "selected" : ""}>${esc(o.label)}</option>`).join("")}</select></label></div>`;
  }
  if (p.type === "font") {
    const fonts = Object.keys(window.Wallpaper?.fonts || { [v]: "" });
    if (!fonts.includes(v)) fonts.unshift(v);
    const fam = window.Wallpaper?.fonts?.[v] || "inherit";
    return `<div class="field" data-key="${key}" data-type="font"><div class="fl"><span class="lbl">${label}</span></div>
      <label class="dd"><select aria-label="${label}" style="font-family:${esc(fam)}">${fonts.map((f) => `<option value="${esc(f)}" ${f === v ? "selected" : ""}>${esc(f)}</option>`).join("")}</select></label></div>`;
  }
  return `<div class="field" data-key="${key}" data-type="text"><div class="fl"><span class="lbl">${label}</span></div><input class="txt" type="text" value="${esc(v ?? "")}" aria-label="${label}"></div>`;
}

function numText(p, v) {
  const n = +v, step = p.type === "int" ? 1 : p.step ?? 0.1;
  const dec = Math.max(0, Math.min(3, (String(step).split(".")[1] || "").length));
  return n.toFixed(dec) + (p.unit ? (p.unit === "%" ? "%" : " " + p.unit) : "");
}
function paintRange(r) { const min = +r.min, max = +r.max; r.style.setProperty("--p", ((+r.value - min) / (max - min || 1)) * 100 + "%"); }

/** Auto colours (follow each cover), this cover's palette, and a custom picker. */
function swatches(p, v) {
  const colors = S.state?.colors || {}, autos = window.Wallpaper?.autoColors || Object.keys(AUTO_LABELS);
  const resolved = (x) => (typeof x === "string" && x.startsWith("auto:") ? colors[x.slice(5)] || "#888888" : x);
  const seen = new Set(), list = [];
  const def = typeof p.default === "string" && p.default.startsWith("auto:") ? p.default.slice(5) : null;
  const order = [...new Set([def, typeof v === "string" && v.startsWith("auto:") ? v.slice(5) : null, ...autos].filter(Boolean))];
  for (const a of order) {
    const hex = String(colors[a] || "").toUpperCase();
    if (!hex || (seen.has(hex) && "auto:" + a !== v)) continue;
    seen.add(hex); list.push(`<button type="button" class="auto ${v === "auto:" + a ? "on" : ""}" data-v="auto:${a}" style="background:${hex}" title="Auto · ${AUTO_LABELS[a] || a} (follows each cover)" aria-label="Auto ${AUTO_LABELS[a] || a}"></button>`);
    if (list.length >= 5) break;
  }
  const pal = (colors.palette || []).map((x) => String(x).toUpperCase()).filter((x) => !seen.has(x)).slice(0, 3);
  const isAuto = typeof v === "string" && v.startsWith("auto:");
  const vHex = isAuto ? "" : String(v || "").toUpperCase();
  let html = list.join("");
  if (pal.length) html += `<span class="div"></span>` + pal.map((x) => `<button type="button" class="${vHex === x ? "on" : ""}" data-v="${x}" style="background:${x}" title="${x} from this cover" aria-label="${x}"></button>`).join("");
  const custom = !isAuto && !pal.includes(vHex) && /^#[0-9A-F]{6}$/.test(vHex);
  html += `<button type="button" class="custom ${custom ? "on has" : ""}" title="Custom colour" aria-label="Custom colour">${custom ? `<i style="background:${vHex}"></i>` : ""}<input type="color" value="${/^#[0-9A-F]{6}$/.test(resolved(v)?.toUpperCase?.() || "") ? resolved(v).toLowerCase() : "#888888"}" tabindex="-1"></button>`;
  const text = isAuto ? `Auto · ${AUTO_LABELS[v.slice(5)] || v.slice(5)}` : vHex;
  return { html, text };
}

function setParam(id, key, value, rerender = true) {
  (S.values[id] = S.values[id] || {})[key] = value;
  post({ type: "setParam", id, key, value });
  if (id === S.stageID) sendStage();
  if (id === S.sheet) sendLive(sheetFrame(), id);
  if (rerender) rerenderInspectors(id);
}
function rerenderInspectors(id) {
  for (const box of document.querySelectorAll(".insp")) if (box.dataset.id === id && box._opt) renderInspector(box, id, box._opt);
}

// one set of handlers for every inspector
document.addEventListener("click", (e) => {
  const box = e.target.closest(".insp");
  if (!box) return;
  const id = box.dataset.id, act = e.target.closest("[data-act]");
  if (act) {
    const a = act.dataset.act;
    if (a === "use") { if (!inUse(id)) use(id); }
    else if (a === "reset") { post({ type: "reset", id }); delete S.values[id]; sendStage(); toast("Back to the defaults"); }
    else if (a === "builder") post({ type: "openBuilder", id });
    else if (a === "collapse") { S.collapsed = !S.collapsed; renderStageInsp(); }
    else if (a === "more") {
      S.moreOpen = !S.moreOpen;
      act.setAttribute("aria-expanded", S.moreOpen);
      act.nextElementSibling?.classList.toggle("open", S.moreOpen);
      act.nextElementSibling?.querySelectorAll(".seg").forEach((s) => segThumb(s, true));
    }
    else if (a === "menu") templateMenu(id, act);
    else if (a === "same") sameOnAll();
    else if (a === "toStage") { selectStage(act.dataset.id); openTab("wallpaper"); }
    return;
  }
  const field = e.target.closest(".field");
  if (!field) return;
  const key = field.dataset.key, type = field.dataset.type, b = e.target.closest("button[data-v]");
  if (!b) return;
  if (type === "color") setParam(id, key, b.dataset.v);
  else if (type === "bool") { setSeg(b.parentElement, (x) => x === b); setParam(id, key, b.dataset.v === "1", false); }
  else if (type === "int") { setSeg(b.parentElement, (x) => x === b); setParam(id, key, +b.dataset.v, false); }
  else if (type === "select") { setSeg(b.parentElement, (x) => x === b); setParam(id, key, b.dataset.v, false); }
});
document.addEventListener("input", (e) => {
  const box = e.target.closest(".insp"), field = e.target.closest(".field");
  if (!box || !field) return;
  const id = box.dataset.id, key = field.dataset.key, type = field.dataset.type, t = tpl(id);
  const p = t?.params.find((x) => x.key === key);
  if (!p) return;
  if (e.target.type === "range") {
    paintRange(e.target);
    const v = type === "int" ? Math.round(+e.target.value) : +e.target.value;
    field.querySelector(".val").textContent = numText(p, v);
    setParam(id, key, v, false);
  } else if (e.target.type === "color") {
    const v = e.target.value.toUpperCase();
    const c = e.target.closest(".custom");
    c.classList.add("on", "has");
    if (!c.querySelector("i")) c.prepend(document.createElement("i"));
    c.querySelector("i").style.background = v;
    field.querySelectorAll(".sw button").forEach((x) => x.classList.toggle("on", x === c));
    field.querySelector(".val").textContent = v;
    setParam(id, key, v, false);
  } else if (e.target.classList.contains("txt")) {
    setParam(id, key, e.target.value, false);
  }
});
document.addEventListener("change", (e) => {
  const box = e.target.closest(".insp"), field = e.target.closest(".field");
  if (!box || !field || e.target.tagName !== "SELECT") return;
  if (field.dataset.type === "font") e.target.style.fontFamily = window.Wallpaper?.fonts?.[e.target.value] || "inherit";
  setParam(box.dataset.id, field.dataset.key, e.target.value, false);
});

function templateMenu(id, anchor) {
  const t = tpl(id);
  const items = [];
  if (t.builder) items.push(["Open in Template Builder", () => post({ type: "openBuilder", id })]);
  else items.push([t.builtin ? "Duplicate & edit code" : "Duplicate", () => post({ type: "duplicate", id })]);
  if (!t.builtin && !t.builder) items.push(["Show code in Finder", () => post({ type: "openFolder", id })]);
  items.push([`Export “${t.name}”…`, () => post({ type: "exportTemplate", id })]);
  items.push([S.favorites.has(id) ? "Remove from favourites" : "Add to favourites", () => toggleFavorite(id)]);
  if (!t.builder && t.params.length) items.push(["Reset to defaults", () => { post({ type: "reset", id }); delete S.values[id]; sendStage(); }]);
  if (!t.builtin) items.push(null, ["Move to Trash…", () => post({ type: "delete", id }), "danger"]);
  openMenu(anchor, items);
}

// ================================================================== shelf

function shelfIDs() {
  const ids = [];
  const add = (id) => { if (tpl(id) && !ids.includes(id)) ids.push(id); };
  add(currentFor(S.target));
  [...S.favorites].forEach(add);
  S.recents.forEach(add);
  for (const t of S.templates) { if (ids.length >= 12) break; add(t.id); }
  return ids;
}
function pickHTML(id, { on, live, star = true, cat = false, drag = false } = {}) {
  const t = tpl(id), fav = S.favorites.has(id);
  return `<button type="button" class="pick ${on ? "on" : ""}" data-id="${esc(id)}" ${drag ? 'draggable="true"' : ""} aria-label="${esc(t.name)}${live ? ", in use" : ""}">
    <span class="tw">${thumb(id)}${live ? `<span class="live">In use</span>` : ""}
    ${star ? `<span class="star ${fav ? "on" : ""}" role="button" tabindex="0" data-star="${esc(id)}" title="${fav ? "Remove from favourites" : "Add to favourites"}" aria-label="${fav ? "Remove from favourites" : "Add to favourites"}" aria-pressed="${fav}">${fav ? ICON.starOn : ICON.star}</span>` : ""}</span>
    <span class="name"><b>${esc(t.name)}</b>${cat ? `<em>${esc(catLabel(t))}</em>` : ""}</span></button>`;
}
/// As many cards as fit the width, the last one "Browse all".
function shelfCapacity() {
  const W = $("shelf").clientWidth || 1100, gap = 14, min = 132;
  return Math.max(3, Math.floor((W + gap) / (min + gap)));
}
function renderShelf() {
  const cap = shelfCapacity();
  $("shelf").style.setProperty("--n", cap);
  let ids = shelfIDs().slice(0, cap - 1);
  if (S.stageID && !ids.includes(S.stageID)) ids = [...ids.slice(0, cap - 2), S.stageID];
  const sample = S.templates.filter((t) => !ids.includes(t.id)).slice(0, 4).map((t) => t.id);
  while (sample.length < 4 && S.templates[sample.length]) sample.push(S.templates[sample.length].id);
  const browse = `<button type="button" class="pick browse" data-browse aria-label="Browse all ${S.templates.length} templates"><div class="th ld">${sample.map((id) => `<span><img data-thumb="${esc(id)}" src="${thumbURL(id)}" alt="" loading="lazy"></span>`).join("")}<b>Browse all · ${S.templates.length}</b></div><span class="name"><b>All templates</b></span></button>`;
  sample.forEach((id) => { if (S.shown[id] == null) S.shown[id] = S.thumbs[id] ?? "0"; });
  setHTML($("shelf"), ids.map((id) => pickHTML(id, { on: id === S.stageID, live: shownOn(id) })).join("") + browse);
}
$("shelf").addEventListener("click", (e) => {
  if (e.target.closest("[data-star]")) return;
  if (e.target.closest("[data-browse]")) return showGallery();
  const p = e.target.closest(".pick");
  if (p) selectStage(p.dataset.id);
});
$("shelf").addEventListener("dblclick", (e) => { const p = e.target.closest(".pick[data-id]"); if (p) use(p.dataset.id); });
$("browseLink").onclick = () => showGallery();
new ResizeObserver(() => { const c = shelfCapacity(); if (c !== $("shelf")._cap) { $("shelf")._cap = c; renderShelf(); } }).observe($("shelf"));

function toggleFavorite(id) {
  const on = !S.favorites.has(id);
  on ? S.favorites.add(id) : S.favorites.delete(id);
  post({ type: "favorite", id, on });
  toast(on ? `Added ${tpl(id).name} to favourites` : `Removed ${tpl(id).name} from favourites`);
  renderShelf();
  if (S.view === "gallery") renderGallery();
  if (S.tab === "displays") renderTray();
}
document.addEventListener("click", (e) => { const s = e.target.closest("[data-star]"); if (s) { e.stopPropagation(); e.preventDefault(); toggleFavorite(s.dataset.star); } }, true);
document.addEventListener("keydown", (e) => {
  const s = e.target.closest?.("[data-star]");
  if (s && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); e.stopPropagation(); toggleFavorite(s.dataset.star); }
}, true);

// ================================================================== gallery & crate

function showGallery(cat) {
  if (cat) S.cat = cat;
  S.view = "gallery";
  S.tab = "wallpaper";
  renderTabs();
}
$("back").onclick = () => { S.view = "stage"; renderTabs(); };

function filtered() { return S.templates.filter((t) => inCat(t, S.cat) && matches(t, S.query)); }

function renderGallery() {
  const counts = Object.fromEntries(CATS.map(([k]) => [k, S.templates.filter((t) => inCat(t, k)).length]));
  setHTML($("cats"), CATS.filter(([k]) => k !== "yours" || counts.yours || true).map(([k, n]) =>
    `<button type="button" class="cat ${S.cat === k ? "on" : ""}" data-cat="${k}" role="option" aria-selected="${S.cat === k}">${esc(n)} <span>${counts[k]}</span></button>`).join(""));
  const list = filtered(), crate = S.prefs.galleryMode === "crate";
  $("gTitle").textContent = S.query ? `“${S.query}”` : S.cat === "all" ? "All templates" : CAT_NAME[S.cat];
  $("gCount").textContent = list.length === 1 ? "1 template" : `${list.length} templates`;
  wireSeg($("mode"));
  setSeg($("mode"), (b) => b.dataset.mode === (crate ? "crate" : "grid"));
  $("gEmpty").hidden = list.length > 0;
  $("gridBox").hidden = crate || !list.length;
  $("crateBox").hidden = !crate || !list.length;
  if (!list.length) return;
  if (crate) return renderCrate(list);
  const cur = currentFor(S.target), hero = S.cat === "all" && !S.query && tpl(cur);
  $("hero").hidden = !hero;
  if (hero) {
    const t = tpl(cur), song = isSample() ? "the sample song" : `${S.state.track.title} by ${S.state.track.artist}`;
    setHTML($("hero"), `${thumb(cur)}<div><span class="lbl">On your desktop${S.displays.length > 1 && S.target !== "all" ? " · " + esc(displayName(S.displays.find((d) => d.id === S.target))) : ""}</span>
      <h3>${esc(t.name)}</h3><p>${esc(t.description)} Showing ${esc(song)}.</p>
      <div class="acts"><button type="button" class="mbtn" data-customize="${esc(cur)}">Customize</button></div></div>`);
  }
  setHTML($("cards"), list.filter((t) => !hero || t.id !== cur).map((t) => pickHTML(t.id, { cat: true, live: shownOn(t.id) })).join(""));
}
$("cats").addEventListener("click", (e) => { const c = e.target.closest("[data-cat]"); if (c) { S.cat = c.dataset.cat; S.crate = 0; renderGallery(); $("gmain").scrollTop = 0; } });
$("cards").addEventListener("click", (e) => { if (e.target.closest("[data-star]")) return; const p = e.target.closest(".pick"); if (p) openSheet(p.dataset.id); });
$("hero").addEventListener("click", (e) => { const c = e.target.closest("[data-customize]"); if (c) { selectStage(c.dataset.customize); S.view = "stage"; renderTabs(); } });
$("gmain").addEventListener("scroll", () => $("gmain").classList.toggle("scrolled", $("gmain").scrollTop > 4));
$("searchIc").innerHTML = ICON.search;
let searchTimer = 0;
$("search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { S.query = $("search").value.trim(); S.crate = 0; renderGallery(); }, 120); });
$("mode").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-mode]");
  if (!b) return;
  if (b.dataset.mode === "crate" && S.prefs.galleryMode !== "crate") S.crate = Math.max(0, filtered().findIndex((t) => t.id === currentFor(S.target)));
  S.prefs.galleryMode = b.dataset.mode;
  post({ type: "pref", key: "galleryMode", value: b.dataset.mode });
  renderGallery();
  if (b.dataset.mode === "crate") $("crate").focus({ preventScroll: true });
});
$("sideNew").onclick = () => post({ type: "newTemplate" });
$("sideImport").onclick = () => post({ type: "importTemplate" });

function renderCrate(list) {
  S.crate = Math.max(0, Math.min(S.crate, list.length - 1));
  const box = $("crate");
  const ids = list.map((t) => t.id).join("|");
  if (box._ids !== ids) {
    box._ids = ids;
    box.innerHTML = list.map((t, i) => `<button type="button" class="sleeve" data-i="${i}" data-id="${esc(t.id)}" tabindex="-1" aria-label="${esc(t.name)}">${thumb(t.id)}<div class="refl"><img data-thumb="${esc(t.id)}" src="${thumbURL(t.id)}" alt="" loading="lazy"></div></button>`).join("");
  }
  layoutCrate(list);
}
function layoutCrate(list = filtered()) {
  const box = $("crate");
  [...box.children].forEach((s, i) => {
    const d = i - S.crate, a = Math.abs(d), sg = Math.sign(d);
    const x = d === 0 ? 0 : sg * (30 + (a - 1) * 7);
    s.style.transform = `translate(calc(-50% + ${x}cqw), -54%) translateZ(${d === 0 ? 0 : -160 - a * 10}px) rotateY(${d === 0 ? 0 : -sg * 56}deg) scale(${d === 0 ? 1 : 0.86})`;
    s.style.zIndex = 100 - a;
    s.style.filter = d === 0 ? "none" : `brightness(${Math.max(0.3, 0.72 - a * 0.1)})`;
    s.style.opacity = a > 4 ? 0 : 1;
    s.classList.toggle("front", d === 0);
  });
  const t = list[S.crate];
  if (!t) return;
  const used = inUse(t.id);
  $("crateInfo").innerHTML = `<span class="lbl">${esc(catLabel(t))}</span><h3>${esc(t.name)}</h3><p>${esc(t.description)}</p>
    <div class="acts">${used ? `<button type="button" class="mbtn on" disabled>In use</button>` : `<button type="button" class="mbtn pri" data-crate-use>Use as wallpaper</button>`}
    <button type="button" class="mbtn" data-crate-open>Customize</button></div><div class="keys">← → flip · ↩ use · space customize</div>`;
}
$("crate").addEventListener("click", (e) => {
  const s = e.target.closest(".sleeve");
  if (!s) return;
  if (+s.dataset.i === S.crate) openSheet(s.dataset.id);
  else { S.crate = +s.dataset.i; layoutCrate(); }
});
$("crate").addEventListener("keydown", (e) => {
  const list = filtered();
  if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
    e.preventDefault();
    S.crate = Math.max(0, Math.min(list.length - 1, S.crate + (e.key === "ArrowRight" ? 1 : -1)));
    layoutCrate(list);
  } else if (e.key === "Enter" && list[S.crate]) { e.preventDefault(); use(list[S.crate].id); }
  else if (e.key === " " && list[S.crate]) { e.preventDefault(); openSheet(list[S.crate].id); }
});
$("crate").addEventListener("wheel", (e) => {
  const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
  const box = $("crate");
  box._acc = (box._acc || 0) + d;
  if (Math.abs(box._acc) < 60) return;
  const list = filtered();
  S.crate = Math.max(0, Math.min(list.length - 1, S.crate + Math.sign(box._acc)));
  box._acc = 0;
  layoutCrate(list);
}, { passive: true });
$("crateInfo").addEventListener("click", (e) => {
  const t = filtered()[S.crate];
  if (!t) return;
  if (e.target.closest("[data-crate-use]")) use(t.id);
  if (e.target.closest("[data-crate-open]")) openSheet(t.id);
});

// ================================================================== sheet

function openSheet(id) {
  if (!tpl(id)) return;
  S.sheet = id;
  S.moreOpen = false;
  const sheet = $("sheet");
  sheet.hidden = false;
  requestAnimationFrame(() => sheet.classList.add("open"));
  const scr = screenFor(S.target);
  $("sheetPv").style.aspectRatio = `${scr.width} / ${scr.height}`;
  $("sheetPv").innerHTML = thumb(id) + `<iframe title="Preview of ${esc(tpl(id).name)}" tabindex="-1"></iframe>`;
  renderSheetHead();
  loadSheetPreview();
  updatePause();
  setTimeout(() => sheet.querySelector(".use, .mbtn")?.focus({ preventScroll: true }), 60);
}
function loadSheetPreview() {
  const f = sheetFrame();
  if (!f) return;
  loadFrame(f, S.sheet, () => { fitSheet(); sendLive(f, S.sheet); });
  fitSheet();
}
function fitSheet() {
  const f = sheetFrame(), box = $("sheetPv");
  if (f) fitFrame(f, { width: box.clientWidth, height: box.clientHeight });
}
new ResizeObserver(fitSheet).observe($("sheetPv"));
function renderSheetHead() {
  const id = S.sheet, t = tpl(id);
  if (!t) return;
  let box = $("sheetCol").querySelector(".insp");
  if (!box) { $("sheetCol").innerHTML = `<div class="insp"></div>`; box = $("sheetCol").querySelector(".insp"); }
  const where = S.displays.length > 1 ? (S.target === "all" ? "All screens" : displayName(S.displays.find((d) => d.id === S.target))) : "";
  renderInspector(box, id, {
    head: `<div class="insp-head"><div class="ttl"><span class="lbl">${esc(catLabel(t))}${where ? " · " + esc(where) : ""}</span><h4 id="sheetName" style="margin-top:6px">${esc(t.name)}</h4></div>
      <button type="button" class="ibtn ghost sm" data-close title="Close (Esc)" aria-label="Close">${P('<path d="M4 4l8 8M12 4l-8 8"/>', 1.6)}</button></div>`,
    between: `<p class="desc">${esc(t.description)}</p>`,
  });
}
function closeSheet() {
  if (!S.sheet) return;
  const sheet = $("sheet"), id = S.sheet;
  S.sheet = null;
  sheet.classList.remove("open");
  setTimeout(() => { if (!S.sheet) { sheet.hidden = true; $("sheetPv").innerHTML = ""; $("sheetCol").innerHTML = ""; } }, 400);
  updatePause();
  document.querySelector(`.pick[data-id="${CSS.escape(id)}"]`)?.focus({ preventScroll: true });
}
$("sheet").addEventListener("click", (e) => { if (e.target === $("sheet") || e.target.closest("[data-close]")) closeSheet(); });

// ================================================================== Displays

function renderDisplays() {
  const can = $("canvas");
  const html = S.displays.map((d) => `<button type="button" class="screen ${d.main ? "main" : ""} ${d.id === S.disp ? "on" : ""}" data-d="${d.id}" aria-label="${esc(displayName(d))}, ${esc(tpl(d.template)?.name || "")}">
      ${thumb(d.template)}<span class="tag"><b>${esc(displayName(d))}</b> · ${esc(tpl(d.template)?.name || "")}</span></button>`).join("");
  setHTML(can, html);
  layoutScreens();
  $("dispHint").textContent = S.displays.length > 1 ? "Drag a template onto a screen, or select a screen and click one." : "Click a template to use it. With another display connected, each screen can have its own.";
  renderTray();
  renderDispInsp();
}
function layoutScreens() {
  const can = $("canvas"), W = can.clientWidth, H = can.clientHeight;
  if (!W || !H || !S.displays.length) return;
  const minX = Math.min(...S.displays.map((d) => d.x)), minY = Math.min(...S.displays.map((d) => d.y));
  const maxX = Math.max(...S.displays.map((d) => d.x + d.width)), maxY = Math.max(...S.displays.map((d) => d.y + d.height));
  const pad = 40, k = Math.min((W - pad * 2) / (maxX - minX), (H - pad * 2 - 30) / (maxY - minY), 0.32);
  const ox = (W - (maxX - minX) * k) / 2, oy = (H - 30 - (maxY - minY) * k) / 2;
  const gap = 6;  // arranged displays touch; leave a hairline between them
  for (const el of can.querySelectorAll(".screen")) {
    const d = S.displays.find((x) => x.id === +el.dataset.d);
    if (!d) continue;
    Object.assign(el.style, { left: ox + (d.x - minX) * k + gap / 2 + "px", top: oy + (d.y - minY) * k + gap / 2 + "px",
      width: d.width * k - gap + "px", height: d.height * k - gap + "px" });
  }
}
new ResizeObserver(() => { if (S.tab === "displays") layoutScreens(); }).observe($("canvas"));
function renderTray() {
  const d = S.displays.find((x) => x.id === S.disp);
  const ids = [...new Set([...S.favorites, ...S.recents, ...S.templates.map((t) => t.id)])].filter((id) => tpl(id));
  setHTML($("tray"), ids.map((id) => pickHTML(id, { on: d?.template === id, drag: true, star: false })).join(""));
}
function renderDispInsp() {
  const d = S.displays.find((x) => x.id === S.disp), box = $("dispInsp");
  if (!d) { box.innerHTML = ""; return; }
  const t = tpl(d.template), overridden = S.overrides[String(d.id)] != null || S.displays.some((x) => x.template !== d.template);
  const res = `${Math.round(d.width)} × ${Math.round(d.height)}${d.main ? " · menu bar" : ""}`;
  renderInspector(box, d.template, {
    noUse: true,
    head: `<div class="insp-head"><div class="ttl"><h4>${esc(displayName(d))}</h4><span class="lbl">${esc(res)}</span></div></div>`,
    between: `<div class="disp-tpl">${thumb(d.template)}<div><b>${esc(t?.name || "")}</b><span>Settings apply to this template on every screen</span></div></div>`,
    footExtra: "",
  });
  // displays-specific footer
  const foot = box.querySelector(".insp-foot");
  foot.innerHTML = S.displays.length > 1
    ? `<button type="button" class="mbtn wide" data-act="same" ${overridden ? "" : "disabled"}>Same on all screens</button>
       <span class="note">${overridden ? `Puts ${esc(t?.name || "this template")} on every screen.` : "Every screen shows the same template."}</span>`
    : `<button type="button" class="mbtn wide" data-act="toStage" data-id="${esc(d.template)}">Customize on the stage</button>`;
}
function sameOnAll() {
  const d = S.displays.find((x) => x.id === S.disp);
  if (d) use(d.template, "all");
}
function assign(displayID, id) {
  const d = S.displays.find((x) => x.id === displayID);
  if (!d || !tpl(id)) return;
  S.disp = displayID;
  if (d.template === id) { renderDisplays(); return; }
  use(id, S.displays.length > 1 ? displayID : "all");
}
$("canvas").addEventListener("click", (e) => { const s = e.target.closest(".screen"); if (s) { S.disp = +s.dataset.d; renderDisplays(); } });
$("canvas").addEventListener("keydown", (e) => {
  if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
  const i = S.displays.findIndex((d) => d.id === S.disp), n = S.displays[(i + (e.key === "ArrowRight" ? 1 : S.displays.length - 1)) % S.displays.length];
  if (n) { S.disp = n.id; renderDisplays(); $("canvas").querySelector(`[data-d="${n.id}"]`)?.focus(); }
});
$("tray").addEventListener("click", (e) => { const p = e.target.closest(".pick"); if (p && S.disp != null) assign(S.disp, p.dataset.id); });
$("tray").addEventListener("dragstart", (e) => {
  const p = e.target.closest(".pick");
  if (!p) return;
  e.dataTransfer.setData("text/plain", p.dataset.id);
  e.dataTransfer.effectAllowed = "copy";
  p.classList.add("dragging");
});
$("tray").addEventListener("dragend", (e) => { e.target.closest(".pick")?.classList.remove("dragging"); clearDrop(); });
const clearDrop = () => $("canvas").querySelectorAll(".screen").forEach((x) => x.classList.remove("drop"));
$("canvas").addEventListener("dragover", (e) => {
  const s = e.target.closest(".screen");
  if (!s) return clearDrop();
  e.preventDefault();
  e.dataTransfer.dropEffect = "copy";
  $("canvas").querySelectorAll(".screen").forEach((x) => x.classList.toggle("drop", x === s));
});
$("canvas").addEventListener("dragleave", (e) => { if (!$("canvas").contains(e.relatedTarget)) clearDrop(); });
$("canvas").addEventListener("drop", (e) => {
  const s = e.target.closest(".screen"), id = e.dataTransfer.getData("text/plain");
  clearDrop();
  if (!s || !tpl(id)) return;
  e.preventDefault();
  assign(+s.dataset.d, id);
});

// ================================================================== History

const historyFrame = () => $("historyFrame");
function loadHistory() {
  const f = historyFrame();
  if (!f.src) f.src = "history.html?embed=1";
}

// ================================================================== Lyrics

function renderLyrics() {
  const L = S.lyrics || { sources: [], choice: "Combined", offset: 0 }, tr = S.state?.track, sample = isSample();
  $("lyrNow").innerHTML = `<span class="art" style="background-image:url('${esc(tr?.cover || "/ui/sample-cover.jpg")}')"></span><div style="min-width:0">
    <b>${esc(sample ? "Nothing playing" : tr.title)}</b><span>${esc(sample ? "Play a song in Spotify to set its lyrics." : tr.artist)}</span>
    <span>${esc(sample ? "" : L.from ? "Lyrics from " + L.from : "No lyrics found for this song")}</span></div>`;
  const synced = L.sources.filter((s) => s.synced).length, none = !L.sources.length;
  const rows = [{ v: "Combined", name: "Combined", sub: synced > 1 ? `Consensus timing from ${synced} synced sources` : "The best source available", badge: "" },
    ...L.sources.map((s) => ({ v: s.name, name: s.name, sub: "", badge: s.synced ? `<span class="badge sync">Synced</span>` : `<span class="badge">Unsynced</span>` }))];
  setHTML($("sources"), rows.map((r) => `<button type="button" class="src ${L.choice === r.v ? "on" : ""}" role="radio" aria-checked="${L.choice === r.v}" data-v="${esc(r.v)}" ${none ? "disabled" : ""}>
    <span class="dot"></span><span style="min-width:0"><b>${esc(r.name)}</b>${r.sub ? `<small>${esc(r.sub)}</small>` : ""}</span>${r.badge}</button>`).join("")
    + (none ? `<p class="note" style="margin:6px 4px 2px">${sample ? "Sources appear here while a song plays." : "No source has lyrics for this song. Try Search again."}</p>` : ""));
  const off = +L.offset || 0;
  $("offset").textContent = off === 0 ? "0.0 s" : `${off > 0 ? "+" : "−"}${Math.abs(off).toFixed(off * 10 % 1 ? 2 : 1)} s`;
  $("offsetNote").textContent = off === 0 ? "As published" : off > 0 ? "Lines show later than published" : "Lines show earlier than published";
  $("resetTiming").hidden = off === 0;
  for (const b of ["earlier", "later"]) $(b).disabled = none;
  $("refetch").disabled = sample;
  // the song's lines, with the one being sung lit
  const lines = S.state?.lyrics?.lines || [];
  const key = (tr?.id || "") + "|" + lines.length + "|" + (lines[0]?.t ?? "") + "|" + off;
  if ($("lines")._key !== key) {
    $("lines")._key = key;
    $("lines").innerHTML = lines.length ? lines.map((l, i) => `<p data-i="${i}">${esc(l.text || "♪")}${l.translation ? `<small>${esc(l.translation)}</small>` : ""}</p>`).join("")
      : `<p class="none">${sample ? "The lyrics of what's playing show here." : "No lyrics for this song."}</p>`;
    $("lines")._idx = null;
  }
  $("linesNote").textContent = S.state?.lyrics?.synced === false && lines.length ? "Unsynced" : "";
  scrollLines();
}
function scrollLines(instant) {
  const box = $("lines"), lines = S.state?.lyrics?.lines || [];
  if (!lines.length || S.tab !== "lyrics") return;
  const pos = isSample() ? null : position() + 0.1;
  let idx = isSample() ? S.state.lyrics.index : -1;
  if (pos != null) for (let i = 0; i < lines.length; i++) { if (lines[i].t <= pos) idx = i; else break; }
  if (box._idx === idx && !instant) return;
  box._idx = idx;
  box.querySelectorAll("p[data-i]").forEach((p) => { const i = +p.dataset.i; p.classList.toggle("now", i === idx); p.classList.toggle("past", i < idx); });
  const cur = box.querySelector(`p[data-i="${Math.max(0, idx)}"]`);
  if (cur) box.scrollTo({ top: cur.offsetTop - box.clientHeight * 0.4, behavior: instant || reduced ? "auto" : "smooth" });
}
setInterval(() => { if (S.visible && S.tab === "lyrics") scrollLines(); }, 250);
$("sources").addEventListener("click", (e) => {
  const b = e.target.closest(".src");
  if (!b || b.disabled) return;
  S.lyrics.choice = b.dataset.v;
  post({ type: "lyricsSource", value: b.dataset.v });
  renderLyrics();
});
const nudge = (d) => { S.lyrics.offset = Math.round(((+S.lyrics.offset || 0) + d) * 100) / 100; post({ type: "lyricsNudge", delta: d }); renderLyrics(); };
$("earlier").onclick = () => nudge(-0.5);
$("later").onclick = () => nudge(0.5);
$("resetTiming").onclick = () => { S.lyrics.offset = 0; post({ type: "lyricsReset" }); renderLyrics(); };
$("refetch").onclick = () => { post({ type: "lyricsRefetch" }); toast("Searching every source again…"); };

// ================================================================== top bar actions, menus, toast

$("np").onclick = () => { closeSheet(); openTab("lyrics"); };
$("share").onclick = () => post({ type: "share" });
$("builder").onclick = () => post({ type: "newTemplate" });
$("moreTop").innerHTML = ICON.more;
$("moreTop").onclick = (e) => {
  const id = S.sheet || S.stageID, t = tpl(id);
  openMenu(e.currentTarget, [
    ["Import template…", () => post({ type: "importTemplate" })],
    t ? [`Export “${t.name}”…`, () => post({ type: "exportTemplate", id })] : null,
    null,
    ["New in Template Builder", () => post({ type: "newTemplate" })],
    ["Open templates folder", () => post({ type: "openFolder" })],
    ["Reload templates", () => post({ type: "reload" })],
  ].filter((x, i, a) => x !== undefined && !(x === null && a[i - 1] === null)));
};

let menuFor = null;
function openMenu(anchor, items) {
  const m = $("menu");
  if (menuFor === anchor && !m.hidden) return closeMenu();
  menuFor = anchor;
  m.innerHTML = items.map((it, i) => (it ? `<button type="button" role="menuitem" data-i="${i}" class="${it[2] || ""}">${esc(it[0])}</button>` : "<hr>")).join("");
  m._items = items;
  m.hidden = false;
  const r = anchor.getBoundingClientRect(), mw = m.offsetWidth, mh = m.offsetHeight;
  const below = r.bottom + 6 + mh < innerHeight;
  m.style.left = Math.max(8, Math.min(innerWidth - mw - 8, r.right - mw)) + "px";
  m.style.top = (below ? r.bottom + 6 : r.top - mh - 6) + "px";
  m.style.transformOrigin = below ? "top right" : "bottom right";
  requestAnimationFrame(() => m.classList.add("open"));
  m.querySelector("button")?.focus({ preventScroll: true });
}
function closeMenu() {
  const m = $("menu");
  m.classList.remove("open");
  m.hidden = true;
  menuFor = null;
}
$("menu").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-i]");
  if (!b) return;
  const it = $("menu")._items[+b.dataset.i];
  closeMenu();
  it?.[1]();
});
document.addEventListener("mousedown", (e) => { if (!$("menu").hidden && !e.target.closest("#menu") && e.target.closest("button") !== menuFor) closeMenu(); });

let toastTimer = 0;
function toast(text) {
  const t = $("toast");
  t.textContent = text;
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 2600);
}

// ================================================================== keyboard

document.addEventListener("keydown", (e) => {
  const typing = /INPUT|SELECT|TEXTAREA/.test(document.activeElement?.tagName) && document.activeElement.type !== "range";
  if (e.key === "Escape") {
    if (!$("menu").hidden) { closeMenu(); return; }
    if (S.sheet) { closeSheet(); return; }
    if (typing && $("search").value) { $("search").value = ""; S.query = ""; renderGallery(); return; }
    if (S.tab === "wallpaper" && S.view === "gallery") { S.view = "stage"; renderTabs(); return; }
  }
  if (!$("menu").hidden && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
    const bs = [...$("menu").querySelectorAll("button")], i = bs.indexOf(document.activeElement);
    bs[(i + (e.key === "ArrowDown" ? 1 : bs.length - 1)) % bs.length]?.focus();
    e.preventDefault();
    return;
  }
  if (e.metaKey && (/^[1-5]$/.test(e.key) || e.key === ",")) {
    e.preventDefault();
    closeSheet();
    openTab(e.key === "," ? "settings" : ["wallpaper", "displays", "history", "lyrics", "settings"][+e.key - 1]);
  } else if ((e.metaKey && e.key === "f") || (e.key === "/" && !typing)) {
    e.preventDefault();
    if (!(S.tab === "wallpaper" && S.view === "gallery")) showGallery();
    $("search").focus();
  }
});

// ================================================================== Settings

function renderSettings() {
  const v = S.settings || {};
  const tg = (key, label) => `<button type="button" class="tg" role="switch" aria-checked="${!!v[key]}" aria-label="${esc(label)}" data-set="${key}"></button>`;
  const row = (label, note, ctl = "", acts = "") => `<div class="pref"><b>${label}</b>${ctl ? `<div class="ctl">${ctl}</div>` : ""}${note ? `<small${note.live ? ' class="live"' : ""}>${esc(note.text ?? note)}</small>` : ""}${acts ? `<div class="acts">${acts}</div>` : ""}</div>`;
  const btn = (action, label, cls = "") => `<button type="button" class="mbtn sm ${cls}" data-act="${action}">${label}</button>`;
  const seg = (key, opts) => `<div class="seg" data-seg="${key}">${opts.map(([val, label]) => `<button type="button" data-val="${esc(val)}" class="${String(v[key]) === String(val) ? "on" : ""}">${label}</button>`).join("")}</div>`;
  const card = (title, rows) => `<div class="card"><div class="card-head"><span class="lbl">${title}</span></div>${rows.join("")}</div>`;
  const sourceNote = (source) => {
    if (source.kind === "direct") return "Read directly from the app.";
    if (source.kind !== "browser") return source.kind === "other" ? "Detected in macOS Now Playing." : "Recognized music app.";
    const members = source.members ? `${source.members} · ` : "";
    const affected = source.statusApps || source.name;
    if (source.status === "ready") return `${members}Recognized music tabs only · tab access on.`;
    if (source.status === "denied") return `${affected}: tab access denied · allow Lirica under Privacy & Security → Automation.`;
    if (source.status === "unsupported") return `${affected} does not expose its tabs to Lirica.`;
    if (source.status === "error") return `${affected}: couldn't read its tabs; Lirica will try again.`;
    return `${members}Recognized music tabs only · access is requested when one plays.`;
  };
  const sourceRows = (v.musicSources || []).map((source) => `<div class="pref source-pref" title="${esc(source.bundle)}">
    <b>${esc(source.name)}</b><div class="ctl"><button type="button" class="tg" role="switch" aria-checked="${!!source.enabled}" aria-label="Use ${esc(source.name)}" data-source="${esc(source.bundle)}"></button></div>
    <small class="${source.status === "ready" ? "ready" : source.status === "denied" || source.status === "error" ? "warn" : ""}">${esc(sourceNote(source))}</small></div>`).join("");
  const siteRows = (v.musicSites || []).map((site) => `<div class="pref source-pref" title="${esc(site.host)}">
    <b>${esc(site.name)}</b><div class="ctl"><button type="button" class="tg" role="switch" aria-checked="${!!site.enabled}" aria-label="Use ${esc(site.name)}" data-site="${esc(site.host)}"></button></div>
    <small>${site.recognized ? "Music website" : "Detected website · off until you allow it"} · ${esc(site.host)}</small></div>`).join("");
  const sourceList = (note, rows, action = "") => `<div class="source-list"><div class="source-head"><small>${note}</small>${action}</div>${rows || `<div class="source-empty">Nothing detected yet.</div>`}</div>`;
  const browserDenied = (v.musicSources || []).some((source) => source.kind === "browser" && source.status === "denied");
  const sharing = v.sharingNow ? { text: `${v.sharingNow} is sharing your screen, so lyrics are hidden.`, live: true }
    : v.canReadTitles ? "Notices Zoom, Google Meet, Teams, Slack, Discord, FaceTime, Webex and Screen Sharing."
    : "Notices Zoom, Teams and Screen Sharing. Sharing from a browser needs Screen Recording permission.";
  const kb = (k) => `<kbd>${k}</kbd>`;
  const html = [
    card("General", [
      row("Launch at login", "", tg("launchAtLogin", "Launch at login")),
      row("Pause wallpaper", "Puts your own wallpaper back until you resume.", tg("paused", "Pause wallpaper")),
      row("Animation frame rate", "Lower rates save battery. Lyric timing stays exact.", seg("refreshRate", [[0, "Max"], [60, "60"], [30, "30"], [15, "15"]])),
    ]),
    card("Lyrics &amp; privacy", [
      row("Focus Mode", "Hides lyrics on every screen until you turn it off.", kb("⌃⌥⌘F") + tg("focus", "Focus Mode")),
      row("Hide lyrics while screen sharing", sharing, tg("hideWhileSharing", "Hide lyrics while screen sharing"),
        v.hideWhileSharing && !v.canReadTitles ? btn("requestScreenRecording", "Detect browsers too…") : ""),
    ]),
    card("Music sources", [
      row("Default music player", "Lirica follows this player when it starts playing, and switches to whatever plays after an hour of silence. Clicking controls never switches players.",
        seg("musicPriority", [["spotify", "Spotify"], ["appleMusic", "Apple Music"], ["youtubeMusic", "YouTube Music"], ["other", "Other Apps"]])),
      row("Other music apps", "Uses macOS Now Playing for browsers and players besides Spotify and Apple Music. A future macOS update could stop this private feed from working.", tg("otherPlayers", "Other music apps")),
    ]),
    card("Applications", [
      sourceList("Choose which apps may become the wallpaper's source. Unknown apps start off.", sourceRows,
        browserDenied ? btn("openAutomation", "Open Automation settings") : ""),
    ]),
    card("Browser music websites", [
      sourceList("Lirica matches Now Playing to tab titles and reads only the matching hostname. Full addresses and tab titles are never saved.", siteRows),
    ]),
    card("Wallpaper data &amp; controls", [
      row("Wallpaper controls", "Controls stay on the desktop and never cover or activate your application windows.", tg("wallpaperControls", "Wallpaper controls")),
      row("Weather", "Uses your approximate location and Open-Meteo, for Weather & Time and other templates.", tg("useWeather", "Weather")),
      row("Sync to the beat", "Analyses Spotify's sound live so templates can move with the music. Nothing is recorded. Needs Screen Recording permission.", tg("beatSync", "Sync to the beat")),
    ]),
    card("Lyric cards", [
      row("Size", "The current template with the line being sung, saved to Pictures and copied.", seg("shareFormat", [["story", "Story 9:16"], ["square", "Square"]]),
        btn("share", "Share lyric card") + kb("⌃⌥⌘L")),
    ]),
    card("History", [
      row("Keep a history of wallpapers", `${v.historyCount ?? 0} wallpaper${v.historyCount === 1 ? "" : "s"} saved.`, tg("keepHistory", "Keep a history"),
        btn("openHistory", "Open History Wall") + btn("clearHistory", "Clear History…", "danger")),
    ]),
    card("Templates", [
      row("Your templates", "Templates you make or install live in a folder you can edit.", "",
        btn("openTemplatesFolder", "Open templates folder") + btn("openBuilder", "Template Builder") + `<button type="button" class="mbtn sm" data-reload>Reload templates</button>`),
    ]),
    card("Updates", [
      row(`Lirica ${esc(v.version || "")}`, v.updateStatus || "Updates come from GitHub releases.", "", btn("checkUpdates", "Check for updates") + btn("whatsNew", "What's new")),
      row("Install updates automatically", "", tg("autoUpdate", "Install updates automatically")),
    ]),
    card("Keyboard", [
      row("Open Lirica", "", kb("⌘O")), row("Quick Switcher", "", kb("⌃⌥⌘W")),
      row("Share lyric card", "", kb("⌃⌥⌘L")), row("Focus Mode", "", kb("⌃⌥⌘F")), row("Tabs in this window", "", kb("⌘1–5")),
    ]),
  ].join("");
  setHTML($("prefs"), html);
  $("prefs").querySelectorAll(".seg").forEach(wireSeg);
}
$("prefs").addEventListener("click", (e) => {
  const t = e.target.closest("[data-set]"), source = e.target.closest("[data-source]"), site = e.target.closest("[data-site]"),
    sg = e.target.closest("[data-seg] > button"), a = e.target.closest("[data-act]");
  if (t) {
    const on = t.getAttribute("aria-checked") !== "true";
    t.setAttribute("aria-checked", on); S.settings[t.dataset.set] = on;
    post({ type: "setting", key: t.dataset.set, value: on });
  } else if (source) {
    const enabled = source.getAttribute("aria-checked") !== "true";
    source.setAttribute("aria-checked", enabled);
    const item = (S.settings.musicSources || []).find((s) => s.bundle === source.dataset.source);
    if (item) item.enabled = enabled;
    post({ type: "setting", key: "musicSource", value: { bundle: source.dataset.source, enabled } });
  } else if (site) {
    const enabled = site.getAttribute("aria-checked") !== "true";
    site.setAttribute("aria-checked", enabled);
    const item = (S.settings.musicSites || []).find((s) => s.host === site.dataset.site);
    if (item) item.enabled = enabled;
    post({ type: "setting", key: "musicSite", value: { host: site.dataset.site, enabled } });
  } else if (sg) {
    const key = sg.parentElement.dataset.seg, raw = sg.dataset.val, val = key === "refreshRate" ? +raw : raw;
    S.settings[key] = val; setSeg(sg.parentElement, (b) => b === sg);
    post({ type: "setting", key, value: val });
  } else if (a) post({ type: "settingAction", action: a.dataset.act });
  else if (e.target.closest("[data-reload]")) post({ type: "reload" });
});

// ================================================================== render all

function renderAll() {
  renderTop();
  renderTabs();
  renderTarget();
  renderStageInsp();
  renderShelf();
  $("sampleNote").hidden = !isSample();
  if (S.tab === "displays") renderDisplays();
  if (S.tab === "lyrics") renderLyrics();
  if (S.tab === "settings") renderSettings();
}

post({ type: "ready" });
