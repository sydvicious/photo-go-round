/// The dashboard, as served. See `DashboardEndpoint`.
///
/// A raw string, so the script's backslashes and the page's `\(` are literal.
/// No numbers are written in here: everything on the page arrives from
/// `/v1/dashboard`.
///
/// **Nothing is said by colour alone.** A stale page says "not answering" in
/// words and dims; the cache meter carries its figures beside the bar.
enum DashboardPage {
    static let html = #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Photo-Go-Round Agent</title>
        <style>
          :root {
            color-scheme: light dark;
            --ground: #f5f5f7; --panel: #ffffff; --ink: #1d1d1f; --muted: #6e6e73;
            --rule: #d2d2d7; --fill: #0a64d8;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --ground: #1c1c1e; --panel: #2c2c2e; --ink: #f5f5f7; --muted: #a1a1a6;
              --rule: #3a3a3c; --fill: #4d9bff;
            }
          }
          * { box-sizing: border-box; }
          [hidden] { display: none !important; }
          body {
            margin: 0; padding: 24px; background: var(--ground); color: var(--ink);
            font: 14px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          }
          header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 16px; margin-bottom: 20px; }
          h1 { font-size: 22px; font-weight: 600; margin: 0; }
          #state { color: var(--muted); font-variant-numeric: tabular-nums; }
          #state.stale { color: var(--ink); font-weight: 600; }
          main.stale section { opacity: 0.45; }
          main { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; }
          section { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; padding: 16px; min-width: 0; }
          section.wide { grid-column: 1 / -1; }
          h2 { font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); margin: 0 0 8px; }
          .figure { font-size: 32px; font-weight: 600; font-variant-numeric: tabular-nums; }
          .sub { color: var(--muted); font-variant-numeric: tabular-nums; }
          .meter { height: 8px; border-radius: 4px; background: var(--rule); margin: 10px 0 6px; overflow: hidden; }
          .meter > div { height: 100%; width: 0; background: var(--fill); }
          table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
          td { padding: 3px 0; }
          td:last-child { text-align: right; }
          tr.total td { border-top: 1px solid var(--rule); font-weight: 600; padding-top: 6px; }
          tr.minor td { color: var(--muted); }
          tr.outcome td { color: var(--muted); }
          tr.outcome td:first-child { padding-left: 14px; }
          .last { display: flex; flex-wrap: wrap; gap: 16px; align-items: center; }
          .frame {
            width: 240px; height: 240px; flex: none; display: flex; align-items: center; justify-content: center;
            background: var(--ground); border-radius: 6px; overflow: hidden; color: var(--muted); text-align: center; padding: 8px;
          }
          .frame img { max-width: 100%; max-height: 100%; display: block; }
          .caption { min-width: 0; flex: 1 1 240px; }
          #lastName { font-size: 18px; font-weight: 600; overflow-wrap: anywhere; }
          #lastID { color: var(--muted); font-size: 12px; overflow-wrap: anywhere; margin-top: 2px; }
          #lastSource { color: var(--muted); overflow-wrap: anywhere; margin-top: 2px; }
          #lastWhen { color: var(--muted); font-variant-numeric: tabular-nums; margin-top: 8px; }
          .errors { list-style: none; margin: 0; padding: 0; }
          .errors li { padding: 8px 0; border-top: 1px solid var(--rule); }
          .errors li:first-child { border-top: 0; padding-top: 0; }
          .errors .message { overflow-wrap: anywhere; }
          .errors .meta { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; margin-top: 2px; overflow-wrap: anywhere; }
          .note { font-size: 12px; margin-bottom: 8px; }
          .changes { margin-top: 8px; }
          .changes td:first-child { overflow-wrap: anywhere; padding-right: 8px; }
          .changes td.n { text-align: right; white-space: nowrap; padding-left: 8px; }
        </style>
        </head>
        <body>
        <header>
          <h1>Photo-Go-Round Agent</h1>
          <span id="state">connecting…</span>
        </header>
        <main id="main">
          <section class="wide">
            <h2>Last picture served</h2>
            <div id="lastEmpty" class="sub">nothing served since launch</div>
            <div id="lastBody" class="last" hidden>
              <div class="frame">
                <img id="thumb" alt="the last picture served">
                <span id="thumbMissing" hidden>no longer here to draw</span>
              </div>
              <div class="caption">
                <div id="lastName"></div>
                <div id="lastID" hidden></div>
                <div id="lastSource"></div>
                <div id="lastWhen"></div>
              </div>
            </div>
          </section>
          <section class="wide">
            <h2>Agent errors</h2>
            <div class="sub note">A standing condition stays until it clears; anything else leaves a minute after it last happened.</div>
            <div id="errorsEmpty" class="sub">nothing standing, and nothing in the last minute</div>
            <ol id="errors" class="errors" hidden></ol>
          </section>
          <section>
            <h2>Photos in the database</h2>
            <div class="figure" id="photos">—</div>
            <div class="sub" id="changesEmpty">none added or removed since launch</div>
            <table id="changes" class="changes" hidden></table>
          </section>
          <section>
            <h2>Photos in the cache</h2>
            <div class="figure" id="cached">—</div>
            <div class="sub" id="queue">&nbsp;</div>
          </section>
          <section>
            <h2>Cache on disk</h2>
            <div class="figure" id="cacheBytes">—</div>
            <div class="meter"><div id="cacheMeter"></div></div>
            <div class="sub" id="cacheCeiling">&nbsp;</div>
            <div class="sub" id="free">&nbsp;</div>
          </section>
          <section>
            <h2>Served since launch</h2>
            <table id="served"></table>
            <div class="sub" id="since">&nbsp;</div>
          </section>
          <section>
            <h2>Serve: cache lookups since launch</h2>
            <table id="lookups"></table>
            <div class="sub" id="hitRate">&nbsp;</div>
          </section>
          <section>
            <h2>Fetch: cache lookups since launch</h2>
            <table id="fetchLookups"></table>
            <div class="sub" id="fetchHitRate">&nbsp;</div>
          </section>
          <section>
            <h2>Cache evictions since launch</h2>
            <div class="figure" id="evicted">—</div>
            <div class="sub" id="evictedBytes">&nbsp;</div>
            <div class="sub" id="evictedWhen">&nbsp;</div>
          </section>
        </main>
        <script>
        "use strict";
        const named = ["wallpaper", "screensaver", "app"];
        const $ = (id) => document.getElementById(id);
        let lastAnswer = null;
        let shownPhoto = null;

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
        $("thumb").addEventListener("error", () => {
          $("thumb").hidden = true;
          $("thumbMissing").hidden = false;
        });
        $("thumb").addEventListener("load", () => {
          $("thumb").hidden = false;
          $("thumbMissing").hidden = true;
        });

        function drawLast(last) {
          $("lastEmpty").hidden = last != null;
          $("lastBody").hidden = last == null;
          if (last == null) return;
          // Only when the picture changes: the page asks once a second, and a
          // thumbnail is a decode.
          if (last.photo !== shownPhoto) {
            shownPhoto = last.photo;
            $("thumb").src = "/v1/dashboard/thumbnail?photo=" + encodeURIComponent(last.photo);
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
        </script>
        </body>
        </html>
        """#
}
