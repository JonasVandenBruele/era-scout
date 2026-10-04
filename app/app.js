"use strict";
/* ERA Scout — prospectiegame (vanilla JS, geen build-stap).
   Data, login en spelregels zitten in Supabase (zie supabase/migrations). */

const app = document.getElementById("app");
const nav = document.getElementById("nav");
const layer = document.getElementById("layer");

const S = {
  me: null,
  demo: false,
  dash: null,
  rule: { door: 5, conversation: 10, phone: 15, appointment: 30, revisit_pct: 50 },
  prospects: [],
};

/* ------------------------------------------------------------ utils --- */

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* ignore */ } },
};
const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
  : "x" + Date.now().toString(36) + Math.random().toString(36).slice(2, 12));
const go = (hash) => { if (location.hash === hash) router(); else location.hash = hash; };
const on = (sel, evt, fn, root = app) => $$(sel, root).forEach((el) => el.addEventListener(evt, fn));
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const fillBars = (root = document) => requestAnimationFrame(() => requestAnimationFrame(() =>
  $$("[data-w]", root).forEach((el) => { el.style.width = `${Math.min(1, +el.dataset.w) * 100}%`; })));

function applyTheme() {
  const t = store.get("nod_theme", "dark");
  document.documentElement.dataset.theme = t;
  $('meta[name="theme-color"]').setAttribute("content", t === "light" ? "#eef0f8" : "#00003d");
}
applyTheme();

/* Icons: simple stroke icons (24×24). */
const ICON = {
  home: '<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
  pin: '<path d="M12 21s-7-6.1-7-11.5a7 7 0 0 1 14 0C19 14.9 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  trophy: '<path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0zM7 6H4v1a3 3 0 0 0 3 3M17 6h3v1a3 3 0 0 1-3 3"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  door: '<path d="M6 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17M3 21h18"/><circle cx="14.5" cy="12" r=".6" fill="currentColor"/>',
  chat: '<path d="M21 12a8 8 0 0 1-11.8 7L4 20l1.1-4.4A8 8 0 1 1 21 12z"/>',
  phone: '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2z"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/>',
  star: '<path d="m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3l-5.6 2.9 1.1-6.2L3 9.6l6.2-.9z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  nav: '<path d="M3 11 21 3l-8 18-2-8z"/>',
  check: '<path d="M5 12.5 9.5 17 19 7"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  back: '<path d="m15 18-6-6 6-6"/>',
  chev: '<path d="m9 18 6-6-6-6"/>',
  target: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',
  team: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6"/>',
  medal: '<circle cx="12" cy="15" r="6"/><path d="M8.5 10 6 3h4l2 4M15.5 10 18 3h-4l-1 2"/>',
  steps: '<path d="M4 16v-2.4C4 11.5 3 10.5 3 8c0-2.7 1.5-6 4.5-6C9.4 2 10 3.8 10 5.5c0 3.1-2 5.7-2 8.7V16a2 2 0 1 1-4 0zM20 20v-2.4c0-2.1 1-3.1 1-5.6 0-2.7-1.5-6-4.5-6C14.6 6 14 7.8 14 9.5c0 3.1 2 5.7 2 8.7V20a2 2 0 1 0 4 0z"/>',
  file: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8zM14 3v5h5M9 13h6M9 17h4"/>',
  ban: '<circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/>',
  sliders: '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
  play: '<path d="M7 4.5v15l12.5-7.5z" fill="currentColor"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16zM14 6l4 4"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
  bolt: '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>',
  gift: '<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13M5 12v9h14v-9M7.5 8a2.5 2.5 0 0 1 0-5C10 3 12 8 12 8s2-5 4.5-5a2.5 2.5 0 0 1 0 5"/>',
  alert: '<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0zM12 9v4M12 17h.01"/>',
  cloudoff: '<path d="m2 2 20 20M5.8 5.8A6 6 0 0 0 7 17h10M22 15a4.5 4.5 0 0 0-5.5-6.9M9.6 4.2a6 6 0 0 1 7.9 3.9"/>',
  crown: '<path d="m3 7 4.5 4L12 4l4.5 7L21 7l-2 12H5z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  up: '<path d="m6 15 6-6 6 6"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  locate: '<circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="2.5" fill="currentColor"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>',
  map: '<path d="m9 4-6 2v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4M21 4v5h-5"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  snooze: '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2M5 3 2 6M22 6l-3-3"/>',
};
const icon = (n, cls = "") => `<svg class="i ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICON[n] || ""}</svg>`;

const RES = {
  door: { icon: "door", label: "Aangebeld", sub: "Niemand thuis, flyer of geen interesse" },
  conversation: { icon: "chat", label: "Gesprek gehad", sub: "Echt contact aan de deur" },
  phone: { icon: "phone", label: "Telefoonnummer", sub: "Rechtstreeks, via buur of anders" },
  appointment: { icon: "calendar", label: "Afspraak", sub: "Datum en uur vastgelegd" },
};
const SOURCES = { direct: "Rechtstreeks", neighbour: "Via buur", other: "Andere" };
const SIGNALS = { sell: "Verkoopplannen", buy: "Koopplannen", move: "Verhuisplannen", valuation: "Wil schatting", rent: "Verhuurplannen", other: "Andere kans" };
const HORIZONS = { now: "Nu", lt1: "< 1 jaar", "1to2": "1–2 jaar", "2to5": "2–5 jaar", gt5: "5+ jaar" };
const HORIZON_DAYS = { now: 7, lt1: 30, "1to2": 90, "2to5": 180, gt5: 365 };
const FOLLOW_IN = [[7, "1 week"], [30, "1 maand"], [90, "3 maanden"], [180, "6 maanden"], [365, "1 jaar"]];
const COLORS = ["#d60a29", "#3e8bff", "#9c7cff", "#ffc53d", "#00b99b", "#2ec5e8", "#ff7a45", "#e84c88"];
const DAYS = ["zo", "ma", "di", "wo", "do", "vr", "za"];
const pad = (n) => String(n).padStart(2, "0");
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const addDays = (n, from = new Date()) => { const d = new Date(from); d.setDate(d.getDate() + n); return ymd(d); };
const fmtDate = (s) => { const d = new Date(s.slice(0, 10) + "T12:00"); return `${DAYS[d.getDay()]} ${d.getDate()}/${d.getMonth() + 1}`; };
const fmtLong = (s) => { const d = new Date(s.slice(0, 10) + "T12:00"); return `${d.getDate()}/${d.getMonth() + 1}/${d.getFullYear()}`; };
const fmtDT = (s) => `${fmtDate(s)} · ${s.slice(11, 16)}`;
const dayDiff = (s) => Math.round((new Date(s.slice(0, 10) + "T12:00") - new Date(ymd(new Date()) + "T12:00")) / 864e5);
function ago(s) { const d = -dayDiff(s); return d <= 0 ? "vandaag" : d === 1 ? "gisteren" : `${d} d geleden`; }
function dueLabel(s) {
  const d = dayDiff(s);
  if (d < 0) return `<span class="due late">${-d} d te laat</span>`;
  if (d === 0) return '<span class="due today">Vandaag</span>';
  if (d < 60) return `<span class="due later">Over ${d} d</span>`;
  return `<span class="due later">${fmtLong(s)}</span>`;
}
const addrKey = (a) => a.toLowerCase().replace(/[.,;/]/g, " ").replace(/\s+/g, " ").trim();
const firstName = (n) => (n || "").split(" ")[0];

function avatar(u, cls = "", level = null) {
  const init = (u.name || "?").split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
  return `<span class="avatar ${cls}" style="--c:${esc(u.color || "#3e8bff")}" aria-hidden="true">${esc(init)}${level ? `<span class="lvl">${level}</span>` : ""}</span>`;
}
const tierTag = (r) => `<span class="tag t-${r}">${RES[r].label}</span>`;

function toast(msg, ms = 2600) {
  const t = document.createElement("div");
  t.className = "toast";
  t.setAttribute("role", "status");
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}
function buzz(ms = 25) { try { navigator.vibrate && navigator.vibrate(ms); } catch { /* ignore */ } }
function mapsUrl(address) {
  const q = encodeURIComponent(address);
  return /iPhone|iPad|Macintosh/.test(navigator.userAgent) && "ontouchend" in document
    ? `https://maps.apple.com/?daddr=${q}` : `https://www.google.com/maps/dir/?api=1&destination=${q}`;
}
const brand = () => `<a class="brand" href="#/" aria-label="Mijn dag"><span class="era">ERA</span><span class="brand-name">Scout</span></a>`;
const backBar = (href, title, extra = "") => `<header class="topbar"><a class="icon-btn" href="${href}" aria-label="Terug">${icon("back")}</a><h1>${esc(title)}</h1>${extra}</header>`;

/* -------------------------------------------------------------- api --- */

const CFG = window.SCOUT_CONFIG || {};
const sb = CFG.supabaseUrl && CFG.supabaseAnonKey && window.supabase
  ? window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey,
    { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } })
  : null;
const BASE = location.href.split("#")[0].split("?")[0];

const offlineError = () => Object.assign(new Error("Geen verbinding met de server."), { offline: true });

/* Every database call goes through one Supabase function (see 20261004000003_api.sql). */
async function rpc(fn, args = {}) {
  if (!sb) throw Object.assign(new Error("De app is nog niet gekoppeld aan Supabase."), { code: "config" });
  if (!navigator.onLine) throw offlineError();
  let res;
  try { res = await sb.rpc(fn, args); } catch { throw offlineError(); }
  const { data, error, status } = res;
  if (!error) return data;
  if (!error.hint && (!status || status >= 500 || /fetch|network|load failed/i.test(error.message || ""))) throw offlineError();
  const err = new Error(error.message || "Er ging iets mis.");
  err.code = error.hint || error.code;
  if (err.code === "auth" || status === 401) {
    S.me = null;
    store.del("nod_me");
    if (!location.hash.startsWith("#/login") && !location.hash.startsWith("#/uitnodiging")) go("#/login");
  }
  throw err;
}

/* The views were written against a small REST API; this table maps those calls onto the Supabase functions. */
const ROUTE_MAP = [
  ["GET", /^\/api\/auth\/status$/, () => ["auth_status"]],
  ["GET", /^\/api\/me\/dashboard$/, () => ["dashboard"]],
  ["GET", /^\/api\/me\/profile$/, () => ["my_profile"]],
  ["PATCH", /^\/api\/me$/, (m, q, b) => ["update_me", { p_data: b }]],
  ["GET", /^\/api\/prospects$/, () => ["prospects_list"]],
  ["POST", /^\/api\/prospects$/, (m, q, b) => ["prospect_create", { p_address: b.address, p_name: b.name || null }]],
  ["GET", /^\/api\/prospects\/(\d+)$/, (m) => ["prospect_get", { p_id: +m[1] }]],
  ["PATCH", /^\/api\/prospects\/(\d+)$/, (m, q, b) => ["prospect_update", { p_id: +m[1], p_data: b }]],
  ["POST", /^\/api\/visits$/, (m, q, b) => ["visit_register", { p_data: b }]],
  ["GET", /^\/api\/visits\/today$/, () => ["visits_today"]],
  ["GET", /^\/api\/visits\/(\d+)$/, (m) => ["visit_get", { p_id: +m[1] }]],
  ["PATCH", /^\/api\/visits\/(\d+)$/, (m, q, b) => ["visit_update", { p_id: +m[1], p_data: b }]],
  ["GET", /^\/api\/rounds\/active$/, () => ["round_active"]],
  ["POST", /^\/api\/rounds$/, (m, q, b) => ["round_start", { p_goal: b.goal ?? null }]],
  ["POST", /^\/api\/rounds\/(\d+)\/end$/, (m) => ["round_end", { p_id: +m[1] }]],
  ["GET", /^\/api\/leaderboard$/, (m, q) => ["leaderboard", { p_period: q.get("period") || "week", p_sort: q.get("sort") || "points" }]],
  ["GET", /^\/api\/follow-ups$/, (m, q) => ["follow_ups_list", { p_scope: q.get("scope") || "mine", p_status: q.get("status") || "open" }]],
  ["POST", /^\/api\/follow-ups$/, (m, q, b) => ["follow_up_create", { p_data: b }]],
  ["PATCH", /^\/api\/follow-ups\/(\d+)$/, (m, q, b) => ["follow_up_update", { p_id: +m[1], p_data: b }]],
  ["GET", /^\/api\/addresses\/search$/, (m, q) => ["addresses_search", { p_q: q.get("q") || "" }]],
  ["GET", /^\/api\/addresses\/(\d+)\/next$/, (m) => ["address_next", { p_id: +m[1] }]],
  ["GET", /^\/api\/addresses\/(\d+)$/, (m) => ["address_get", { p_id: +m[1] }]],
  ["GET", /^\/api\/region$/, () => ["region_status"]],
  ["GET", /^\/api\/admin\/overview$/, () => ["admin_overview"]],
  ["GET", /^\/api\/admin\/visits$/, () => ["admin_visits"]],
  ["POST", /^\/api\/admin\/visits\/(\d+)\/void$/, (m, q, b) => ["admin_void", { p_id: +m[1], p_reason: b.reason || "" }]],
  ["PATCH", /^\/api\/admin\/users\/([\w-]+)$/, (m, q, b) => ["admin_user_update", { p_id: m[1], p_data: b }]],
  ["PATCH", /^\/api\/admin\/team$/, (m, q, b) => ["admin_team_update", { p_data: b }]],
  ["POST", /^\/api\/admin\/rules$/, (m, q, b) => ["admin_rules", { p_data: b }]],
  ["POST", /^\/api\/admin\/competitions$/, (m, q, b) => ["admin_competition_create", { p_data: b }]],
  ["POST", /^\/api\/admin\/competitions\/(\d+)\/end$/, (m) => ["admin_competition_end", { p_id: +m[1] }]],
  ["PATCH", /^\/api\/admin\/challenges\/(\d+)$/, (m, q, b) => ["admin_challenge_update", { p_id: +m[1], p_data: b }]],
  ["POST", /^\/api\/admin\/region\/(\d+)\/remove$/, (m) => ["admin_region_remove", { p_id: +m[1] }]],
];

async function api(method, path, body = {}) {
  const [p, qs] = path.split("?");
  const q = new URLSearchParams(qs || "");
  for (const [m, rx, fn] of ROUTE_MAP) {
    const hit = m === method && p.match(rx);
    if (hit) {
      const [name, args] = fn(hit, q, body || {});
      return rpc(name, args || {});
    }
  }
  throw new Error(`Onbekende actie: ${method} ${p}`);
}

/* ----------------------------------------------------------- outbox --- */
/* Every registration is written to the outbox *before* it is sent and only
   leaves it when the server confirms (or rejects) it. The client_id makes
   resending safe: the server never stores a registration twice. */

const OUT = "nod_outbox";
const outbox = () => store.get(OUT, []);
function setOutbox(list) { store.set(OUT, list); paintOutbox(); }

async function sendRegistration(item) {
  setOutbox([...outbox().filter((i) => i.client_id !== item.client_id), { ...item, status: "pending" }]);
  try {
    const data = await api("POST", "/api/visits", item.payload);
    setOutbox(outbox().filter((i) => i.client_id !== item.client_id));
    return { data };
  } catch (e) {
    if (e.offline) return { queued: true };
    setOutbox(outbox().filter((i) => i.client_id !== item.client_id));
    throw e;
  }
}

let flushing = false;
async function flushOutbox() {
  if (flushing || !S.me) return;
  const pending = outbox().filter((i) => i.status === "pending");
  if (!pending.length) return;
  flushing = true;
  let sent = 0, pts = 0;
  for (const item of pending) {
    try {
      const data = await api("POST", "/api/visits", item.payload);
      setOutbox(outbox().filter((i) => i.client_id !== item.client_id));
      sent++; pts += data.points;
    } catch (e) {
      if (e.offline) break;
      setOutbox(outbox().map((i) => i.client_id === item.client_id ? { ...i, status: "failed", error: e.message } : i));
    }
  }
  flushing = false;
  if (sent) {
    toast(`${plural(sent, "bezoek", "bezoeken")} alsnog opgeslagen · +${pts} punten`);
    if (["#/", "", "#"].includes(location.hash.split("?")[0])) router();
  }
}
window.addEventListener("online", flushOutbox);
setInterval(flushOutbox, 20000);

function paintOutbox() {
  const box = $("#outbox-slot");
  if (!box) return;
  const list = outbox();
  const pending = list.filter((i) => i.status === "pending");
  const failed = list.filter((i) => i.status === "failed");
  box.innerHTML = list.length ? `<div class="stack">
    ${pending.length ? `<div class="outbox" role="status">${icon("cloudoff")}<div class="grow">${plural(pending.length, "bezoek wacht", "bezoeken wachten")} op verbinding · veilig bewaard op je toestel</div>
      <button class="btn sm outline" data-flush>Sturen</button></div>` : ""}
    ${failed.map((i) => `<div class="outbox">${icon("alert")}<div class="grow"><b>${esc(i.address)}</b><br><span class="small muted">${esc(i.error)}</span></div>
      <button class="btn sm outline" data-drop="${esc(i.client_id)}">Wis</button></div>`).join("")}</div>` : "";
  on("[data-flush]", "click", flushOutbox, box);
  on("[data-drop]", "click", (e) => setOutbox(outbox().filter((i) => i.client_id !== e.currentTarget.dataset.drop)), box);
}

/* ------------------------------------------------- prospect cache --- */

function loadProspectCache() { S.prospects = store.get("nod_prospects", []); }
async function refreshProspects() {
  try {
    const { prospects } = await api("GET", "/api/prospects");
    S.prospects = prospects;
    store.set("nod_prospects", prospects);
  } catch { /* offline: keep cache */ }
  return S.prospects;
}
function rememberAddress(address) {
  store.set("nod_recent", [address, ...store.get("nod_recent", []).filter((a) => a !== address)].slice(0, 6));
}
function nextDoors(address) {
  const m = address && address.match(/^(.*?)(\d+)\s*[a-zA-Z]?\s*(,.*)?$/);
  if (!m) return [];
  const street = m[1].trim(), n = +m[2], rest = m[3] || "";
  return [n + 2, n + 4, n + 1, n - 2].filter((x) => x > 0).map((x) => `${street} ${x}${rest}`);
}
const findCached = (address) => S.prospects.find((p) => addrKey(p.address) === addrKey(address));

/* ---------------------------------------------------------- location --- */
/* One-shot position on request (no background tracking). The position is sent
   to our own server only to find the nearest address and is not stored. */

const autoLocate = () => store.get("nod_autoloc", true);
async function locationGranted() {
  try { return (await navigator.permissions.query({ name: "geolocation" })).state === "granted"; } catch { return false; }
}
function getPosition() {
  return new Promise((resolve, reject) => {
    if (!window.isSecureContext) return reject(new Error("Locatie werkt enkel via https (of op deze computer via localhost)."));
    if (!navigator.geolocation) return reject(new Error("Dit toestel geeft geen locatie door."));
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lon: p.coords.longitude, acc: Math.round(p.coords.accuracy) }),
      (e) => reject(new Error(e.code === 1 ? "Geen toestemming voor locatie. Zet ze aan in je browserinstellingen." : "Locatie niet gevonden. Probeer opnieuw of zoek het adres.")),
      { enableHighAccuracy: true, timeout: 12000, maximumAge: 10000 });
  });
}
function distanceM(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const x = (lon2 - lon1) * rad * Math.cos(((lat1 + lat2) / 2) * rad), y = (lat2 - lat1) * rad;
  return 6371000 * Math.hypot(x, y);
}
/* Outside the loaded region: Geopunt geolocation service (Digitaal Vlaanderen), called from the browser. */
async function geopuntNear(lat, lon, limit = 5) {
  try {
    const r = await fetch(`https://geo.api.vlaanderen.be/geolocation/v4/Location?latlon=${lat.toFixed(6)},${lon.toFixed(6)}&c=${limit}`);
    const d = await r.json();
    const seen = new Set();
    return (d.LocationResult || []).filter((x) => x.Housenumber && x.Thoroughfarename).map((x) => {
      const number = (x.Housenumber.match(/\d+[A-Za-z]?/) || [x.Housenumber])[0];
      return {
        id: null, street: x.Thoroughfarename, number, postcode: x.Zipcode, municipality: x.Municipality, boxes: 0,
        label: `${x.Thoroughfarename} ${number}, ${x.Zipcode} ${x.Municipality}`,
        lat: x.Location.Lat_WGS84, lon: x.Location.Lon_WGS84,
        distance: Math.round(distanceM(lat, lon, x.Location.Lat_WGS84, x.Location.Lon_WGS84)), prospect_id: null,
      };
    }).filter((a) => !seen.has(a.label) && seen.add(a.label));
  } catch { return []; }
}
async function nearby(radius = 60, limit = 6) {
  const pos = await getPosition();
  const r = await rpc("addresses_near", { p_lat: pos.lat, p_lon: pos.lon, p_radius: radius, p_limit: limit });
  if (r.addresses.length) return { ...r, acc: pos.acc };
  return { addresses: await geopuntNear(pos.lat, pos.lon, Math.min(limit, 8)), source: "geopunt", acc: pos.acc };
}
/* A register/Geopunt address as something the registration form can use. */
function asProspect(a) {
  if (a.prospect_id) {
    const p = S.prospects.find((x) => x.id === a.prospect_id);
    if (p) return { ...p, address_ref: p.address_ref || a.id, boxes: a.boxes };
    return { id: a.prospect_id, address: a.label, address_ref: a.id };
  }
  return { address: a.label, address_ref: a.id, lat: a.lat, lon: a.lon, register: !!a.id, boxes: a.boxes };
}

/* ------------------------------------------------------------- nav --- */

function setNav(path, show = true) {
  nav.classList.toggle("hidden", !show);
  if (!show) return;
  const cur = path === "#" || path === "" ? "#/" : path;
  const active = (href) => cur === href
    || (href === "#/prospecten" && (cur.startsWith("#/prospect") || cur === "#/opvolgingen"))
    || (href === "#/profiel" && cur === "#/beheer") || (href === "#/" && cur === "#/ronde");
  const items = [["#/", "home", "Mijn dag"], ["#/prospecten", "pin", "Adressen"], ["#/registreer", "plus", ""],
    ["#/ranglijst", "trophy", "Ranking"], ["#/profiel", "user", "Profiel"]];
  nav.innerHTML = `<div>${items.map(([href, ic, label]) => !label
    ? `<a href="${href}" aria-label="Registreer bezoek"><span class="fab">${icon(ic)}</span></a>`
    : `<a href="${href}" ${active(href) ? 'aria-current="page"' : ""}>${icon(ic)}<span>${label}</span></a>`).join("")}</div>`;
}

/* ---------------------------------------------------------- router --- */

const ROUTES = [
  [/^#\/?$/, viewDay], [/^#\/registreer$/, viewRegister, { nav: false }], [/^#\/prospecten$/, viewProspects],
  [/^#\/opvolgingen$/, viewFollowUps], [/^#\/prospect\/(\d+)$/, viewProspect], [/^#\/ronde$/, viewRound],
  [/^#\/ranglijst$/, viewLeaderboard], [/^#\/profiel$/, viewProfile], [/^#\/beheer$/, viewAdmin],
  [/^#\/login$/, viewLogin, { pub: true, nav: false }], [/^#\/uitnodiging\/([\w-]+)$/, viewInvite, { pub: true, nav: false }],
  [/^#\/setup$/, viewSetup, { pub: true, nav: false }], [/^#\/wachtwoord$/, viewPassword, { pub: true, nav: false }],
];

async function loadMe() {
  if (!sb) return { config: true };
  const { data } = await sb.auth.getSession();
  if (!data.session) { S.me = null; store.del("nod_me"); return { user: null }; }
  try {
    let st = await rpc("auth_status");
    // Account exists but no profile yet: finish the invite or the first-time setup stored at sign-up.
    const meta = data.session.user.user_metadata || {};
    if (!st.user && meta.invite_code) {
      try { st = await rpc("accept_invite", { p_code: meta.invite_code, p_name: meta.name || data.session.user.email }); } catch { /* shown on login */ }
    } else if (!st.user && st.needs_setup && meta.team_name) {
      st = await rpc("setup_team", { p_team_name: meta.team_name, p_name: meta.name || data.session.user.email });
    }
    S.me = st.user;
    S.session = data.session;
    if (st.user) store.set("nod_me", st.user); else store.del("nod_me");
    return st;
  } catch (e) {
    if (e.offline) S.me = store.get("nod_me", null);
    return { user: S.me, offline: true };
  }
}

async function router() {
  const [path, qs] = (location.hash || "#/").split("?");
  const query = new URLSearchParams(qs || "");
  closeLayer();
  const hit = ROUTES.map(([rx, fn, opt]) => [path.match(rx), fn, opt || {}]).find(([m]) => m);
  if (!hit) return go("#/");
  const [m, view, opt] = hit;
  if (!sb && path !== "#/login") return go("#/login");
  if (!opt.pub && !S.me) {
    const st = await loadMe();
    if (!S.me) return go("#/login");
  }
  setNav(path, opt.nav !== false);
  window.scrollTo(0, 0);
  try {
    await view(m, query);
  } catch (e) {
    app.innerHTML = `<header class="topbar">${brand()}</header>
      <div class="panel stack"><div class="row">${icon(e.offline ? "cloudoff" : "alert", "lg")}<h2>${e.offline ? "Je bent offline" : "Even geduld"}</h2></div>
      <p class="muted" style="margin:0">${esc(e.offline ? "Registreren werkt wel: je bezoeken worden op je toestel bewaard en later verstuurd." : e.message)}</p>
      <a class="btn primary block" href="#/registreer">${icon("plus")} Registreer bezoek</a>
      <button class="btn outline block" id="retry">Opnieuw proberen</button></div>`;
    on("#retry", "click", router);
  }
}
window.addEventListener("hashchange", router);

/* ------------------------------------------------------------ login --- */

const heroHtml = (title, sub) => `<div class="login-hero"><span class="era">ERA</span><h1>${title}</h1><p class="muted" style="margin:0">${sub}</p></div>`;

async function viewLogin() {
  if (!sb) {
    app.innerHTML = `${heroHtml("Scout", "Nog niet gekoppeld")}
      <div class="panel stack"><p style="margin:0">Deze versie van de app is nog niet gekoppeld aan een Supabase-project.</p>
      <p class="small muted" style="margin:0">Zet <code>VITE_SUPABASE_URL</code> en <code>VITE_SUPABASE_ANON_KEY</code> als repository-variabelen op GitHub (zie README) of vul <code>app/config.js</code> in voor lokaal gebruik.</p></div>`;
    return;
  }
  const st = await loadMe();
  if (S.me) return go("#/");
  const session = (await sb.auth.getSession()).data.session;
  app.innerHTML = `${heroHtml("Scout", "Scout je wijk. Tik je resultaat. Klim in de ranking.")}
    ${session ? `<div class="notice warn">${icon("alert")}<span>Je bent ingelogd als ${esc(session.user.email)}, maar je hebt nog geen toegang tot een team.
      ${st.inactive ? "Je account is gedeactiveerd." : st.needs_setup ? "Start hieronder je team." : "Open de uitnodigingslink die je van je beheerder kreeg."}</span></div>` : ""}
    <form class="panel stack" id="login" novalidate>
      <label class="field"><span class="label">E-mail</span><input class="input" type="email" name="email" autocomplete="username" required></label>
      <label class="field"><span class="label">Wachtwoord</span><input class="input" type="password" name="password" autocomplete="current-password" required></label>
      <p class="error" id="err" role="alert"></p>
      <button class="btn primary xl block">Inloggen</button>
      <button type="button" class="btn ghost block" id="forgot">Wachtwoord vergeten?</button>
    </form>
    <div class="stack" style="margin-top:18px;text-align:center">
      ${session ? '<button class="btn ghost block" id="out">Afmelden</button>' : ""}
      <a class="small muted" href="#/setup">Eerste keer? Start een nieuw team</a>
    </div>`;
  on("#login", "submit", async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    $("#err").textContent = "";
    const { error } = await sb.auth.signInWithPassword({ email: String(f.get("email")).trim(), password: String(f.get("password")) });
    if (error) { $("#err").textContent = /invalid/i.test(error.message) ? "E-mail of wachtwoord klopt niet." : error.message; return; }
    await loadMe();
    if (S.me) go("#/"); else viewLogin();
  });
  on("#forgot", "click", async () => {
    const email = $('#login [name="email"]').value.trim();
    if (!email) { $("#err").textContent = "Vul eerst je e-mailadres in."; return; }
    const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: BASE + "#/wachtwoord" });
    $("#err").textContent = error ? error.message : "Je krijgt een mail om een nieuw wachtwoord te kiezen.";
  });
  on("#out", "click", async () => { await sb.auth.signOut(); viewLogin(); });
}

async function viewPassword() {
  app.innerHTML = `${heroHtml("Nieuw wachtwoord", "Kies een nieuw wachtwoord")}
    <form class="panel stack" id="pw"><label class="field"><span class="label">Nieuw wachtwoord (min. 8 tekens)</span>
      <input class="input" type="password" name="password" minlength="8" required autocomplete="new-password"></label>
      <p class="error" id="err" role="alert"></p><button class="btn primary xl block">Opslaan</button></form>`;
  on("#pw", "submit", async (e) => {
    e.preventDefault();
    const { error } = await sb.auth.updateUser({ password: new FormData(e.target).get("password") });
    if (error) { $("#err").textContent = error.message; return; }
    toast("Wachtwoord aangepast"); go("#/");
  });
}

async function signUpOrIn(email, password, metadata) {
  const { data, error } = await sb.auth.signUp({ email, password, options: { data: metadata, emailRedirectTo: BASE } });
  if (error) throw new Error(/registered/i.test(error.message) ? "Er bestaat al een account met dit e-mailadres. Log in met je wachtwoord." : error.message);
  return data.session;
}

async function viewSetup() {
  if (!sb) return go("#/login");
  app.innerHTML = `${heroHtml("Start je team", "Je wordt de eerste beheerder.")}
    <form class="panel stack" id="setup">
      <label class="field"><span class="label">Teamnaam</span><input class="input" name="team_name" required maxlength="60" placeholder="bv. ERA Leus & Toye"></label>
      <label class="field"><span class="label">Jouw naam</span><input class="input" name="name" required maxlength="60" autocomplete="name"></label>
      <label class="field"><span class="label">E-mail</span><input class="input" type="email" name="email" required autocomplete="username"></label>
      <label class="field"><span class="label">Wachtwoord (min. 8 tekens)</span><input class="input" type="password" name="password" minlength="8" required autocomplete="new-password"></label>
      <p class="error" id="err" role="alert"></p>
      <button class="btn primary xl block">Team aanmaken</button></form>`;
  on("#setup", "submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    try {
      const session = await signUpOrIn(f.email.trim(), f.password, { team_name: f.team_name, name: f.name });
      if (!session) { $("#err").textContent = "Bevestig je e-mailadres via de link in je mailbox en log daarna in."; return; }
      await rpc("setup_team", { p_team_name: f.team_name, p_name: f.name });
      await loadMe(); go("#/");
    } catch (err) { $("#err").textContent = err.message; }
  });
}

async function viewInvite(m) {
  const code = m[1];
  if (!sb) return go("#/login");
  let info;
  try { info = await rpc("invite_info", { p_code: code }); } catch (e) {
    app.innerHTML = `${heroHtml("Uitnodiging", esc(e.message))}<a class="btn outline block" href="#/login">Naar inloggen</a>`;
    return;
  }
  app.innerHTML = `${heroHtml(`Welkom bij ${esc(info.team)}`, esc(info.email))}
    <form class="panel stack" id="inv">
      <label class="field"><span class="label">Jouw naam</span><input class="input" name="name" required maxlength="60" autocomplete="name"></label>
      <label class="field"><span class="label">Kies een wachtwoord (min. 8 tekens)</span><input class="input" type="password" name="password" minlength="8" required autocomplete="new-password"></label>
      <p class="error" id="err" role="alert"></p>
      <button class="btn primary xl block">Account aanmaken</button>
      <button type="button" class="btn ghost block" id="have">Ik heb al een account</button></form>`;
  const finish = async (name) => {
    await rpc("accept_invite", { p_code: code, p_name: name });
    await loadMe(); go("#/");
  };
  on("#inv", "submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    try {
      const session = await signUpOrIn(info.email, f.password, { invite_code: code, name: f.name });
      if (!session) { $("#err").textContent = "Bevestig je e-mailadres via de link in je mailbox en log daarna in."; return; }
      await finish(f.name);
    } catch (err) { $("#err").textContent = err.message; }
  });
  on("#have", "click", async () => {
    const pw = $('#inv [name="password"]').value;
    const name = $('#inv [name="name"]').value || info.email;
    const { error } = await sb.auth.signInWithPassword({ email: info.email, password: pw });
    if (error) { $("#err").textContent = "Vul je bestaande wachtwoord in en tik opnieuw."; return; }
    try { await finish(name); } catch (err) { $("#err").textContent = err.message; }
  });
}

/* ---------------------------------------------------------- my day --- */

function followUpRows(items, opts = {}) {
  return items.map((f) => `<div class="fu">
    <span class="ic">${icon("star")}</span>
    <a class="grow" href="#/prospect/${f.prospect_id}" style="text-decoration:none">
      <div class="row spread"><b class="small">${esc(f.address)}</b>${dueLabel(f.due_on)}</div>
      <div class="small muted">${esc(f.signal_label)}${f.horizon_label ? ` · ${esc(f.horizon_label.toLowerCase())}` : ""}${opts.owner ? ` · ${esc(firstName(f.owner))}` : ""}</div>
      ${f.note ? `<div class="small" style="margin-top:2px">“${esc(f.note)}”</div>` : ""}
    </a></div>`).join("");
}

async function viewDay() {
  const d = await api("GET", "/api/me/dashboard");
  S.dash = d; S.rule = d.rule; S.me = d.user;
  const t = d.today;
  const pct = Math.min(1, t.doors / Math.max(1, t.goal));
  const left = Math.max(0, t.goal - t.doors);
  const msg = !t.workday
    ? (t.doors ? `Bonusdag: ${plural(t.doors, "deur", "deuren")} op een vrije dag.` : "Geen werkdag vandaag. Elke deur is bonus.")
    : left === 0 ? "Dagmissie voltooid. Nog één deur?" : t.doors === 0 ? `Eerste deur = ${d.rule.door} punten. Go.` : `Nog ${plural(left, "deur", "deuren")} tot je dagmissie.`;
  const ch = d.challenge;
  const teamCh = d.challenges.find((c) => c.scope === "team");
  const w = d.week;
  const fu = d.follow_ups;
  app.innerHTML = `
    <header class="topbar">${brand()}${d.team.is_demo ? '<span class="demo-flag" title="Fictieve demonstratiegegevens">Demo</span>' : ""}</header>
    <div class="stack">
      <a class="panel link player" href="#/profiel">
        ${avatar(d.user, "", d.level.level)}
        <div class="grow"><div class="name">${esc(d.user.name)}</div>
          <div class="title">${esc(d.level.title)}</div>
          <div class="row" style="margin-top:6px"><div class="bar xp seg grow"><i data-w="${d.level.progress}"></i></div><span class="tiny muted num">${d.level.xp}/${d.level.next} XP</span></div></div>
      </a>
      <div id="outbox-slot"></div>
      <section class="panel">
        <div class="panel-head"><span class="label">Dagmissie</span><span class="tag">${t.goal} deuren</span></div>
        <div class="mission">
          <div class="ring" style="--p:${pct}"><div><b class="num">${t.doors}</b><small>/ ${t.goal}</small></div></div>
          <div class="grid2 grow" style="gap:14px 10px">
            <div class="stat c-gold"><b class="num">${t.points}</b><span>Punten</span></div>
            <div class="stat"><b class="num">${t.conversations}</b><span>Gesprekken</span></div>
            <div class="stat"><b class="num">${t.phones}</b><span>Nummers</span></div>
            <div class="stat"><b class="num">${t.appointments}</b><span>Afspraken</span></div>
          </div>
        </div>
        <p class="msg">${esc(msg)}</p>
      </section>
      <div class="stack">
        ${d.round
          ? `<a class="btn primary xl block" href="#/ronde">${icon("play")} Ronde bezig · ${plural(d.round.doors, "deur", "deuren")}</a>`
          : `<button class="btn primary xl block glow" id="start">${icon("play")} Start prospecteren</button>`}
        <a class="btn outline xl block" href="#/registreer">${icon("plus")} Registreer bezoek</a>
      </div>
      <div class="grid2">
        <a class="panel link" href="#/ranglijst">
          <div class="panel-head"><span class="label">Week</span>${icon("trophy", "sm")}</div>
          <div class="big-rank num">${w.rank ? "#" + w.rank : "–"}<small> / ${w.of}</small></div>
          <div class="small muted" style="margin-top:6px">${w.rank === 1 ? "Je leidt de week" : w.gap_to_next != null ? `<b class="pts">${w.gap_to_next} pt</b> tot de volgende plek` : `${w.points} punten`}</div>
        </a>
        ${d.competition ? `<a class="panel link" href="#/ranglijst?period=competition">
          <div class="panel-head"><span class="label">${esc(d.competition.name)}</span>${icon("crown", "sm")}</div>
          <div class="big-rank num">${d.competition.rank ? "#" + d.competition.rank : "–"}<small> / ${d.competition.of}</small></div>
          <div class="small muted" style="margin-top:6px">Nog ${plural(d.competition.days_left, "dag", "dagen")}</div>
        </a>` : `<div class="panel"><div class="panel-head"><span class="label">Weekdoel</span></div><div class="big-rank num">${w.doors}<small> / ${w.goal}</small></div></div>`}
      </div>
      <section class="panel" style="padding-bottom:6px">
        <div class="panel-head"><span class="label">Opvolgingen</span>
          ${fu.overdue ? `<span class="tag red">${fu.overdue} te laat</span>` : ""}<a class="tag" href="#/opvolgingen">${fu.open} open</a></div>
        ${fu.items.length ? `<div style="margin:0 -14px">${followUpRows(fu.items)}</div>`
          : `<p class="small muted" style="margin:0 0 10px">Niets deze week. Hoor je aan de deur iets interessants? Zet een opvolging.</p>`}
      </section>
      ${ch ? `<section class="panel">
        <div class="panel-head"><span class="label">${icon("target", "sm")} Uitdaging</span><span class="tag ${ch.done ? "t-appointment" : ""}">${ch.done ? "Voltooid" : ch.period === "day" ? "Vandaag" : "Deze week"}</span></div>
        <div style="font-weight:800;font-size:16.5px">${esc(ch.title)}</div>
        <div class="row" style="margin-top:10px"><div class="bar seg grow"><i data-w="${ch.progress / ch.target}"></i></div><b class="num">${ch.progress}/${ch.target}</b></div>
      </section>` : ""}
      ${teamCh && teamCh !== ch ? `<section class="panel">
        <div class="panel-head"><span class="label">${icon("team", "sm")} Teamdoel</span><span class="tiny muted">${esc(d.team.name)}</span></div>
        <div style="font-weight:700">${esc(teamCh.title)}</div>
        <div class="row" style="margin-top:10px"><div class="bar teal grow"><i data-w="${teamCh.progress / teamCh.target}"></i></div><b class="num">${teamCh.progress}/${teamCh.target}</b></div>
      </section>` : ""}
      <section class="panel tight">
        <div class="panel-head" style="margin-bottom:8px"><span class="label">Puntenregels</span><span class="tiny faint">hoogste resultaat telt</span></div>
        <div class="grid4">${Object.keys(RES).map((k) => `<div class="t-${k}" style="text-align:center"><div style="color:var(--t)">${icon(RES[k].icon)}</div><b class="num" style="color:var(--t);font-size:18px">${d.rule[k]}</b><div class="tiny muted">${RES[k].label.split(" ")[0]}</div></div>`).join("")}</div>
        <p class="tiny faint" style="margin:8px 0 0">Herbezoek binnen ${d.rule.cooldown_days} dagen: ${d.rule.revisit_pct}% voor aanbellen of gesprek.</p>
      </section>
    </div>`;
  paintOutbox();
  fillBars();
  on("#start", "click", startRound);
  flushOutbox();
}

async function startRound() {
  await api("POST", "/api/rounds", {});
  buzz();
  go("#/ronde");
}

/* ----------------------------------------------- quick registration --- */

let reg = null;
const DRAFT = "nod_draft";

function newReg(extra = {}) {
  return {
    mode: "new", visitId: null, prospect: null, preview: null, result: null, flyer: false, dnc: false,
    phone: { number: "", source: "direct" }, appt: { date: null, time: null, note: "" },
    fu: { on: false, signal: null, horizon: null, days: null, note: "" },
    client_id: uuid(), saving: false, q: "", nearby: null, locating: false, locErr: null, regHits: [], ...extra,
  };
}
function saveDraft() { if (reg && reg.mode === "new" && (reg.prospect || reg.result)) store.set(DRAFT, { reg, at: Date.now() }); }
function clearDraft() { store.del(DRAFT); }

async function viewRegister(_m, query) {
  loadProspectCache();
  const draft = store.get(DRAFT, null);
  if (query.get("v")) {
    const { visit } = await api("GET", `/api/visits/${query.get("v")}`);
    reg = newReg({
      mode: "edit", visitId: visit.id, result: visit.result, flyer: visit.flyer,
      prospect: { id: visit.prospect_id, address: visit.address, name: visit.name },
      phone: { number: visit.phone ? visit.phone.number : "", source: visit.phone_source || "direct" },
      appt: visit.appointment ? { date: visit.appointment.starts_at.slice(0, 10), time: visit.appointment.starts_at.slice(11, 16), note: visit.appointment.note || "" } : { date: null, time: null, note: "" },
    });
  } else if (query.get("ref")) {
    reg = newReg();
    try { reg.prospect = asProspect((await api("GET", `/api/addresses/${query.get("ref")}`)).address); } catch { /* offline */ }
  } else if (query.get("p")) {
    reg = newReg();
    reg.prospect = S.prospects.find((p) => p.id === +query.get("p")) || { id: +query.get("p"), address: "…" };
  } else if (draft && Date.now() - draft.at < 30 * 60e3) {
    reg = { ...newReg(), ...draft.reg, saving: false };
  } else {
    reg = newReg();
  }
  let round = null;
  try { round = (await api("GET", "/api/rounds/active")).round; } catch { /* offline */ }
  app.innerHTML = `
    <header class="topbar" style="position:sticky;top:0;z-index:5;background:var(--bg)">
      <a class="icon-btn" href="#/" aria-label="Sluiten">${icon("x")}</a>
      <h1>${reg.mode === "edit" ? "Bezoek aanpassen" : "Registreer bezoek"}</h1>
      ${round ? `<a href="#/ronde" class="tag gold">Ronde · ${round.doors}</a>` : ""}
    </header>
    <div class="stack" style="padding-bottom:96px">
      <section id="reg-addr"></section>
      <section id="reg-result"></section>
      <section id="reg-details"></section>
      <section id="reg-fu"></section>
      <p class="error" id="reg-err" role="alert"></p>
    </div>
    <div class="save-bar"><div id="reg-save"></div></div>`;
  paintAll();
  if (reg.prospect && reg.prospect.id) loadPreview();
  const lastRef = store.get("nod_last_ref", null);
  if (!reg.prospect && reg.mode === "new" && lastRef) {
    api("GET", `/api/addresses/${lastRef}/next`).then((r) => {
      const today = ymd(new Date());
      reg.next = r.addresses.filter((a) => {
        const p = a.prospect_id && S.prospects.find((x) => x.id === a.prospect_id);
        return !a.do_not_contact && !(p && p.last_visit && p.last_visit.date === today);
      }).slice(0, 4);
      paintAddrList();
    }).catch(() => {});
  }
  if (!reg.prospect && reg.mode === "new" && autoLocate() && await locationGranted()) locateMe(true);
  refreshProspects().then(() => {
    if (reg.prospect && reg.prospect.id && reg.prospect.address === "…") {
      reg.prospect = S.prospects.find((p) => p.id === reg.prospect.id) || reg.prospect;
      paintAddr();
    }
    if (!reg.prospect) paintAddrList();
  });
}
function paintAll() { paintAddr(); paintResults(); paintDetails(); paintFollowUp(); paintSave(); }

async function loadPreview() {
  const pid = reg.prospect.id;
  try {
    const { prospect } = await api("GET", `/api/prospects/${pid}`);
    if (!reg.prospect || reg.prospect.id !== pid) return;
    reg.prospect = { ...prospect, address_ref: prospect.address_ref || reg.prospect.address_ref, boxes: reg.prospect.boxes };
    reg.preview = prospect.preview;
    paintAddr(); paintResults(); paintSave();
  } catch { /* offline: rule values */ }
}
function pointsFor(res) {
  if (reg.mode === "edit") return null;
  if (reg.preview) return reg.preview.points[res];
  return S.rule[res];
}

function paintAddr() {
  const el = $("#reg-addr");
  if (!el) return;
  const p = reg.prospect;
  const head = '<div class="step"><b>01</b><span class="label">Adres</span></div>';
  if (!p) {
    el.innerHTML = `${head}<div class="row"><div class="search grow">${icon("search")}<input id="addr-q" class="input" placeholder="Zoek of typ straat + nummer" autocomplete="off" enterkeyhint="go" value="${esc(reg.q)}"></div>
      <button class="icon-btn" id="locate" aria-label="Gebruik mijn locatie" style="width:50px;height:50px;color:var(--red)">${icon("locate")}</button></div>
      <div id="addr-list" class="stack" style="margin-top:10px"></div>`;
    paintAddrList();
    const input = $("#addr-q");
    let timer;
    input.addEventListener("input", () => {
      reg.q = input.value; paintAddrList();
      clearTimeout(timer);
      timer = setTimeout(searchRegister, 220);
    });
    on("#locate", "click", () => locateMe(false));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); const first = $("#addr-list [data-pick]:not(:disabled)"); if (first) first.click(); }
    });
    return;
  }
  const pv = reg.preview;
  let warn = "";
  if (p.do_not_contact) warn = `<div class="notice warn">${icon("ban")}<span>Dit adres staat op ‘Niet meer contacteren’.</span></div>`;
  else if (pv && pv.visited_today) warn = `<div class="notice">${icon("check")}<span>Vandaag al geregistreerd als ${esc(RES[pv.today_result].label.toLowerCase())}. Verbeter gerust: je krijgt het verschil.</span></div>`;
  else if (pv && pv.recent_date) warn = `<div class="notice warn">${icon("alert")}<span>Herbezoek: ${esc(firstName(pv.recent_by))} belde hier ${esc(ago(pv.recent_date))} aan. Aanbellen of gesprek telt voor ${S.rule.revisit_pct}%.</span></div>`;
  el.innerHTML = `${head}<div class="picked">
      <span style="color:var(--red)">${icon("pin", "lg")}</span>
      <div class="grow"><div class="title">${esc(p.address)}</div>
        <div class="small muted">${p.id ? [p.name, p.last_visit ? `${RES[p.last_visit.result].label} ${ago(p.last_visit.date)}` : "Nog niet bezocht"].filter(Boolean).map(esc).join(" · ") : "Nieuw adres"}</div></div>
      ${reg.mode === "edit" ? "" : '<button class="btn sm outline" id="addr-change">Wijzig</button>'}
    </div>
    ${p.boxes ? `<p class="tiny muted" style="margin:6px 0 0">${p.boxes} wooneenheden achter deze deur</p>` : ""}
    ${reg.nearby && reg.nearby.length > 1 && reg.mode === "new" ? `<div style="margin-top:10px"><span class="label">Niet juist? Hier vlakbij</span>
      <div class="chips scroll" style="margin-top:8px">${reg.nearby.filter((a) => a.label !== p.address).slice(0, 5).map((a, i) => `<button class="chip" data-alt="${i}">${esc(a.street)} ${esc(a.number)}${a.distance != null ? ` · ${a.distance} m` : ""}</button>`).join("")}</div></div>` : ""}
    ${warn ? `<div style="margin-top:10px">${warn}</div>` : ""}`;
  on("[data-alt]", "click", (e) => {
    const alts = reg.nearby.filter((a) => a.label !== p.address);
    pickAddress(asProspect(alts[+e.currentTarget.dataset.alt]));
  });
  on("#addr-change", "click", () => {
    reg.prospect = null; reg.preview = null; reg.nearby = null; saveDraft();
    paintAll(); $("#addr-q").focus();
  });
}

function pickAddress(p) {
  reg.prospect = p; reg.preview = null; reg.q = "";
  saveDraft(); buzz(10);
  paintAddr(); paintResults(); paintSave();
  if (p.id) loadPreview();
}

async function locateMe(silent) {
  reg.locating = true; reg.locErr = null; paintAddrList();
  try {
    const r = await nearby(60, 6);
    reg.locating = false;
    if (reg.prospect) return;
    const list = r.addresses.filter((a) => !a.do_not_contact);
    reg.nearby = r.addresses;
    reg.locAcc = r.acc;
    reg.locSource = r.source;
    if (list.length && list[0].distance <= 30 && r.acc <= 40) {
      pickAddress(asProspect(list[0]));
      toast(`Adres gevonden op ${list[0].distance} m`);
    } else paintAddrList();
  } catch (e) {
    reg.locating = false;
    reg.locErr = silent ? null : e.message;
    paintAddrList();
  }
}

async function searchRegister() {
  const q = reg.q.trim();
  if (q.length < 2) { reg.regHits = []; return; }
  try {
    const { addresses } = await api("GET", `/api/addresses/search?q=${encodeURIComponent(q)}`);
    if (reg.q.trim() === q) { reg.regHits = addresses; paintAddrList(); }
  } catch { /* offline: cached prospects only */ }
}

function registerItem(a, i, kind) {
  const p = a.prospect_id ? S.prospects.find((x) => x.id === a.prospect_id) : null;
  const sub = a.do_not_contact ? '<span class="tag red">Niet meer contacteren</span>'
    : p && p.last_visit ? `${RES[p.last_visit.result].label} ${ago(p.last_visit.date)} · ${esc(firstName(p.last_visit.by))}` : "Nog niet bezocht";
  return `<button class="item" data-${kind}="${i}" ${a.do_not_contact ? "disabled" : ""}>
    <span class="dot ${p && p.best ? "t-" + p.best : ""}"></span>
    <div class="grow"><div class="title">${esc(a.label)}</div><div class="sub">${sub}${a.boxes ? ` · ${a.boxes} units` : ""}</div></div>
    ${a.distance != null ? `<span class="tag">${a.distance} m</span>` : icon("chev", "sm")}</button>`;
}

function addrItem(p, label) {
  const sub = p.do_not_contact ? '<span class="tag red">Niet meer contacteren</span>'
    : p.last_visit ? `${RES[p.last_visit.result].label} ${ago(p.last_visit.date)} · ${esc(firstName(p.last_visit.by))}` : "Nog niet bezocht";
  return `<button class="item" data-pick="${p.id || ""}" data-addr="${esc(p.address)}" ${p.do_not_contact ? "disabled" : ""}>
    <span class="dot ${p.best ? "t-" + p.best : ""}"></span>
    <div class="grow"><div class="title">${label ? `<span class="label" style="color:var(--red)">${esc(label)}</span> ` : ""}${esc(p.address)}</div><div class="sub">${p.name ? esc(p.name) + " · " : ""}${sub}</div></div>
    ${p.id ? icon("chev", "sm") : `<span class="tag solid-red">${icon("plus", "sm")} Nieuw</span>`}</button>`;
}

function paintAddrList() {
  const el = $("#addr-list");
  if (!el) return;
  const q = reg.q.trim();
  const recent = store.get("nod_recent", []);
  let html = "";
  if (reg.locating) html += `<div class="notice">${icon("locate")}<span>Locatie zoeken…</span></div>`;
  if (reg.locErr) html += `<div class="notice warn">${icon("alert")}<span>${esc(reg.locErr)}</span></div>`;
  if (!q) {
    if (reg.nearby && reg.nearby.length) {
      html += `<span class="label">Dichtbij jou${reg.locAcc ? ` · ±${reg.locAcc} m` : ""}${reg.locSource === "geopunt" ? " · Geopunt" : ""}</span>
        <div class="list">${reg.nearby.map((a, i) => registerItem(a, i, "near")).join("")}</div>`;
    } else if (reg.nearby) {
      html += '<p class="small muted">Geen adres gevonden op je locatie. Zoek het adres.</p>';
    }
    if (reg.next && reg.next.length) {
      html += `<span class="label">Volgende deuren in de straat</span><div class="list">${reg.next.map((a, i) => registerItem(a, i, "nxt")).join("")}</div>`;
    } else {
      const nexts = nextDoors(recent[0]).map((a) => findCached(a) || { address: a });
      const fresh = nexts.filter((p) => !p.do_not_contact && !(p.last_visit && p.last_visit.date === ymd(new Date()))).slice(0, 3);
      if (fresh.length) html += `<span class="label">Volgende deuren in de straat</span><div class="list">${fresh.map((p) => addrItem(p)).join("")}</div>`;
    }
    const unvisited = S.prospects.filter((p) => !p.best && !p.do_not_contact).slice(0, 4);
    if (unvisited.length && !reg.nearby) html += `<span class="label">Nog niet bezocht</span><div class="list">${unvisited.map((p) => addrItem(p)).join("")}</div>`;
    if (!html) html = `<p class="muted small">Tik op ${icon("locate", "sm")} om het adres te vinden waar je staat, of typ een straat en huisnummer.</p>`;
  } else {
    const k = addrKey(q);
    const words = k.split(" ");
    const hits = S.prospects.filter((p) => words.every((w) => addrKey(p.address + " " + (p.name || "")).includes(w))).slice(0, 6);
    const linked = new Set(hits.map((p) => p.id));
    const reg_ = reg.regHits.filter((a) => !linked.has(a.prospect_id));
    // Offer a free-text address only when neither the list nor the register knows it.
    const exact = hits.length > 0 || reg_.length > 0;
    const lastCity = (recent[0] || "").includes(",") ? recent[0].split(",").slice(1).join(",").trim() : "";
    const newAddr = q.includes(",") || !lastCity || !/\d/.test(q) ? q : `${q}, ${lastCity}`;
    html = `<div class="list">${hits.map((p) => addrItem(p)).join("")}${reg_.map((a, i) => registerItem(a, i, "reg")).join("")}${exact ? "" : addrItem({ address: newAddr }, "Nieuw")}</div>
      ${reg_.length ? '<p class="tiny faint" style="margin:0">Bron: Adressenregister Vlaanderen</p>' : ""}`;
    reg._regShown = reg_;
  }
  el.innerHTML = html;
  on("[data-pick]", "click", (e) => {
    const b = e.currentTarget;
    const id = +b.dataset.pick;
    pickAddress(id ? S.prospects.find((p) => p.id === id) : { address: b.dataset.addr });
  }, el);
  on("[data-near]", "click", (e) => pickAddress(asProspect(reg.nearby[+e.currentTarget.dataset.near])), el);
  on("[data-nxt]", "click", (e) => pickAddress(asProspect(reg.next[+e.currentTarget.dataset.nxt])), el);
  on("[data-reg]", "click", (e) => pickAddress(asProspect(reg._regShown[+e.currentTarget.dataset.reg])), el);
}

function paintResults() {
  const el = $("#reg-result");
  if (!el) return;
  const disabled = !reg.prospect || reg.prospect.do_not_contact;
  el.innerHTML = `<div class="step"><b>02</b><span class="label">Resultaat</span></div>
    <div class="results">${Object.entries(RES).map(([k, r]) => {
      const pts = pointsFor(k);
      const reduced = reg.preview && reg.preview.revisit && pts != null && pts < S.rule[k] && (k === "door" || k === "conversation");
      return `<button class="result t-${k}" data-res="${k}" aria-pressed="${reg.result === k}" ${disabled ? "disabled" : ""}>
        <span class="ic">${icon(r.icon, "lg")}</span><span class="lbl">${r.label}<small>${r.sub}</small></span>
        ${pts == null ? "" : `<span class="p">+${pts}${reduced ? "<small>herbezoek</small>" : ""}</span>`}</button>`;
    }).join("")}</div>`;
  on("[data-res]", "click", (e) => {
    reg.result = e.currentTarget.dataset.res;
    buzz(10); saveDraft();
    paintResults(); paintDetails(); paintFollowUp(); paintSave();
    if (reg.result !== "door") $("#reg-details").scrollIntoView({ behavior: "smooth", block: "start" });
  }, el);
}

function phoneFields() {
  const hint = reg.phone.number.trim() ? "Nummer wordt bij dit adres bewaard." : "Leeg laten mag: het nummer wordt dan <b>niet</b> in de app bewaard.";
  return `<label class="field"><span class="label">Telefoonnummer · optioneel</span>
      <input class="input" id="ph-num" type="tel" inputmode="tel" autocomplete="off" placeholder="0470 12 34 56" value="${esc(reg.phone.number)}"></label>
    <div class="seg" role="group" aria-label="Bron">${Object.entries(SOURCES).map(([k, l]) =>
      `<button type="button" data-src="${k}" aria-pressed="${reg.phone.source === k}">${l}</button>`).join("")}</div>
    <p class="small muted" id="ph-hint" style="margin:0">${hint}</p>`;
}

function paintDetails() {
  const el = $("#reg-details");
  if (!el) return;
  if (!reg.result) { el.innerHTML = ""; return; }
  let html = "";
  if (reg.result === "door") {
    html = `<div class="chips">
      <button class="chip" data-tog="flyer" aria-pressed="${reg.flyer}">${icon("file", "sm")} Flyer achtergelaten</button>
      ${reg.mode === "new" ? `<button class="chip" data-tog="dnc" aria-pressed="${reg.dnc}">${icon("ban", "sm")} Niet meer contacteren</button>` : ""}</div>`;
  } else if (reg.result === "conversation") {
    html = "";
  } else if (reg.result === "phone") {
    html = `<div class="details stack">${phoneFields()}</div>`;
  } else {
    const days = [...Array(8)].map((_, i) => addDays(i));
    const times = ["09:00", "10:00", "11:00", "13:00", "14:00", "16:00", "17:00", "18:00", "19:00", "19:30", "20:00"];
    html = `<div class="details stack">
      <div><span class="label">Datum</span>
        <div class="chips scroll" style="margin-top:8px">${days.map((d, i) => `<button class="chip" data-date="${d}" aria-pressed="${reg.appt.date === d}">${i === 0 ? "Vandaag" : i === 1 ? "Morgen" : fmtDate(d)}</button>`).join("")}
        <input type="date" class="chip" id="ap-date-other" aria-label="Andere datum" min="${ymd(new Date())}"></div></div>
      <div><span class="label">Uur</span>
        <div class="time-grid" style="margin-top:8px">${times.map((t) => `<button class="chip" data-time="${t}" aria-pressed="${reg.appt.time === t}">${t}</button>`).join("")}
        <input class="chip" type="time" id="ap-time" aria-label="Ander uur" value="${times.includes(reg.appt.time) ? "" : esc(reg.appt.time || "")}"></div></div>
      ${reg.appt.date && !days.includes(reg.appt.date) ? `<p class="small" style="margin:0">Gekozen: <b>${fmtDate(reg.appt.date)}</b></p>` : ""}
      <label class="field"><span class="label">Korte notitie · optioneel</span>
        <input class="input" id="ap-note" maxlength="280" placeholder="bv. partner ook aanwezig" value="${esc(reg.appt.note)}"></label>
      <details ${reg.phone.number ? "open" : ""}><summary class="label" style="cursor:pointer;padding:6px 0">+ Telefoonnummer toevoegen</summary><div class="stack" style="margin-top:8px">${phoneFields()}</div></details>
    </div>`;
  }
  el.innerHTML = html;
  on("[data-tog]", "click", (e) => {
    const k = e.currentTarget.dataset.tog; reg[k] = !reg[k];
    e.currentTarget.setAttribute("aria-pressed", reg[k]);
    if (k === "dnc" && reg.dnc) { reg.fu.on = false; paintFollowUp(); }
    saveDraft();
  }, el);
  on("[data-src]", "click", (e) => { reg.phone.source = e.currentTarget.dataset.src; $$("[data-src]", el).forEach((b) => b.setAttribute("aria-pressed", b === e.currentTarget)); saveDraft(); }, el);
  on("#ph-num", "input", (e) => {
    reg.phone.number = e.target.value; saveDraft();
    $("#ph-hint").innerHTML = reg.phone.number.trim() ? "Nummer wordt bij dit adres bewaard." : "Leeg laten mag: het nummer wordt dan <b>niet</b> in de app bewaard.";
  }, el);
  const rerender = () => { saveDraft(); paintDetails(); paintSave(); };
  on("[data-date]", "click", (e) => { reg.appt.date = e.currentTarget.dataset.date; rerender(); }, el);
  on("#ap-date-other", "change", (e) => { if (e.target.value) { reg.appt.date = e.target.value; rerender(); } }, el);
  on("[data-time]", "click", (e) => { reg.appt.time = e.currentTarget.dataset.time; rerender(); }, el);
  on("#ap-time", "change", (e) => { if (e.target.value) { reg.appt.time = e.target.value; rerender(); } }, el);
  on("#ap-note", "input", (e) => { reg.appt.note = e.target.value; saveDraft(); }, el);
}

function followUpFields(fu, prefix = "fu") {
  const days = fu.days ?? (fu.horizon ? HORIZON_DAYS[fu.horizon] : null);
  return `<div><span class="label">Wat hoorde je?</span>
      <div class="chips" style="margin-top:8px">${Object.entries(SIGNALS).map(([k, l]) => `<button type="button" class="chip" data-${prefix}-sig="${k}" aria-pressed="${fu.signal === k}">${l}</button>`).join("")}</div></div>
    <div><span class="label">Termijn</span>
      <div class="chips" style="margin-top:8px">${Object.entries(HORIZONS).map(([k, l]) => `<button type="button" class="chip" data-${prefix}-hor="${k}" aria-pressed="${fu.horizon === k}">${l}</button>`).join("")}</div></div>
    <div><span class="label">Opnieuw contacteren over</span>
      <div class="chips" style="margin-top:8px">${FOLLOW_IN.map(([n, l]) => `<button type="button" class="chip" data-${prefix}-in="${n}" aria-pressed="${days === n}">${l}</button>`).join("")}</div></div>
    <label class="field"><span class="label">Notitie · optioneel</span><input class="input" data-${prefix}-note maxlength="280" placeholder="bv. denkt aan verkopen als de kinderen uit huis zijn" value="${esc(fu.note || "")}"></label>`;
}
function bindFollowUpFields(root, fu, prefix, onChange) {
  on(`[data-${prefix}-sig]`, "click", (e) => { fu.signal = e.currentTarget.dataset[`${prefix}Sig`]; onChange(); }, root);
  on(`[data-${prefix}-hor]`, "click", (e) => { fu.horizon = e.currentTarget.dataset[`${prefix}Hor`]; fu.days = null; onChange(); }, root);
  on(`[data-${prefix}-in]`, "click", (e) => { fu.days = +e.currentTarget.dataset[`${prefix}In`]; onChange(); }, root);
  on(`[data-${prefix}-note]`, "input", (e) => { fu.note = e.target.value; saveDraft(); }, root);
}
const followUpPayload = (fu) => ({
  signal: fu.signal, horizon: fu.horizon || undefined, note: fu.note || undefined,
  due_on: fu.days ? addDays(fu.days) : undefined,
});

function paintFollowUp() {
  const el = $("#reg-fu");
  if (!el) return;
  if (!reg.result || reg.mode === "edit" || reg.dnc) { el.innerHTML = ""; return; }
  el.innerHTML = `<button class="followup-toggle" id="fu-toggle" aria-pressed="${reg.fu.on}">
      <span class="ic">${icon("star", "lg")}</span>
      <span class="grow"><b>Interessant signaal?</b><br><span class="small muted">Verkoopplannen, schatting, verhuis… zet een opvolging</span></span>
      ${reg.fu.on ? icon("check") : icon("plus")}</button>
    ${reg.fu.on ? `<div class="details stack" style="margin-top:8px">${followUpFields(reg.fu)}</div>` : ""}`;
  on("#fu-toggle", "click", () => { reg.fu.on = !reg.fu.on; saveDraft(); paintFollowUp(); paintSave(); }, el);
  bindFollowUpFields(el, reg.fu, "fu", () => { saveDraft(); paintFollowUp(); paintSave(); });
}

function canSave() {
  if (!reg.prospect || !reg.result || reg.saving || reg.prospect.do_not_contact) return false;
  if (reg.result === "appointment" && !(reg.appt.date && reg.appt.time)) return false;
  if (reg.fu.on && !reg.fu.signal) return false;
  return true;
}

function paintSave() {
  const el = $("#reg-save");
  if (!el) return;
  const pts = reg.result ? pointsFor(reg.result) : null;
  const label = reg.saving ? "Opslaan…" : !reg.prospect ? "Kies eerst een adres" : !reg.result ? "Kies een resultaat"
    : reg.result === "appointment" && !(reg.appt.date && reg.appt.time) ? "Kies datum en uur"
      : reg.fu.on && !reg.fu.signal ? "Kies wat er interessant is"
        : `Opslaan${pts != null ? ` · +${pts}` : ""}${reg.fu.on ? " · opvolging" : ""}`;
  el.innerHTML = `<button class="btn primary xl block" id="save" ${canSave() ? "" : "disabled"}>${esc(label)}</button>`;
  on("#save", "click", saveVisit, el);
}

function regPayload() {
  const p = { client_id: reg.client_id, result: reg.result, flyer: reg.result === "door" && reg.flyer, visited_at: new Date().toISOString() };
  if (reg.prospect.id) p.prospect_id = reg.prospect.id;
  else {
    p.new_prospect = { address: reg.prospect.address };
    if (reg.prospect.address_ref) p.new_prospect.address_ref = reg.prospect.address_ref;
    if (reg.prospect.lat != null) Object.assign(p.new_prospect, { lat: reg.prospect.lat, lon: reg.prospect.lon });
  }
  if (reg.result === "phone" || reg.result === "appointment") {
    p.phone = { source: reg.phone.source };
    if (reg.phone.number.trim()) p.phone.number = reg.phone.number.trim();
  }
  if (reg.result === "appointment") p.appointment = { date: reg.appt.date, time: reg.appt.time, note: reg.appt.note };
  if (reg.result === "door" && reg.dnc) p.do_not_contact = true;
  else if (reg.fu.on && reg.mode === "new") p.follow_up = followUpPayload(reg.fu);
  return p;
}

async function saveVisit() {
  if (!canSave()) return;
  reg.saving = true;
  $("#reg-err").textContent = "";
  paintSave();
  const payload = regPayload();
  try {
    if (reg.mode === "edit") {
      const data = await api("PATCH", `/api/visits/${reg.visitId}`, payload);
      buzz(40);
      showReward(data, { edit: true });
      return;
    }
    const out = await sendRegistration({ client_id: reg.client_id, payload, address: reg.prospect.address, created: Date.now() });
    clearDraft();
    rememberAddress(reg.prospect.address);
    if (reg.prospect.address_ref) store.set("nod_last_ref", reg.prospect.address_ref); else store.del("nod_last_ref");
    buzz(40);
    if (out.queued) showQueued(reg.prospect.address, reg.result);
    else showReward(out.data, {});
    refreshProspects();
  } catch (e) {
    reg.saving = false;
    $("#reg-err").textContent = e.message;
    if (e.code === "do_not_contact" && reg.prospect) { reg.prospect.do_not_contact = true; paintAddr(); paintResults(); }
    paintSave();
  }
}

/* ------------------------------------------------------- reward --- */

function closeLayer() { layer.innerHTML = ""; }

function sparks(n = 22) {
  const colors = ["#d60a29", "#ffffff", "#ffc53d", "#5ce1e6"];
  return `<div class="sparks" aria-hidden="true">${[...Array(n)].map((_, i) =>
    `<i style="background:${colors[i % 4]};--r:${(360 / n) * i}deg;--d:${-(90 + Math.random() * 70)}px;animation-delay:${Math.random() * .12}s"></i>`).join("")}</div>`;
}

function showReward(data, opt) {
  const v = data.visit;
  const t = data.today;
  const pct = Math.min(1, t.doors / Math.max(1, t.goal));
  const reached = t.doors >= t.goal;
  const party = data.new_badges.length || data.level_up || data.completed_challenges.length || v.result === "appointment" || (reached && t.doors === t.goal);
  const rk = data.rank;
  const rankLine = !rk.after ? "" : rk.before && rk.after < rk.before
    ? `${icon("up", "sm")} Je stijgt naar <b>#${rk.after}</b> deze week`
    : rk.after === 1 ? `${icon("crown", "sm")} Je leidt de week` : `Je staat <b>#${rk.after}</b> deze week`;
  const pts = data.points;
  const head = data.already_saved ? "Al opgeslagen" : opt.edit ? (pts > 0 ? "Verbeterd" : "Aangepast") : data.merged ? "Bezoek bijgewerkt" : RES[v.result].label;
  layer.innerHTML = `<div class="overlay" role="dialog" aria-modal="true" aria-label="Opgeslagen">
    <div class="sheet stack t-${v.result}">
      <div class="burst">${party ? sparks() : ""}
        <div class="tier">${data.reduced ? "Herbezoek" : esc(head)}</div>
        <div class="plus num ${pts === 0 ? "zero" : ""}" id="plus">${pts > 0 ? "+" : ""}${pts}</div>
        <div class="what">${esc(v.address)}</div>
        <div class="small muted">${icon("check", "sm")} Opgeslagen${v.flyer ? " · flyer" : ""}${data.follow_up ? " · opvolging gezet" : ""}
          ${v.result === "phone" && v.phone_status === "not_stored" ? " · nummer niet in app bewaard" : ""}${v.phone_status === "known" ? " · nummer was al bekend" : ""}</div>
      </div>
      ${data.notes.map((n) => `<div class="notice small">${icon("alert", "sm")}<span>${esc(n)}</span></div>`).join("")}
      <div class="panel tight stack" style="background:var(--surface-2)">
        <div class="row spread"><span class="label">${reached ? "Dagmissie voltooid" : "Dagmissie"}</span><span class="num small"><b>${t.doors}</b> / ${t.goal} deuren · <b class="pts">${t.points} pt</b></span></div>
        <div class="bar seg"><i id="rbar"></i></div>
        ${rankLine ? `<div class="small row" style="gap:6px">${rankLine}</div>` : ""}
      </div>
      ${data.follow_up ? `<div class="unlock" style="animation-delay:.15s"><span class="hex" style="--t:var(--gold)">${icon("star")}</span><div><div class="label">Opvolging</div><b>${esc(data.follow_up.signal_label)}</b><div class="small muted">Contact opnieuw ${esc(fmtLong(data.follow_up.due_on))}</div></div></div>` : ""}
      ${data.level_up ? `<div class="unlock"><span class="hex">${icon("bolt")}</span><div><div class="label">Level up</div><b>Level ${data.level.level} · ${esc(data.level.title)}</b></div></div>` : ""}
      ${data.new_badges.map((b) => `<div class="unlock"><span class="hex">${icon(b.icon)}</span><div><div class="label">Badge vrijgespeeld</div><b>${esc(b.name)}</b><div class="small muted">${esc(b.desc)}</div></div></div>`).join("")}
      ${data.completed_challenges.map((c) => `<div class="unlock"><span class="hex" style="--t:var(--diamond)">${icon("target")}</span><div><div class="label">Uitdaging voltooid</div><b>${esc(c.title)}</b></div></div>`).join("")}
      ${opt.edit ? `<button class="btn primary xl block" id="r-done">Klaar</button>`
        : `<button class="btn primary xl block" id="r-next">Volgende deur ${icon("chev")}</button>
           <button class="btn ghost block" id="r-done">${data.round ? "Terug naar ronde" : "Naar mijn dag"}</button>`}
    </div></div>`;
  requestAnimationFrame(() => requestAnimationFrame(() => { $("#rbar").style.width = `${pct * 100}%`; }));
  countUp($("#plus"), pts);
  on("#r-next", "click", () => { closeLayer(); reg = newReg(); viewRegister(null, new URLSearchParams()); }, layer);
  on("#r-done", "click", () => { closeLayer(); if (opt.edit) history.back(); else go(data.round ? "#/ronde" : "#/"); }, layer);
}

function countUp(el, to) {
  if (!el || to <= 0 || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const t0 = performance.now(), dur = 650;
  const step = (now) => {
    const k = Math.min(1, (now - t0) / dur);
    el.textContent = "+" + Math.round(to * (1 - Math.pow(1 - k, 3)));
    if (k < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

function showQueued(address, result) {
  layer.innerHTML = `<div class="overlay" role="dialog" aria-modal="true"><div class="sheet stack">
    <div class="burst"><div class="tier" style="color:var(--muted)">Offline</div><div class="plus zero">${icon("cloudoff", "lg")}</div>
      <div class="what">Bewaard op je toestel</div><div class="small muted">${esc(address)} · ${esc(RES[result].label)}</div></div>
    <div class="notice warn">${icon("clock")}<span>Geen verbinding. Het bezoek wordt automatisch verstuurd zodra je weer online bent. Je punten volgen dan.</span></div>
    <button class="btn primary xl block" id="r-next">Volgende deur ${icon("chev")}</button>
    <button class="btn ghost block" id="r-done">Naar mijn dag</button></div></div>`;
  on("#r-next", "click", () => { closeLayer(); reg = newReg(); viewRegister(null, new URLSearchParams()); }, layer);
  on("#r-done", "click", () => { closeLayer(); go("#/"); }, layer);
}

/* ------------------------------------------------------------ round --- */

async function viewRound() {
  const { round } = await api("GET", "/api/rounds/active");
  if (!round) {
    const goal = (S.dash && S.dash.today.goal) || S.me.daily_goal || 10;
    app.innerHTML = `${backBar("#/", "Prospectieronde")}
      <div class="panel stack" style="text-align:center">
        <span class="hex" style="margin:4px auto 0;--t:var(--red)">${icon("flag")}</span>
        <h2>Klaar om te vertrekken?</h2>
        <p class="muted" style="margin:0">Kies je doel. Onderweg kan je spontaan nieuwe adressen toevoegen.</p>
        <div class="row" style="justify-content:center;gap:22px;margin:8px 0">
          <button class="icon-btn" id="g-min" aria-label="Minder">−</button>
          <div><b class="num" id="g-val" style="font-size:52px;font-weight:900;line-height:1">${goal}</b><div class="label">deuren</div></div>
          <button class="icon-btn" id="g-plus" aria-label="Meer">${icon("plus")}</button></div>
        <button class="btn primary xl block glow" id="go">${icon("play")} Start ronde</button>
      </div>`;
    let g = goal;
    const set = (n) => { g = Math.max(1, Math.min(200, n)); $("#g-val").textContent = g; };
    on("#g-min", "click", () => set(g - 1));
    on("#g-plus", "click", () => set(g + 1));
    on("#go", "click", async () => { await api("POST", "/api/rounds", { goal: g }); buzz(); router(); });
    return;
  }
  let visits = [];
  try { visits = (await api("GET", "/api/visits/today")).visits.filter((v) => v.visited_at >= round.started_at); } catch { /* ignore */ }
  app.innerHTML = `${backBar("#/", "Ronde bezig", `<span class="tag gold">${icon("clock", "sm")} ${round.minutes} min</span>`)}
    <div class="stack">
      <section class="panel stack">
        <div class="row" style="align-items:flex-end;gap:8px"><span class="num" style="font-size:64px;font-weight:900;line-height:.9">${round.doors}</span><span class="label" style="padding-bottom:6px">/ ${round.goal} deuren</span></div>
        <div class="bar seg"><i data-w="${round.doors / round.goal}"></i></div>
        <div class="grid4"><div class="stat c-gold"><b class="num">${round.points}</b><span>Punten</span></div><div class="stat"><b class="num">${round.conversations}</b><span>Gesprek</span></div><div class="stat"><b class="num">${round.phones}</b><span>Nummers</span></div><div class="stat"><b class="num">${round.appointments}</b><span>Afspr.</span></div></div>
      </section>
      <a class="btn primary xl block" href="#/registreer">${icon("plus")} Registreer bezoek</a>
      ${visits.length ? `<span class="label">Deze ronde</span><div class="list">${visits.map((v) => `<a class="item" href="#/prospect/${v.prospect_id}">
        <span class="dot t-${v.result}"></span><div class="grow"><div class="title">${esc(v.address)}</div><div class="sub">${RES[v.result].label}${v.flyer ? " · flyer" : ""}${v.reduced ? " · herbezoek" : ""}</div></div>
        <span class="pts">+${v.points}</span></a>`).join("")}</div>` : '<p class="muted" style="text-align:center">Nog geen deuren in deze ronde. De eerste is de moeilijkste.</p>'}
      <button class="btn outline block" id="end">Ronde afsluiten</button>
    </div>`;
  fillBars();
  on("#end", "click", async () => {
    const { summary } = await api("POST", `/api/rounds/${round.id}/end`);
    showSummary(summary);
  });
}

function showSummary(s) {
  const party = s.doors >= s.goal || s.record || s.appointments;
  app.innerHTML = `<header class="topbar"><h1>Ronde voltooid</h1></header>
    <div class="stack">
      <section class="panel stack burst" style="text-align:center;padding:24px 16px">${party ? sparks(26) : ""}
        <div class="tier" style="color:var(--gold)">${s.doors >= s.goal ? "Doel gehaald" : "Ronde afgesloten"}</div>
        <div class="num" style="font-size:72px;font-weight:900;line-height:1">${s.doors}<span class="label" style="font-size:14px"> deuren</span></div>
        <h2>${esc(s.message)}</h2>
        ${s.record ? `<div class="row" style="justify-content:center"><span class="tag gold">${icon("medal", "sm")} Persoonlijk record</span></div>` : ""}
        <div class="grid4" style="margin-top:6px">
          <div class="stat c-gold"><b class="num">${s.points}</b><span>Punten</span></div><div class="stat"><b class="num">${s.conversations}</b><span>Gesprek</span></div>
          <div class="stat"><b class="num">${s.phones}</b><span>Nummers</span></div><div class="stat"><b class="num">${s.appointments}</b><span>Afspr.</span></div></div>
        <p class="small muted" style="margin:0">${s.minutes} min · doel ${s.goal}${s.flyers ? ` · ${plural(s.flyers, "flyer", "flyers")}` : ""}</p>
      </section>
      <a class="btn primary xl block" href="#/ranglijst">${icon("trophy")} Bekijk de ranking</a>
      <a class="btn ghost block" href="#/">Naar mijn dag</a>
    </div>`;
}

/* -------------------------------------------------------- prospects --- */

const FILTERS = [["", "Alle"], ["near", "In de buurt"], ["unvisited", "Nog niet bezocht"], ["door", "Aangebeld"], ["conversation", "Gesprek"], ["phone", "Telefoon"], ["appointment", "Afspraak"], ["fu", "Opvolging"], ["dnc", "Niet contacteren"]];
const listTabs = (cur) => `<div class="seg"><button data-href="#/prospecten" aria-pressed="${cur === "p"}">Adressen</button><button data-href="#/opvolgingen" aria-pressed="${cur === "f"}">Opvolgingen</button></div>`;

async function viewProspects(_m, query) {
  loadProspectCache();
  let filter = query.get("f") || "";
  let q = "";
  app.innerHTML = `<header class="topbar"><h1>Adressen</h1><button class="btn sm primary" id="add">${icon("plus", "sm")} Adres</button></header>
    <div class="stack">
      ${listTabs("p")}
      <div class="search">${icon("search")}<input class="input" id="pq" type="search" placeholder="Zoek adres of naam" autocomplete="off"></div>
      <div class="chips scroll">${FILTERS.map(([k, l]) => `<button class="chip" data-f="${k}" aria-pressed="${filter === k}">${l}</button>`).join("")}</div>
      <div id="add-form"></div>
      <div id="plist"></div>
    </div>`;
  on("[data-href]", "click", (e) => go(e.currentTarget.dataset.href));
  let near = null, nearErr = null, nearBusy = false;
  const paintNear = () => {
    $("#plist").innerHTML = nearBusy ? `<div class="notice">${icon("locate")}<span>Locatie zoeken…</span></div>`
      : nearErr ? `<div class="notice warn">${icon("alert")}<span>${esc(nearErr)}</span></div>`
        : !near || !near.addresses.length ? '<p class="muted">Geen adressen gevonden in de buurt. Is jullie regio ingesteld?</p>'
          : `<p class="label" style="margin:0 0 8px">${near.addresses.length} deuren binnen 150 m · ±${near.acc} m${near.source === "geopunt" ? " · Geopunt" : ""}</p>
            <div class="list">${near.addresses.map((a) => {
              const p = a.prospect_id ? S.prospects.find((x) => x.id === a.prospect_id) : null;
              const href = a.prospect_id ? `#/prospect/${a.prospect_id}` : a.id ? `#/registreer?ref=${a.id}` : "#/registreer";
              return `<a class="item" href="${href}"><span class="dot ${p && p.best ? "t-" + p.best : ""}"></span>
                <div class="grow"><div class="title">${esc(a.street)} ${esc(a.number)}</div><div class="sub">${a.do_not_contact ? '<span class="tag red">Niet contacteren</span>' : p && p.last_visit ? `${RES[p.last_visit.result].label} ${ago(p.last_visit.date)}` : "Nog niet bezocht"}</div></div>
                <span class="tag">${a.distance} m</span></a>`;
            }).join("")}</div>`;
  };
  const loadNear = async () => {
    nearBusy = true; nearErr = null; paintNear();
    try { near = await nearby(150, 30); } catch (e) { nearErr = e.message; }
    nearBusy = false;
    if (filter === "near") paintNear();
  };
  const paint = () => {
    if (filter === "near") return paintNear();
    const words = addrKey(q).split(" ").filter(Boolean);
    const list = S.prospects.filter((p) => {
      if (words.length && !words.every((w) => addrKey(p.address + " " + (p.name || "")).includes(w))) return false;
      if (filter === "dnc") return p.do_not_contact;
      if (filter && p.do_not_contact) return false;
      if (filter === "unvisited") return !p.best;
      if (filter === "fu") return !!p.follow_up;
      if (filter) return p.best === filter;
      return true;
    });
    $("#plist").innerHTML = list.length ? `<p class="label" style="margin:0 0 8px">${plural(list.length, "adres", "adressen")}</p>
      <div class="list">${list.map((p) => `<div class="item">
        <span class="dot ${p.best ? "t-" + p.best : ""}"></span>
        <a class="grow" href="#/prospect/${p.id}" style="text-decoration:none"><div class="title">${esc(p.address)}${p.is_demo ? ' <span class="tiny faint">demo</span>' : ""}</div>
          <div class="sub">${p.name ? esc(p.name) + " · " : ""}${p.do_not_contact ? '<span class="tag red">Niet contacteren</span>'
            : p.follow_up ? `<span style="color:var(--gold)">★ ${esc(SIGNALS[p.follow_up.signal])}</span> · ${fmtDate(p.follow_up.due_on)}`
              : p.appointment ? `Afspraak ${fmtDT(p.appointment)}` : p.last_visit ? `${RES[p.last_visit.result].label} ${ago(p.last_visit.date)}` : "Nog niet bezocht"}</div></a>
        <a class="icon-btn" href="${mapsUrl(p.address)}" target="_blank" rel="noopener" aria-label="Navigeer naar ${esc(p.address)}">${icon("nav")}</a>
      </div>`).join("")}</div>` : '<p class="muted">Geen adressen gevonden.</p>';
  };
  paint();
  refreshProspects().then(paint);
  on("#pq", "input", (e) => { q = e.target.value; if (filter === "near") { filter = ""; $$("[data-f]").forEach((b) => b.setAttribute("aria-pressed", b.dataset.f === "")); } paint(); });
  if (filter === "near") loadNear();
  on("[data-f]", "click", (e) => {
    filter = e.currentTarget.dataset.f;
    $$("[data-f]").forEach((b) => b.setAttribute("aria-pressed", b === e.currentTarget));
    if (filter === "near") loadNear(); else paint();
  });
  on("#add", "click", () => {
    $("#add-form").innerHTML = `<form class="panel stack" id="af">
      <label class="field"><span class="label">Adres</span><input class="input" name="address" required maxlength="160" placeholder="Straat nr, gemeente"></label>
      <label class="field"><span class="label">Naam · optioneel</span><input class="input" name="name" maxlength="80"></label>
      <p class="error" id="aerr"></p><button class="btn primary block">Adres opslaan</button></form>`;
    $("#af input").focus();
    on("#af", "submit", async (e) => {
      e.preventDefault();
      try { const { prospect } = await api("POST", "/api/prospects", Object.fromEntries(new FormData(e.target))); go(`#/prospect/${prospect.id}`); }
      catch (err) { $("#aerr").textContent = err.message; }
    });
  });
}

/* ------------------------------------------------------ follow-ups --- */

async function viewFollowUps(_m, query) {
  const scope = query.get("scope") || "mine";
  const status = query.get("status") || "open";
  const { follow_ups: list } = await api("GET", `/api/follow-ups?scope=${scope}&status=${status}`);
  const link = (s, st) => `#/opvolgingen?scope=${s}&status=${st}`;
  const today = ymd(new Date()), week = addDays(7);
  const groups = status === "open"
    ? [["Te laat", list.filter((f) => f.due_on < today)], ["Deze week", list.filter((f) => f.due_on >= today && f.due_on <= week)], ["Later", list.filter((f) => f.due_on > week)]]
    : [[status === "done" ? "Afgerond" : "Geannuleerd", list]];
  const card = (f) => `<div class="fu" data-fu="${f.id}">
    <span class="ic">${icon("star")}</span>
    <div class="grow stack">
      <a href="#/prospect/${f.prospect_id}" style="text-decoration:none;display:block"><div class="row spread"><b>${esc(f.address)}</b>${status === "open" ? dueLabel(f.due_on) : ""}</div>
        <div class="small muted">${esc(f.signal_label)}${f.horizon_label ? ` · ${esc(f.horizon_label.toLowerCase())}` : ""}${scope === "team" ? ` · ${esc(firstName(f.owner))}` : ""}</div>
        ${f.note ? `<div class="small">“${esc(f.note)}”</div>` : ""}</a>
      ${status === "open" && (f.user_id === S.me.id || S.me.role === "admin") ? `<div class="row wrap" style="gap:6px">
        <a class="btn sm primary" href="#/registreer?p=${f.prospect_id}">${icon("door", "sm")} Bezoek</a>
        ${f.phone ? `<a class="btn sm outline" href="tel:${esc(f.phone.replace(/\s/g, ""))}">${icon("phone", "sm")} Bel</a>` : ""}
        <button class="btn sm outline" data-done>${icon("check", "sm")} Gedaan</button>
        <button class="btn sm ghost" data-snooze>${icon("snooze", "sm")} Later</button></div>
        <div class="chips hidden" data-snooze-opts>${FOLLOW_IN.map(([n, l]) => `<button class="chip" data-in="${n}">+ ${l}</button>`).join("")}</div>` : ""}
    </div></div>`;
  app.innerHTML = `<header class="topbar"><h1>Opvolgingen</h1></header>
    <div class="stack">
      ${listTabs("f")}
      <div class="row"><div class="seg grow">${[["mine", "Mijn"], ["team", "Team"]].map(([k, l]) => `<button data-href="${link(k, status)}" aria-pressed="${scope === k}">${l}</button>`).join("")}</div>
        <div class="seg grow">${[["open", "Open"], ["done", "Gedaan"]].map(([k, l]) => `<button data-href="${link(scope, k)}" aria-pressed="${status === k}">${l}</button>`).join("")}</div></div>
      ${list.length ? groups.filter(([, g]) => g.length).map(([title, g]) => `<span class="label">${title} · ${g.length}</span><div class="list">${g.map(card).join("")}</div>`).join("")
        : `<div class="panel stack" style="text-align:center"><span class="hex" style="margin:0 auto">${icon("star")}</span><b>Geen opvolgingen</b>
           <p class="small muted" style="margin:0">Hoor je aan de deur dat iemand wil verkopen, verhuizen of een schatting wil? Tik bij het registreren op ‘Interessant signaal’.</p></div>`}
    </div>`;
  on("[data-href]", "click", (e) => go(e.currentTarget.dataset.href));
  const patch = async (el, body, msg) => {
    try { await api("PATCH", `/api/follow-ups/${el.closest("[data-fu]").dataset.fu}`, body); toast(msg); router(); } catch (e) { toast(e.message); }
  };
  on("[data-done]", "click", (e) => patch(e.currentTarget, { status: "done" }, "Opvolging afgerond"));
  on("[data-snooze]", "click", (e) => e.currentTarget.closest("[data-fu]").querySelector("[data-snooze-opts]").classList.toggle("hidden"));
  on("[data-in]", "click", (e) => patch(e.currentTarget, { due_on: addDays(+e.currentTarget.dataset.in) }, "Opvolging verplaatst"));
}

async function viewProspect(m) {
  const { prospect: p } = await api("GET", `/api/prospects/${m[1]}`);
  const today = ymd(new Date());
  const editable = (v) => !v.voided && v.user_id === S.me.id && (Date.parse(today) - Date.parse(v.visit_date)) / 864e5 <= 7;
  const fuNew = { signal: null, horizon: null, days: null, note: "" };
  const openFu = p.follow_ups.filter((f) => f.status === "open");
  app.innerHTML = `${backBar("#/prospecten", p.address)}
    <div class="stack">
      <div class="row wrap">${p.best ? tierTag(p.best) : '<span class="tag">Nog niet bezocht</span>'}
        ${p.do_not_contact ? '<span class="tag red">Niet meer contacteren</span>' : ""}${p.is_demo ? '<span class="demo-flag">Demo</span>' : ""}</div>
      <div class="grid2">
        ${p.do_not_contact ? "" : `<a class="btn primary block" href="#/registreer?p=${p.id}">${icon("plus", "sm")} Registreer</a>`}
        <a class="btn outline block" href="${mapsUrl(p.address)}" target="_blank" rel="noopener">${icon("nav", "sm")} Navigeer</a>
      </div>
      <section class="panel stack">
        <label class="field"><span class="label">Naam</span><input class="input" id="p-name" maxlength="80" value="${esc(p.name || "")}" placeholder="Onbekend"></label>
        <label class="field"><span class="label">Notitie</span><input class="input" id="p-note" maxlength="280" value="${esc(p.note || "")}" placeholder="Korte notitie"></label>
        ${p.phones.length ? `<div><span class="label">Telefoon</span>${p.phones.map((ph) => `<div class="row spread" style="margin-top:6px"><a href="tel:${esc(ph.number.replace(/\s/g, ""))}" style="font-weight:800;font-size:18px">${esc(ph.number)}</a><span class="tag">${esc(SOURCES[ph.source])}</span></div>`).join("")}</div>` : ""}
        ${p.appointments.length ? `<div><span class="label">Afspraak</span>${p.appointments.map((a) => `<div style="margin-top:6px;${a.status === "cancelled" ? "text-decoration:line-through;opacity:.6" : ""}"><b style="color:var(--diamond)">${fmtDT(a.starts_at)}</b> · ${esc(a.by)}${a.note ? `<div class="small muted">${esc(a.note)}</div>` : ""}</div>`).join("")}</div>` : ""}
        <button class="btn sm outline" id="p-save">Opslaan</button>
      </section>
      ${p.do_not_contact ? "" : `<section class="panel" style="padding-bottom:8px">
        <div class="panel-head"><span class="label">Opvolging</span><button class="btn sm outline" id="fu-add">${icon("plus", "sm")} Nieuw</button></div>
        <div id="fu-form"></div>
        ${openFu.length ? `<div style="margin:0 -14px">${followUpRows(openFu, { owner: true })}</div>` : '<p class="small muted" style="margin:0 0 8px">Geen open opvolging.</p>'}
      </section>`}
      <span class="label">Bezoekhistoriek</span>
      ${p.visits.length ? `<div class="list">${p.visits.map((v) => `<div class="item" style="${v.voided ? "opacity:.5;text-decoration:line-through" : ""}">
        <span class="dot t-${v.result}"></span>
        <div class="grow"><div class="title">${RES[v.result].label}${v.flyer ? " · flyer" : ""}</div><div class="sub">${fmtDate(v.visit_date)} · ${esc(v.by)}</div></div>
        <span class="pts">${v.points > 0 ? "+" : ""}${v.points}</span>
        ${editable(v) ? `<a class="icon-btn" href="#/registreer?v=${v.id}" aria-label="Aanpassen">${icon("edit", "sm")}</a>` : ""}
      </div>`).join("")}</div>` : '<p class="muted">Nog geen bezoeken.</p>'}
      <button class="btn ${p.do_not_contact ? "outline" : "danger"} block" id="p-dnc">${p.do_not_contact ? "Opnieuw contacteren toestaan" : `${icon("ban", "sm")} Niet meer contacteren`}</button>
    </div>`;
  on("#p-save", "click", async () => {
    await api("PATCH", `/api/prospects/${p.id}`, { name: $("#p-name").value, note: $("#p-note").value });
    toast("Opgeslagen");
  });
  on("#p-dnc", "click", async () => {
    if (!p.do_not_contact && !confirm("Dit adres verdwijnt uit suggesties en open opvolgingen worden geannuleerd. Doorgaan?")) return;
    await api("PATCH", `/api/prospects/${p.id}`, { do_not_contact: !p.do_not_contact });
    refreshProspects(); router();
  });
  const paintFu = () => {
    const box = $("#fu-form");
    box.innerHTML = `<div class="stack" style="margin-bottom:12px">${followUpFields(fuNew, "nf")}
      <p class="error" id="nf-err"></p><button class="btn primary block" id="nf-save" ${fuNew.signal ? "" : "disabled"}>Opvolging opslaan</button></div>`;
    bindFollowUpFields(box, fuNew, "nf", paintFu);
    on("#nf-save", "click", async () => {
      try {
        const r = await api("POST", "/api/follow-ups", { prospect_id: p.id, ...followUpPayload(fuNew) });
        toast(r.new_badges.length ? `Badge vrijgespeeld: ${r.new_badges[0].name}` : "Opvolging opgeslagen");
        router();
      } catch (e) { $("#nf-err").textContent = e.message; }
    }, box);
  };
  on("#fu-add", "click", paintFu);
}

/* ------------------------------------------------------ leaderboard --- */

async function viewLeaderboard(_m, query) {
  const period = query.get("period") || "week";
  const sort = query.get("sort") || "points";
  const lb = await api("GET", `/api/leaderboard?period=${encodeURIComponent(period)}&sort=${encodeURIComponent(sort)}`);
  const link = (p, s) => `#/ranglijst?period=${p}&sort=${s}`;
  const metric = (e) => sort === "doors" ? e.doors : e.points;
  const unit = sort === "doors" ? "deuren" : "punten";
  let encourage = "";
  if (lb.me) {
    const above = lb.entries.filter((e) => metric(e) > metric(lb.me));
    encourage = lb.me.rank === 1 ? "Je leidt de ranking." : above.length ? `Nog ${Math.min(...above.map(metric)) - metric(lb.me)} ${unit} tot #${lb.me.rank - 1}` : "";
  }
  const row = (e, me) => `<div class="lb-row ${e.is_me && !me ? "me" : ""}">
    <span class="lb-rank">${e.rank}</span>${avatar(e)}
    <div class="lb-main"><div class="title">${esc(e.name)}${e.is_me ? " · jij" : ""}</div>
      <div class="lb-stats"><span>${icon("door", "sm")}${e.doors}</span><span>${icon("chat", "sm")}${e.conversations}</span><span>${icon("phone", "sm")}${e.phones}</span><span>${icon("calendar", "sm")}${e.appointments}</span></div></div>
    <div class="lb-score num">${metric(e)}<small>${unit}</small></div></div>`;
  const top = lb.entries.slice(0, 3);
  const podium = top.length >= 3 ? `<div class="podium">${[top[1], top[0], top[2]].map((e) => `<div class="p p${e.rank > 3 ? 3 : e.rank} ${e.is_me ? "me" : ""}">
      ${avatar(e)}<div class="nm">${esc(firstName(e.name))}</div><div class="sc num">${metric(e)}</div><div class="block">${e.rank}</div></div>`).join("")}</div>` : "";
  app.innerHTML = `<header class="topbar"><h1>Ranking</h1></header>
    <div class="stack" style="padding-bottom:76px">
      <div class="seg">${[["week", "Week"], ["month", "Maand"], ["competition", "Competitie"]].map(([k, l]) =>
        `<button data-href="${link(k, sort)}" aria-pressed="${period === k}">${l}</button>`).join("")}</div>
      ${period === "competition" && !lb.competition ? '<div class="panel"><p class="muted" style="margin:0">Er loopt momenteel geen competitie.</p></div>' : `
      ${lb.competition ? `<section class="panel stack"><div class="row spread"><h2>${icon("crown")} ${esc(lb.competition.name)}</h2><span class="tag gold">nog ${plural(lb.competition.days_left, "dag", "dagen")}</span></div>
        <div class="small muted">${fmtDate(lb.from)} – ${fmtDate(lb.to)}</div>${lb.competition.reward ? `<div class="notice">${icon("gift")}<span>${esc(lb.competition.reward)}</span></div>` : ""}</section>` : ""}
      ${podium}
      <div class="row spread"><span class="label">Rangschikken op</span>
        <div class="seg" style="width:210px">${[["points", "Punten"], ["doors", "Deuren"]].map(([k, l]) =>
          `<button data-href="${link(period, k)}" aria-pressed="${sort === k}">${l}</button>`).join("")}</div></div>
      <div class="list">${lb.entries.map((e) => row(e)).join("")}</div>
      ${encourage ? `<p class="small muted" style="text-align:center;margin:0">${esc(encourage)}</p>` : ""}
      <section class="panel tight"><div class="panel-head" style="margin-bottom:8px"><span class="label">${icon("team", "sm")} Samen ${period === "week" ? "deze week" : period === "month" ? "deze maand" : ""}</span></div>
        <div class="grid4"><div class="stat"><b class="num">${lb.team.doors}</b><span>Deuren</span></div><div class="stat"><b class="num">${lb.team.conversations}</b><span>Gesprek</span></div><div class="stat"><b class="num">${lb.team.phones}</b><span>Nummers</span></div><div class="stat"><b class="num">${lb.team.appointments}</b><span>Afspr.</span></div></div></section>`}
    </div>
    ${lb.me ? `<div class="me-bar"><div>${row(lb.me, true)}</div></div>` : ""}`;
  on("[data-href]", "click", (e) => go(e.currentTarget.dataset.href));
}

/* ---------------------------------------------------------- profile --- */

async function viewProfile() {
  const pr = await api("GET", "/api/me/profile");
  const u = pr.user, l = pr.level, r = pr.records, life = pr.lifetime;
  const maxW = Math.max(1, ...pr.weeks.map((w) => w.doors));
  let wd = u.work_days, color = u.color;
  const earned = pr.badges.filter((b) => b.earned).length;
  app.innerHTML = `<header class="topbar"><h1>Profiel</h1>${u.role === "admin" ? `<a class="btn sm outline" href="#/beheer">${icon("sliders", "sm")} Beheer</a>` : ""}</header>
    <div class="stack">
      <section class="panel stack" style="text-align:center;padding:22px 16px">
        <div style="display:grid;justify-items:center;gap:10px">${avatar(u, "lg", l.level)}<h2 style="font-size:22px;margin-top:6px">${esc(u.name)}</h2>
          <span class="label" style="color:var(--gold)">${esc(l.title)}</span></div>
        <div class="bar xp seg"><i data-w="${l.progress}"></i></div>
        <div class="small muted num">${l.xp} XP · nog ${l.next - l.xp} XP tot level ${l.level + 1}</div>
        <div class="grid4" style="margin-top:4px"><div class="stat"><b class="num">${life.doors}</b><span>Deuren</span></div><div class="stat"><b class="num">${life.conversations}</b><span>Gesprek</span></div><div class="stat"><b class="num">${life.phones}</b><span>Nummers</span></div><div class="stat"><b class="num">${life.appointments}</b><span>Afspr.</span></div></div>
      </section>
      <div class="row spread"><span class="label">Badges</span><span class="tag">${earned} / ${pr.badges.length}</span></div>
      <div class="medals">${pr.badges.map((b) => `<div class="medal ${b.earned ? "" : "locked"}"><span class="hex ${b.earned ? "" : "locked"}">${icon(b.icon)}</span><b>${esc(b.name)}</b><small>${esc(b.desc)}</small></div>`).join("")}</div>
      <span class="label">Persoonlijke records</span>
      <div class="grid2">
        <div class="panel stat"><b class="num">${r.best_day ? r.best_day.doors : 0}</b><span>Deuren op 1 dag</span></div>
        <div class="panel stat c-gold"><b class="num">${r.best_points_day ? r.best_points_day.points : 0}</b><span>Punten op 1 dag</span></div>
        <div class="panel stat"><b class="num">${r.best_round}</b><span>Beste ronde</span></div>
        <div class="panel stat"><b class="num">${r.challenges}</b><span>Uitdagingen</span></div>
      </div>
      <section class="panel stack"><div class="row spread"><span class="label">Laatste 6 weken</span><span class="tiny faint">deuren per week</span></div>
        <div class="weeks">${pr.weeks.slice().reverse().map((w, i, a) => `<div><b class="tiny num">${w.doors}</b><i class="${i === a.length - 1 ? "now" : ""}" style="height:${(w.doors / maxW) * 80}%"></i><span>${fmtDate(w.from).split(" ")[1]}</span></div>`).join("")}</div>
        <div class="small muted">${life.unique_doors} unieke adressen · ${life.follow_ups} opvolgingen genoteerd</div></section>
      <section class="panel stack"><span class="label">Mijn doelen</span>
        <div class="row spread"><b>Dagmissie</b><div class="row"><button class="icon-btn" id="dg-min" aria-label="Minder">−</button><b class="num" id="dg" style="font-size:24px;min-width:40px;text-align:center">${u.daily_goal}</b><button class="icon-btn" id="dg-plus" aria-label="Meer">${icon("plus", "sm")}</button></div></div>
        <div><span class="label">Werkdagen</span>
          <div class="chips" style="margin-top:8px">${["ma", "di", "wo", "do", "vr", "za", "zo"].map((d, i) => `<button class="chip" data-wd="${i + 1}" aria-pressed="${wd.includes(String(i + 1))}" style="min-width:46px;justify-content:center">${d}</button>`).join("")}</div></div>
        <label class="field"><span class="label">Afwezig / verlof tot en met</span><input class="input" type="date" id="away" value="${esc(u.away_until || "")}"></label>
        <p class="tiny faint" style="margin:0">Geen streaks: weekends, verlof en vrije dagen breken niets.</p>
        <div><span class="label">Kleur</span><div class="row wrap" style="margin-top:8px">${COLORS.map((c) => `<button class="swatch" data-color="${c}" aria-pressed="${color === c}" style="background:${c}" aria-label="Kleur ${c}"></button>`).join("")}</div></div>
        <button class="btn primary block" id="g-save">Opslaan</button></section>
      <section class="panel"><label class="switch"><span><b>Locatie bij registreren</b><br><span class="small muted">Vind meteen het adres waar je staat (geen tracking)</span></span><input type="checkbox" id="autoloc" ${autoLocate() ? "checked" : ""}></label></section>
      <section class="panel"><label class="switch"><span><b>Buitenmodus</b><br><span class="small muted">Lichte weergave voor fel zonlicht</span></span><input type="checkbox" id="theme" ${store.get("nod_theme", "dark") === "light" ? "checked" : ""}></label></section>
      <section class="panel stack"><span class="label">Puntenhistoriek</span>
        ${pr.transactions.length ? `<table class="table">${pr.transactions.map((t) => `<tr><td class="pts" style="width:44px">${t.amount > 0 ? "+" : ""}${t.amount}</td>
          <td>${esc(t.detail || "")}<div class="tiny muted">${esc(t.address)}${t.reason ? ` · ${esc(t.reason)}` : ""}</div></td><td class="tiny muted">${fmtDate(t.created_at)}</td></tr>`).join("")}</table>` : '<p class="muted">Nog geen punten.</p>'}
      </section>
      <button class="btn ghost block" id="logout">${icon("logout", "sm")} Uitloggen</button>
    </div>`;
  fillBars();
  let goal = u.daily_goal;
  on("#dg-min", "click", () => { goal = Math.max(1, goal - 1); $("#dg").textContent = goal; });
  on("#dg-plus", "click", () => { goal = Math.min(100, goal + 1); $("#dg").textContent = goal; });
  on("[data-wd]", "click", (e) => {
    const d = e.currentTarget.dataset.wd;
    wd = wd.includes(d) ? wd.replace(d, "") : wd + d;
    e.currentTarget.setAttribute("aria-pressed", wd.includes(d));
  });
  on("[data-color]", "click", (e) => { color = e.currentTarget.dataset.color; $$("[data-color]").forEach((b) => b.setAttribute("aria-pressed", b === e.currentTarget)); });
  on("#autoloc", "change", (e) => store.set("nod_autoloc", e.target.checked));
  on("#theme", "change", (e) => { store.set("nod_theme", e.target.checked ? "light" : "dark"); applyTheme(); });
  on("#g-save", "click", async () => {
    try {
      const { user } = await api("PATCH", "/api/me", { daily_goal: goal, work_days: wd, away_until: $("#away").value || null, color });
      S.me = user; store.set("nod_me", user); toast("Opgeslagen"); router();
    } catch (e) { toast(e.message); }
  });
  on("#logout", "click", async () => {
    await sb.auth.signOut();
    S.me = null; ["nod_me", "nod_prospects", "nod_recent", DRAFT].forEach(store.del); go("#/login");
  });
}

/* ------------------------------------------------------- region import --- */
/* The admin's browser downloads a municipality from the Adressenregister (WFS, open data,
   CORS allowed) and stores one row per front door in Supabase, in batches. */

const WFS = "https://geo.api.vlaanderen.be/Adressenregister/wfs";
const REGION = { queue: [], running: null, progress: "" };
let municipalityCache = null;

async function municipalities() {
  if (municipalityCache) return municipalityCache;
  try {
    const d = await (await fetch("https://api.basisregisters.vlaanderen.be/v2/gemeenten?limit=500&status=inGebruik")).json();
    municipalityCache = d.gemeenten.map((g) => g.gemeentenaam.geografischeNaam.spelling).sort((a, b) => a.localeCompare(b, "nl"));
  } catch { return []; }
  return municipalityCache;
}

async function fetchMunicipality(name, onProgress) {
  const props = "ObjectId,StraatnaamObjectId,Straatnaam,Huisnummer,Busnummer,PostinfoObjectId,AdresStatus,AdresPositie";
  const filter = encodeURIComponent(`Gemeentenaam='${name.replace(/'/g, "''")}'`);
  const doors = new Map();
  for (let start = 0; ; start += 10000) {
    const url = `${WFS}?service=WFS&version=2.0.0&request=GetFeature&typeNames=Adressenregister:Adres&outputFormat=application/json`
      + `&srsName=EPSG:4326&count=10000&startIndex=${start}&sortBy=ObjectId&propertyName=${props}&CQL_FILTER=${filter}`;
    let data;
    for (let attempt = 0; ; attempt++) {
      try { data = await (await fetch(url)).json(); break; } catch (e) {
        if (attempt === 2) throw new Error("Adressenregister niet bereikbaar. Probeer later opnieuw.");
        await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
      }
    }
    const feats = data.features || [];
    for (const f of feats) {
      const p = f.properties;
      if (p.AdresStatus !== "InGebruik" || !f.geometry) continue;
      const [lon, lat] = f.geometry.coordinates;
      const key = `${p.StraatnaamObjectId}|${p.Huisnummer}`;
      let d = doors.get(key);
      if (!d) {
        d = { id: p.ObjectId, street_id: p.StraatnaamObjectId, street: p.Straatnaam, number: p.Huisnummer,
              postcode: p.PostinfoObjectId, lat, lon, boxes: 0 };
        doors.set(key, d);
      }
      if (p.Busnummer) d.boxes++;
      else Object.assign(d, { id: p.ObjectId, lat, lon });  // front door: the address without box number
    }
    onProgress(`${(start + feats.length).toLocaleString("nl-BE")} adressen opgehaald`);
    if (feats.length < 10000) break;
  }
  return [...doors.values()];
}

async function importMunicipality(id, name) {
  REGION.running = id;
  REGION.progress = "";
  const progress = (t) => { REGION.progress = t; if (location.hash === "#/beheer") paintRegionProgress(); };
  try {
    await rpc("admin_region_begin", { p_id: id });
    const doors = await fetchMunicipality(name, progress);
    if (!doors.length) throw new Error("Geen adressen gevonden. Controleer de naam (sinds 2025 zijn sommige gemeenten gefusioneerd).");
    for (let i = 0; i < doors.length; i += 2000) {
      await rpc("admin_region_rows", { p_id: id, p_rows: doors.slice(i, i + 2000) });
      progress(`${Math.min(i + 2000, doors.length).toLocaleString("nl-BE")} / ${doors.length.toLocaleString("nl-BE")} deuren opgeslagen`);
    }
    await rpc("admin_region_finish", { p_id: id });
    toast(`${name}: ${doors.length.toLocaleString("nl-BE")} deuren geladen`);
  } catch (e) {
    await rpc("admin_region_finish", { p_id: id, p_error: e.message }).catch(() => {});
    toast(`${name}: ${e.message}`);
  } finally {
    REGION.running = null;
  }
}

function queueImport(id, name) {
  if (REGION.running === id || REGION.queue.includes(id)) return;
  REGION.queue.push(id);
  REGION.names = { ...(REGION.names || {}), [id]: name };
  if (!REGION.running) runImports();
}
async function runImports() {
  while (REGION.queue.length) {
    const id = REGION.queue.shift();
    await importMunicipality(id, REGION.names[id]);
    if (location.hash === "#/beheer") viewAdmin();
  }
}
function paintRegionProgress() {
  const el = document.querySelector(`[data-muni="${REGION.running}"] .sub`);
  if (el) el.textContent = `Bezig met laden… ${REGION.progress}`;
}
window.addEventListener("beforeunload", (e) => { if (REGION.running) { e.preventDefault(); e.returnValue = ""; } });

/* ------------------------------------------------------------ admin --- */

async function viewAdmin() {
  if (S.me.role !== "admin") return go("#/profiel");
  const [o, vs, rg] = await Promise.all([api("GET", "/api/admin/overview"), api("GET", "/api/admin/visits"), api("GET", "/api/region")]);
  municipalities().then((list) => {
    const dl = $("#munis");
    if (dl) dl.innerHTML = list.map((m) => `<option value="${esc(m)}">`).join("");
  });
  const busy = REGION.running || rg.municipalities.some((m) => m.status === "queued" && REGION.queue.includes(m.id));
  const today = o.results.today;
  const active = o.competitions.find((c) => c.starts_on <= today && c.ends_on >= today);
  const upcoming = o.competitions.filter((c) => c.starts_on > today);
  const rule = o.rules[0];
  const kpis = (r) => `<div class="grid4"><div class="stat"><b class="num">${r.doors}</b><span>Deuren</span></div><div class="stat"><b class="num">${r.conversations}</b><span>Gesprek</span></div><div class="stat"><b class="num">${r.phones}</b><span>Nummers</span></div><div class="stat"><b class="num">${r.appointments}</b><span>Afspr.</span></div></div>`;
  app.innerHTML = `${backBar("#/profiel", "Beheer", o.team.is_demo ? '<span class="demo-flag">Demo</span>' : "")}
  <div class="stack">
    <details class="adm" open><summary>${icon("trophy")} Teamresultaten</summary><div class="body stack">
      <span class="label">Deze week</span>${kpis(o.results.week)}<span class="label">Deze maand</span>${kpis(o.results.month)}
      ${o.follow_ups.length ? `<span class="label">Open opvolgingen</span><div class="chips">${o.follow_ups.map((f) => `<span class="tag gold">${esc(SIGNALS[f.signal])} · ${f.n}</span>`).join("")}</div>` : ""}
      <table class="table"><tr><th>Collega</th><th>Week</th><th>XP</th></tr>${o.members.filter((m) => m.active).map((m) => `<tr><td>${esc(m.name)}</td><td class="num">${m.week ? `${m.week.doors} d · ${m.week.points} pt` : "–"}</td><td class="num">${m.xp}</td></tr>`).join("")}</table>
    </div></details>

    <details class="adm" ${busy || !rg.municipalities.length ? "open" : ""}><summary>${icon("map")} Regio & adressen</summary><div class="body stack">
      <p class="small muted" style="margin:0">Alle adressen van deze gemeenten worden geladen uit het Adressenregister van Digitaal Vlaanderen (Geopunt), met hun positie. Daarmee vindt de app het adres waar je staat. Laden gebeurt vanuit deze app (± 40 s per gemeente): laat ze open tot alles klaar is.</p>
      <div class="row"><span class="label grow">${rg.addresses.toLocaleString("nl-BE")} deuren in jullie regio</span></div>
      ${rg.municipalities.length ? `<div class="list">${rg.municipalities.map((m) => `<div class="item" data-muni="${m.id}">
        <div class="grow"><div class="title">${esc(m.name)}</div><div class="sub">${m.status === "done" ? `${(m.address_count || 0).toLocaleString("nl-BE")} deuren · ${fmtDate(m.imported_at)}`
          : m.status === "error" ? `<span style="color:var(--danger)">${esc(m.error || "Fout bij laden")}</span>` : REGION.running === m.id ? `Bezig met laden… ${REGION.progress}`
          : REGION.queue.includes(m.id) ? "In wachtrij" : "Niet volledig geladen: tik op herladen"}</div></div>
        ${REGION.queue.includes(m.id) || REGION.running === m.id ? `<span class="tag gold">${icon("refresh", "sm")} laden</span>`
          : `<button class="icon-btn" data-reload aria-label="Opnieuw laden">${icon("refresh", "sm")}</button><button class="icon-btn" data-remove aria-label="Verwijderen">${icon("trash", "sm")}</button>`}
      </div>`).join("")}</div>` : ""}
      <form id="muni" class="row"><input class="input grow" name="name" list="munis" placeholder="Gemeente, bv. Merelbeke-Melle" required autocomplete="off">
        <button class="btn primary">${icon("plus", "sm")} Laad</button></form><datalist id="munis"></datalist>
      <p class="error" id="muni-err"></p>
      <p class="tiny faint" style="margin:0">Open data · enkel Vlaanderen · sinds 2025 bestaan fusiegemeenten (bv. Merelbeke-Melle). Herlaad af en toe voor nieuwe adressen.</p>
    </div></details>

    <details class="adm"><summary>${icon("team")} Collega's</summary><div class="body stack">
      <form id="inv" class="stack"><div class="row"><input class="input grow" name="email" type="email" placeholder="e-mail collega" required>
        <select class="input" name="role" style="width:auto"><option value="member">Lid</option><option value="admin">Beheerder</option></select></div>
        <button class="btn primary block">Uitnodiging maken</button><div id="inv-out"></div></form>
      ${o.members.map((m) => `<div class="panel stack" style="background:var(--surface-2)" data-member="${m.id}">
        <div class="row">${avatar(m)}<div class="grow"><b>${esc(m.name)}</b><div class="tiny muted">${esc(m.email)}</div></div>${m.is_demo ? '<span class="demo-flag">demo</span>' : ""}</div>
        <div class="row wrap"><label class="field grow"><span class="label">Rol</span><select class="input" data-k="role"><option value="member" ${m.role === "member" ? "selected" : ""}>Lid</option><option value="admin" ${m.role === "admin" ? "selected" : ""}>Beheerder</option></select></label>
          <label class="field" style="width:92px"><span class="label">Dagdoel</span><input class="input" type="number" min="1" max="100" data-k="daily_goal" value="${m.daily_goal}"></label>
          <label class="field" style="width:104px"><span class="label">Werkdagen</span><input class="input" data-k="work_days" value="${esc(m.work_days)}" inputmode="numeric" title="1=ma … 7=zo"></label></div>
        <div class="row"><label class="row grow small"><input type="checkbox" data-k="active" ${m.active ? "checked" : ""}> Actief</label><button class="btn sm outline" data-save-member>Opslaan</button></div>
      </div>`).join("")}
      <p class="tiny faint">Werkdagen: 1 = maandag … 7 = zondag (bv. 135 voor ma, wo, vr).</p>
    </div></details>

    <details class="adm"><summary>${icon("crown")} Competitie</summary><div class="body stack">
      ${active ? `<div class="panel stack" style="background:var(--surface-2)"><b>${esc(active.name)}</b><div class="small muted">${fmtDate(active.starts_on)} – ${fmtDate(active.ends_on)} · ${active.participants} deelnemers</div>${active.reward ? `<div class="small">${esc(active.reward)}</div>` : ""}<button class="btn sm danger" data-end="${active.id}">Competitie beëindigen</button></div>` : '<p class="muted small">Geen actieve competitie.</p>'}
      ${upcoming.map((c) => `<div class="panel small" style="background:var(--surface-2)"><b>${esc(c.name)}</b> · start ${fmtDate(c.starts_on)} <button class="btn sm ghost" data-end="${c.id}">Annuleren</button></div>`).join("")}
      <form id="comp" class="stack"><span class="label">Nieuwe competitie</span>
        <label class="field"><span class="label">Naam</span><input class="input" name="name" required maxlength="60" placeholder="bv. Wintersprint"></label>
        <div class="grid2"><label class="field"><span class="label">Start</span><input class="input" type="date" name="starts_on" required value="${active ? addDays(1, new Date(active.ends_on + "T12:00")) : today}"></label>
          <label class="field"><span class="label">Einde</span><input class="input" type="date" name="ends_on" required></label></div>
        <label class="field"><span class="label">Beloning · optioneel</span><input class="input" name="reward" maxlength="160" placeholder="bv. etentje voor de winnaar"></label>
        <div><span class="label">Deelnemers</span>${o.members.filter((m) => m.active).map((m) => `<label class="row small" style="min-height:36px"><input type="checkbox" name="p" value="${m.id}" checked> ${esc(m.name)}</label>`).join("")}</div>
        <p class="tiny faint" style="margin:0">Een nieuwe competitie start op nul. Persoonlijke XP en historiek blijven bewaard.</p>
        <p class="error" id="comp-err"></p><button class="btn primary block">Competitie starten</button></form>
    </div></details>

    <details class="adm"><summary>${icon("sliders")} Punten & team</summary><div class="body stack">
      <form id="rules" class="stack"><div class="grid4">
        ${Object.keys(RES).map((k) => `<label class="field t-${k}"><span class="label" style="color:var(--t)">${RES[k].label.split(" ")[0]}</span><input class="input" type="number" min="0" name="${k}" value="${rule[k]}"></label>`).join("")}</div>
        <label class="field"><span class="label">Herbezoek binnen ${o.team.revisit_cooldown_days} dagen · % van aanbellen/gesprek</span><input class="input" type="number" min="0" max="100" name="revisit_pct" value="${rule.revisit_pct}"></label>
        <p class="tiny faint" style="margin:0">Totaal per bezoek, niet opgeteld. Nieuwe waarden gelden voor nieuwe bezoeken; reeds verdiende punten veranderen niet.</p>
        <p class="error" id="rules-err"></p><button class="btn primary block">Puntwaarden opslaan</button></form>
      <table class="table"><tr><th>Sinds</th><th>Aanb.</th><th>Gespr.</th><th>Tel.</th><th>Afspr.</th><th>Herb.</th></tr>${o.rules.map((r) => `<tr><td>${fmtDate(r.created_at)}</td><td>${r.door}</td><td>${r.conversation}</td><td>${r.phone}</td><td>${r.appointment}</td><td>${r.revisit_pct}%</td></tr>`).join("")}</table>
      <form id="team" class="stack"><span class="label">Team</span>
        <label class="field"><span class="label">Teamnaam</span><input class="input" name="name" value="${esc(o.team.name)}" maxlength="60"></label>
        <div class="grid2"><label class="field"><span class="label">Tijdzone</span><input class="input" name="timezone" value="${esc(o.team.timezone)}"></label>
          <label class="field"><span class="label">Herbezoek-periode (dagen)</span><input class="input" type="number" min="1" max="120" name="revisit_cooldown_days" value="${o.team.revisit_cooldown_days}"></label></div>
        <button class="btn outline block">Team opslaan</button></form>
    </div></details>

    <details class="adm"><summary>${icon("target")} Uitdagingen</summary><div class="body stack">
      ${o.challenges.map((c) => `<div class="row" data-ch="${c.id}"><div class="grow"><b class="small">${esc(c.title)}</b><div class="tiny muted">${c.scope === "team" ? "Team" : "Persoonlijk"} · per ${c.period === "day" ? "dag" : "week"}</div></div>
        <input class="input" type="number" min="1" data-k="target" value="${c.target}" style="width:76px;min-height:44px">
        <label class="small"><input type="checkbox" data-k="active" ${c.active ? "checked" : ""}> aan</label>
        <button class="icon-btn" data-save-ch aria-label="Opslaan">${icon("check", "sm")}</button></div>`).join("")}
      <p class="tiny faint" style="margin:0">Uitdagingen leveren badges en voortgang op, geen extra rankingpunten.</p>
    </div></details>

    <details class="adm"><summary>${icon("edit")} Correcties</summary><div class="body stack">
      <p class="small muted" style="margin:0">Pas een foutieve registratie aan of schrap ze. Een reden is verplicht en blijft zichtbaar.</p>
      <div class="list">${vs.visits.map((v) => `<div class="item" style="flex-wrap:wrap;${v.voided ? "opacity:.5" : ""}" data-visit="${v.id}">
        <span class="dot t-${v.result}"></span><div class="grow"><div class="title small">${esc(v.address)}</div><div class="sub tiny">${fmtDate(v.visit_date)} · ${esc(v.user_name)} · ${RES[v.result].label}${v.voided ? " · geschrapt" : ""}</div></div>
        <span class="pts small">${v.points}</span>${v.voided ? "" : '<button class="btn sm outline" data-fix>Corrigeer</button>'}
        <div class="fix hidden stack" style="width:100%;margin-top:8px"><select class="input" data-k="result">${Object.entries(RES).map(([k, r]) => `<option value="${k}" ${k === v.result ? "selected" : ""}>${r.label}</option>`).join("")}</select>
          <input class="input" data-k="reason" placeholder="Reden (verplicht)" maxlength="200">
          <div class="row"><button class="btn sm primary grow" data-apply>Aanpassen</button><button class="btn sm danger" data-void>Schrappen</button></div></div>
      </div>`).join("")}</div>
      ${vs.corrections.length ? `<span class="label">Laatste correcties</span><table class="table">${vs.corrections.map((t) => `<tr><td class="pts">${t.amount > 0 ? "+" : ""}${t.amount}</td><td class="small">${esc(t.user_name)} · ${esc(t.address)}<div class="tiny muted">${esc(t.detail || "")} — ${esc(t.reason || "")} (${esc(t.by_name || "")})</div></td></tr>`).join("")}</table>` : ""}
    </div></details>
  </div>`;

  const done = (msg = "Opgeslagen") => { toast(msg); viewAdmin(); };

  on("#muni", "submit", async (e) => {
    e.preventDefault();
    const name = new FormData(e.target).get("name").trim();
    const known = await municipalities();
    const match = known.find((m) => m.toLowerCase() === name.toLowerCase());
    if (known.length && !match) { $("#muni-err").textContent = `‘${name}’ is geen huidige Vlaamse gemeente. Kies uit de lijst.`; return; }
    try {
      const { municipality } = await rpc("admin_region_add", { p_name: match || name });
      queueImport(municipality.id, municipality.name);
      done("Adressen worden geladen… laat de app open");
    } catch (err) { $("#muni-err").textContent = err.message; }
  });
  on("[data-reload]", "click", (e) => {
    const id = +e.currentTarget.closest("[data-muni]").dataset.muni;
    const m = rg.municipalities.find((x) => x.id === id);
    queueImport(id, m.name);
    done("Opnieuw laden… laat de app open");
  });
  on("[data-remove]", "click", async (e) => {
    if (!confirm("Gemeente uit de regio halen? Bezochte adressen en punten blijven bewaard.")) return;
    await api("POST", `/api/admin/region/${e.currentTarget.closest("[data-muni]").dataset.muni}/remove`, {}); done("Verwijderd");
  });
  on("#inv", "submit", async (e) => {
    e.preventDefault();
    try {
      const f = Object.fromEntries(new FormData(e.target));
      const r = await rpc("admin_invite", { p_email: f.email, p_role: f.role });
      const url = `${BASE}#/uitnodiging/${r.code}`;
      $("#inv-out").innerHTML = `<div class="notice ok small">${icon("check", "sm")}<span>Stuur deze link naar ${esc(r.email)} (14 dagen geldig):<br><code style="word-break:break-all">${esc(url)}</code></span></div><button type="button" class="btn sm outline" id="copy">Kopieer link</button>`;
      on("#copy", "click", () => navigator.clipboard.writeText(url).then(() => toast("Link gekopieerd")));
    } catch (err) { $("#inv-out").innerHTML = `<p class="error">${esc(err.message)}</p>`; }
  });
  on("[data-save-member]", "click", async (e) => {
    const box = e.currentTarget.closest("[data-member]");
    const val = (k) => $(`[data-k="${k}"]`, box);
    try {
      await api("PATCH", `/api/admin/users/${box.dataset.member}`, { role: val("role").value, daily_goal: +val("daily_goal").value, work_days: val("work_days").value, active: val("active").checked });
      done();
    } catch (err) { toast(err.message); }
  });
  on("[data-end]", "click", async (e) => {
    if (!confirm("Competitie beëindigen? De resultaten blijven bewaard.")) return;
    await api("POST", `/api/admin/competitions/${e.currentTarget.dataset.end}/end`, {});
    done("Competitie beëindigd");
  });
  on("#comp", "submit", async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      await api("POST", "/api/admin/competitions", { name: f.get("name"), starts_on: f.get("starts_on"), ends_on: f.get("ends_on"), reward: f.get("reward"), participant_ids: f.getAll("p").map(Number) });
      done("Competitie aangemaakt");
    } catch (err) { $("#comp-err").textContent = err.message; }
  });
  on("#rules", "submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries([...new FormData(e.target)].map(([k, v]) => [k, +v]));
    try { await api("POST", "/api/admin/rules", f); done(); } catch (err) { $("#rules-err").textContent = err.message; }
  });
  on("#team", "submit", async (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    try { await api("PATCH", "/api/admin/team", { ...f, revisit_cooldown_days: +f.revisit_cooldown_days }); done(); } catch (err) { toast(err.message); }
  });
  on("[data-save-ch]", "click", async (e) => {
    const box = e.currentTarget.closest("[data-ch]");
    try { await api("PATCH", `/api/admin/challenges/${box.dataset.ch}`, { target: +$('[data-k="target"]', box).value, active: $('[data-k="active"]', box).checked }); done(); }
    catch (err) { toast(err.message); }
  });
  on("[data-fix]", "click", (e) => $(".fix", e.currentTarget.closest("[data-visit]")).classList.toggle("hidden"));
  on("[data-apply]", "click", async (e) => {
    const box = e.currentTarget.closest("[data-visit]");
    const body = { result: $('[data-k="result"]', box).value, reason: $('[data-k="reason"]', box).value };
    if (body.result === "appointment") {
      const when = prompt("Afspraak (JJJJ-MM-DD UU:MM)", `${ymd(new Date())} 14:00`);
      if (!when) return;
      const [date, time] = when.trim().split(/\s+/);
      body.appointment = { date, time };
    }
    try { const r = await api("PATCH", `/api/visits/${box.dataset.visit}`, body); done(`Gecorrigeerd: ${r.points >= 0 ? "+" : ""}${r.points} punten`); } catch (err) { toast(err.message); }
  });
  on("[data-void]", "click", async (e) => {
    const box = e.currentTarget.closest("[data-visit]");
    if (!confirm("Deze registratie schrappen? De punten worden teruggedraaid.")) return;
    try { const r = await api("POST", `/api/admin/visits/${box.dataset.visit}/void`, { reason: $('[data-k="reason"]', box).value }); done(`Geschrapt: ${r.points} punten`); } catch (err) { toast(err.message); }
  });
}

/* ------------------------------------------------------------- boot --- */

if ("serviceWorker" in navigator && location.protocol !== "file:") {
  navigator.serviceWorker.register("sw.js").catch(() => { /* optional */ });
}
router();
