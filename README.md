# Photo-Go-Round

Take a giant blob of photos and do something nice with it.

A background agent maintains a shuffled queue of photographs drawn from folders
on disk — eventually Apple Photos and Google Photos — keeps their bytes
available, and serves them to whatever wants to display one: desktop wallpaper,
screensaver, widgets, and apps across Apple's platforms. The library problem
(what to show, in what order, cached where) is split from the display problem
(how to show it), so one deck feeds every surface.

## Building and installing from Xcode

Open `app/Photo-Go-Round.xcodeproj`. Everything below is the Debug configuration; Release is Archive, moved to `/Applications` by hand.

**⌘B builds, ⌘R installs**, since 2026-09-19. Building an install scheme changes nothing.

| To | Scheme | Key |
|---|---|---|
| Install the agent, and restart it | **Install Agent** | ⌘R |
| Install the wallpaper extension | **Install Wallpaper Extension** | ⌘R |
| Install the screensaver | **Install Screen Saver** | ⌘R |
| Run the app | **Photo-Go-Round** | ⌘R |
| Run the agent under the debugger | **Photo-Go-Round Server** | ⌘R |
| Run every test | **Package Tests** | ⌘U |

`Package Tests` covers the package's five test targets — 1,001 tests. From a terminal, note that it takes no `-project`, because a scheme whose targets are the package's is a package scheme:

```
xcodebuild test -scheme "Package Tests" -destination "platform=macOS,arch=arm64"
```

The app's own bundle, `Photo-Go-RoundTests`, is not in it: it wants a running agent. Run it through the **Photo-Go-Round** scheme.

`pgr_ctl` has no shared scheme. Build its target and put the product on your `PATH` — a copy or a symlink into `~/bin`. Not `swift run pgr_ctl`: that writes a `.build` directory into the checkout, and nothing generated belongs there.

Install the agent first; the wallpaper and the screensaver get their pictures from it. Each install scheme builds its product and `pgr_install`, and ⌘R runs it — so ⌘R is the whole step, and ⌘R again reinstalls.

Each build configuration installs under its own names, so Debug, Release and an agent's `Claude` build can sit on one Mac at once without displacing each other. `Documentation/Installing.md` has the table.

Then choose them in System Settings:

- **Wallpaper** › *Photo-Go-Round* › **Photo-Go-Round Wallpaper (Debug)**
- **Screen Saver** › *Other* › **Photo-Go-Round Screensaver (Debug)**

To take all three off the Mac, leaving the library, cache and preferences alone:

```bash
./Scripts/uninstall.sh
```

[`Documentation/Installing.md`](Documentation/Installing.md) has what each install does and how to check it worked.

## Running the agent

```
./Scripts/photogoroundd --add-folder ~/Pictures/Wallpaper
```

The wrapper builds first, so a stale binary is never run — the `Photo-Go-Round
Server` target, so the agent it runs carries its configuration's port and label
exactly as an installed one does. `--release` and `--claude` pick another. A bare invocation runs
the agent — it has exactly one job and takes no subcommand. Name each folder
once; it is written through to preferences, and every later run needs no
arguments at all:

```
./Scripts/photogoroundd --port 9000
```

`--add-folder` does not walk subdirectories unless `--recursive` is given between
it and the path, which applies to that folder alone. By default everything lives
under `~/Library/Containers/<identifier>.dev` and the matching cache, where a
development run cannot disturb a real library — reaching the real one takes
`--prod`, typed on purpose. `<identifier>` carries the build configuration, so a
release, a Debug and an agent's build never share a library.

The agent serves pictures on a fixed port — one per build configuration — and
publishes it where every process on the machine can read it; `pgr_ctl status`
prints the address. `--port` pins a different number, which is what you want for
a URL you are going to type.

## Inspecting and configuring it

`pgr_ctl` is the rig: sources, preferences, the pool, the queue, the cache, and
the deck's statistical checks. It never needs the agent running.

Build its scheme and put the product on your `PATH` — a copy or a symlink into
`~/bin`. Then, against a Debug agent installed by ⌘R:

```
pgr_ctl status --development --debug
```

It addresses one configuration's library at a time and defaults to production
and to the configuration it was built as, so those two flags are how you reach
a development agent you have running. `Documentation/pgr_ctl.md`.

## Testing the picture endpoint

The agent serves pictures over HTTP. Clients ask it for one and are handed the
bytes; they never open the database or the cache. From a terminal that means
`curl`.

**The port is fixed, and there is one per build configuration** — 9427 release,
9428 Debug, 9429 Claude — so two of them can run at once and neither has to
chase the other. It was whatever the kernel gave the agent at launch until
2026-09-17; Syd: "this dynamic port stuff is causing problems." A port already
held by something else is still fallen back from and published, so `pgr_ctl
status` remains the way to be certain.

The examples below pin one with `--port` anyway, so they are copy-pasteable
whichever configuration you are running.

Start the agent in one terminal and leave it running — it prints the URL once the
listener is up, then a line for every request it answers:

```
./Scripts/photogoroundd
```

In another terminal, take a picture:

```
curl -sS -D - -o /tmp/pgr.bin "http://localhost:9000/v1/next?consumer=cli&w=3840&h=2160"

```

The response headers say what you got — `Content-Type` for the format,
`X-PGR-Card` for the photo's row id, `X-PGR-Deal` for its ordinal in the shuffle.
Requesting again gives a *different* picture, because serving pops the queue.

`w` and `h` are maximums — nothing comes back larger than either — and what you
get is the largest that fits inside them with its aspect ratio intact. HEIC
unless you ask for JPEG with `Accept`. Leave both out and you get the original
bytes, untouched. Either way the extension matters if
you want Preview to open it, so save it with the one the `Content-Type` implies:

```
curl -sS -D /tmp/pgr.head -o /tmp/pgr.body "http://localhost:9000/v1/next?w=3840&h=2160" && ext=$(awk -F/ 'tolower($0) ~ /^content-type/ {gsub(/\r/,""); print $2}' /tmp/pgr.head) && mv /tmp/pgr.body "/tmp/pgr.$ext" && open "/tmp/pgr.$ext"
```

Two answers that are not errors. **`204 No Content`** means the queue is empty —
a fresh library answers this way until the agent has produced something, and so
does a small library asked faster than it can refill. And four requests at once
never hand out the same picture, because serving removes the queue entry:

```
for c in a b c d; do curl -sS -D - -o /dev/null "http://localhost:9000/v1/next?consumer=display-$c&w=1920&h=1080" & done; wait
```

## Managing sources over HTTP

The same listener manages the source list, because the database is private to the
agent — a client asks rather than opening the store. `pgr_ctl sources` does all of
this without the agent running; this is the path a shipping client takes.

List what is configured, with counts and availability:

```
curl -sS "http://localhost:9000/v1/sources"
```

Add one or more. The body is an array, `kind` defaults to `folder`, and the batch
is all-or-none — one path that does not resolve refuses the lot and names it:

```
curl -sS -X POST "http://localhost:9000/v1/sources" -H 'Content-Type: application/json' -d '[{"path": "/Users/me/Pictures/Sunsets", "recursive": true}]'
```

The answer carries each new source's `uuid`, which is what names it afterwards —
the row id `pgr_ctl` prints belongs to a disposable database. It does **not** wait
for the folder to be scanned, so `photos` is zero until a later request:

```
curl -sS "http://localhost:9000/v1/sources/<uuid>"
curl -sS -X DELETE -D - "http://localhost:9000/v1/sources/<uuid>"
```

`DELETE` answers `204` and takes the source's photographs — and their cached
bytes — with it. Removal is not deletion: nothing on the source itself is
touched.

Change what a folder was added with, keeping its identity and its shuffle
position:

```
curl -sS -X PATCH "http://localhost:9000/v1/sources/<uuid>" -H 'Content-Type: application/json' -d '{"recursive": false}'
```

## Documentation

- [`Documentation/photogoroundd.md`](Documentation/photogoroundd.md) — the
  agent's man page: options, environment, preferences, files.
- [`Documentation/pgr_ctl.md`](Documentation/pgr_ctl.md) — the command-line
  tool's man page: subcommands, options, exit status.
- [`Documentation/Installing.md`](Documentation/Installing.md) — installing the
  agent, the wallpaper extension and the screensaver on a Mac from Xcode, in
  order, and removing them.
- [`Documentation/Wallpaper Extension.md`](Documentation/Wallpaper%20Extension.md) —
  checking the wallpaper extension once it is installed: registration, the
  gates, the logs.
