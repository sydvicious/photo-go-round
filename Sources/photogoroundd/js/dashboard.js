// The dashboard's script. Served at /dashboard/dashboard.js by the agent;
// see DashboardEndpoint and DashboardPage.
//
// No numbers are written in here: everything on the page arrives from
// /v1/dashboard. Nothing is said by colour alone: a stale page says
// "not answering" in words and dims.
"use strict";
const named = ["wallpaper", "screensaver", "app"];
const $ = (id) => document.getElementById(id);
let lastAnswer = null;
// The photograph whose thumbnail is drawn, or known to be missing.
let shownPhoto = null;
// The photograph a thumbnail is being fetched for; one at a time.
let loadingPhoto = null;

// Decimal units, as the Finder and the agent's console count them.
function bytes(n) {
  if (n < 1000) return n + " bytes";
  const units = ["KB", "MB", "GB", "TB"];
  let value = n, unit = -1;
  do { value /= 1000; unit++; } while (value >= 1000 && unit < units.length - 1);
  return value.toFixed(value < 10 ? 2 : 1) + " " + units[unit];
}
const count = (n) => n.toLocaleString();
const clock = (d) => d.toLocaleTimeString([], { hour12: false });

function duration(ms) {
  const s = Math.floor(ms / 1000), d = Math.floor(s / 86400),
        h = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60;
  if (d > 0) return d + "d " + h + "h";
  if (h > 0) return h + "h " + m + "m";
  return m + "m " + (s % 60) + "s";
}

function row(label, value, cls) {
  const tr = document.createElement("tr");
  if (cls) tr.className = cls;
  const name = document.createElement("td"), figure = document.createElement("td");
  name.textContent = label;
  figure.textContent = count(value);
  tr.append(name, figure);
  return tr;
}

// A picture that has been evicted, or whose file went, cannot be drawn;
// the caption still says what it was.
function showMissing() {
  $("thumb").hidden = true;
  $("thumbMissing").hidden = false;
}
$("thumb").addEventListener("error", showMissing);
$("thumb").addEventListener("load", () => {
  $("thumb").hidden = false;
  $("thumbMissing").hidden = true;
});

// One thumbnail at a time, and the image already drawn stays until the next
// one has arrived. Until 2026-09-16 the image's src was set on every new
// picture, so a thumbnail waiting 38.9 s on the agent's resizer left the image
// further behind the filename with each picture. The agent now answers 503
// when its resizer is busy: that is "not yet", so the image stays and a later
// redraw asks for whatever picture is newest then.
async function loadThumbnail(photo) {
  loadingPhoto = photo;
  try {
    const response = await fetch(
      "/v1/dashboard/thumbnail?photo=" + encodeURIComponent(photo), { cache: "no-store" });
    if (response.status === 503) return;
    shownPhoto = photo;
    if (!response.ok) {
      showMissing();
      return;
    }
    const previous = $("thumb").src;
    $("thumb").src = URL.createObjectURL(await response.blob());
    if (previous.startsWith("blob:")) URL.revokeObjectURL(previous);
  } catch (error) {
    // The agent did not answer; the poll says so at the top of the page.
  } finally {
    loadingPhoto = null;
  }
}

function drawLast(last) {
  $("lastEmpty").hidden = last != null;
  $("lastBody").hidden = last == null;
  if (last == null) return;
  // Only when the picture changes: the page asks once a second, and a
  // thumbnail is a resize. Never while one is already on its way.
  if (last.photo !== shownPhoto && loadingPhoto === null) {
    loadThumbnail(last.photo);
  }
  $("lastName").textContent = last.name;
  // A Photos photograph's identifier, under its filename; a folder
  // photograph's identifier is its name, and is not said twice.
  $("lastID").textContent = last.externalID;
  $("lastID").hidden = last.externalID === last.name;
  $("lastSource").textContent = last.source;
  $("lastWhen").textContent = "to " + last.consumer + " at " + clock(new Date(last.at));
}

// One row per kind of trouble, most recently seen first: the latest
// words, then the kind and when. A standing condition is still true,
// so what it says is how long; an event says how often and how lately.
function drawErrors(list) {
  $("errorsEmpty").hidden = list.length > 0;
  $("errors").hidden = list.length === 0;
  $("errors").replaceChildren(...list.map((e) => {
    const item = document.createElement("li");
    const message = document.createElement("div");
    message.className = "message";
    message.textContent = e.message;
    const last = new Date(e.lastSeen), first = new Date(e.firstSeen);
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = (e.standing ? [
      e.kind,
      "standing since " + clock(first) + " (" + duration(Date.now() - first.getTime()) + ")",
      e.until == null ? null : "until " + clock(new Date(e.until)),
    ] : [
      e.kind,
      e.count === 1 ? "once" : count(e.count) + " times",
      "last " + clock(last) + " (" + duration(Date.now() - last.getTime()) + " ago)",
      e.count === 1 ? null : "first " + clock(first),
    ]).filter(Boolean).join(" · ");
    item.append(message, meta);
    return item;
  }));
}

function changeRow(label, added, removed, cls) {
  const tr = document.createElement("tr");
  if (cls) tr.className = cls;
  const name = document.createElement("td");
  const plus = document.createElement("td"), minus = document.createElement("td");
  name.textContent = label;
  plus.textContent = "+" + count(added);
  minus.textContent = "−" + count(removed);
  plus.className = minus.className = "n";
  tr.append(name, plus, minus);
  return tr;
}

// One row per source that added or removed anything since launch,
// then the totals. A source removed since keeps its name.
function drawChanges(list) {
  $("changesEmpty").hidden = list.length > 0;
  $("changes").hidden = list.length === 0;
  let added = 0, removed = 0;
  const rows = list.map((c) => {
    added += c.added;
    removed += c.removed;
    return changeRow(c.source + (c.sourceRemoved ? " (removed)" : ""), c.added, c.removed);
  });
  if (list.length > 0) rows.push(changeRow("total", added, removed, "total"));
  $("changes").replaceChildren(...rows);
}

function draw(s) {
  drawErrors(s.errors);
  drawLast(s.last);
  $("photos").textContent = count(s.photos);
  drawChanges(s.libraryChanges);
  $("cached").textContent = count(s.cached);
  $("queue").textContent = count(s.queued) + " / " + count(s.queueSize) + " queued";
  $("cacheBytes").textContent = bytes(s.cacheBytes);
  const share = s.cacheCeilingBytes > 0 ? Math.min(1, s.cacheBytes / s.cacheCeilingBytes) : 0;
  $("cacheMeter").style.width = (share * 100).toFixed(1) + "%";
  const percent = s.cacheCeilingBytes > 0 ? Math.round(100 * s.cacheBytes / s.cacheCeilingBytes) : 0;
  $("cacheCeiling").textContent =
    "of " + bytes(s.cacheCeilingBytes) + " ceiling (" + percent + "%)";
  $("free").textContent = s.freeBytes == null
    ? "free space on the volume unknown"
    : bytes(s.freeBytes) + " free on the volume; fetching stops below " + bytes(s.freeFloorBytes);

  const table = $("served");
  table.replaceChildren();
  let total = 0;
  for (const name of named) {
    const n = s.served[name] || 0;
    total += n;
    table.append(row(name, n));
  }
  for (const name of Object.keys(s.served).filter((k) => !named.includes(k)).sort()) {
    total += s.served[name];
    table.append(row(name, s.served[name], "minor"));
  }
  table.append(row("total", total, "total"));
  const since = new Date(s.since);
  $("since").textContent =
    "since " + since.toLocaleString([], { hour12: false }) +
    " (" + duration(Date.now() - since.getTime()) + ")";

  // Materialized cards only, one per card a request met — so hits and
  // misses together can exceed pictures served.
  const l = s.serveLookups;
  const misses = l.landed + l.timedOut + l.leftDuringWait + l.droppedWithoutWaiting;
  $("lookups").replaceChildren(
    row("hits", l.hits),
    row("misses", misses),
    row("arrived during the wait", l.landed, "outcome"),
    row("timed out waiting", l.timedOut, "outcome"),
    row("left the queue during the wait", l.leftDuringWait, "outcome"),
    row("dropped without waiting", l.droppedWithoutWaiting, "outcome"));
  const looked = l.hits + misses;
  $("hitRate").textContent = looked === 0
    ? "no cached originals looked up yet"
    : "hit rate " + Math.round(100 * l.hits / looked) + "% of " + count(looked);

  // Counted as a materialized card is dealt: its original already held,
  // or sent to the fetcher. The outcomes are what became of fetches, and
  // include fetches for cards dealt before launch.
  const f = s.fetchLookups;
  $("fetchLookups").replaceChildren(
    row("hits", f.hits),
    row("misses", f.misses),
    row("fetched", f.fetched, "outcome"),
    row("failed", f.failed, "outcome"),
    row("timed out", f.timedOut, "outcome"));
  const dealt = f.hits + f.misses;
  $("fetchHitRate").textContent = dealt === 0
    ? "no materialized cards dealt yet"
    : "hit rate " + Math.round(100 * f.hits / dealt) + "% of " + count(dealt);

  // The agent's own maintenance passes; pgr_ctl's evictions and bytes
  // that left with their photograph are not counted.
  const e = s.evictions;
  $("evicted").textContent = count(e.photos);
  $("evictedBytes").textContent = "photos evicted" + (e.photos === 0 ? "" :
    ", " + bytes(e.bytesFreed) + " freed in " + count(e.passes) + (e.passes === 1 ? " pass" : " passes"));
  if (e.lastAt == null) {
    $("evictedWhen").textContent = "none since launch";
  } else {
    const at = new Date(e.lastAt);
    $("evictedWhen").textContent = "last at " + clock(at) + " (" + duration(Date.now() - at.getTime()) + " ago)" +
      (e.lastCeilingHalved ? " — free space below the critical floor, ceiling halved" : "");
  }
}

async function poll() {
  try {
    const response = await fetch("/v1/dashboard", { cache: "no-store" });
    if (!response.ok) throw new Error(response.status + " " + response.statusText);
    draw(await response.json());
    lastAnswer = new Date();
    $("state").textContent = "updated " + clock(lastAnswer);
    $("state").className = "";
    $("main").className = "";
  } catch (error) {
    $("state").textContent = lastAnswer
      ? "not answering since " + clock(lastAnswer) + " (" + error.message + ")"
      : "not answering (" + error.message + ")";
    $("state").className = "stale";
    $("main").className = "stale";
  }
  // After the answer rather than on a fixed interval, so a slow agent
  // is not asked again before it has replied.
  setTimeout(poll, 1000);
}
poll();
