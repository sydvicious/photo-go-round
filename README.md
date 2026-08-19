# Photo-Go-Round

Take a giant blob of photos and do something nice with it.

A background agent maintains a shuffled queue of photographs drawn from folders
on disk — eventually Apple Photos and Google Photos — keeps their bytes
available, and serves them to whatever wants to display one: desktop wallpaper,
screensaver, widgets, and apps across Apple's platforms. The library problem
(what to show, in what order, cached where) is split from the display problem
(how to show it), so one deck feeds every surface.

## Running the agent

```
swift build
./Scripts/photogoroundd --add-folder ~/Pictures/Wallpaper
```

The wrapper builds first, so a stale binary is never run. A bare invocation runs
the agent — it has exactly one job and takes no subcommand. Name each folder
once; it is written through to preferences, and every later run needs no
arguments at all:

```
./Scripts/photogoroundd
```

`--add-folder` does not walk subdirectories unless `--recursive` is given between
it and the path, which applies to that folder alone. By default everything lives
under `.build`, where a
development run cannot disturb a real library — reaching the real one takes
`--prod`, typed on purpose.

The agent serves pictures on port 9000. Two agents cannot hold the same port, so
`--port` is how a development one runs beside another that is already going.

## Inspecting and configuring it

`pgr_ctl` is the rig: sources, preferences, the pool, the queue, the cache, and
the deck's statistical checks. It never needs the agent running.

```
"$(swift build --show-bin-path)/pgr_ctl" status
```

## Testing the picture endpoint

The agent serves pictures over HTTP on port 9000. Clients ask it for one and are
handed the bytes; they never open the database or the cache. From a terminal that
means `curl`.

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

**The bytes are the original**, untouched: `w` and `h` are accepted and currently
ignored, so what comes back is byte-for-byte the file on disk. That means the
extension matters if you want Preview to open it — save it with the one the
`Content-Type` implies:

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

## Documentation

- [`Documentation/photogoroundd.md`](Documentation/photogoroundd.md) — the
  agent's man page: options, environment, preferences, files.
- [`Documentation/pgr_ctl.md`](Documentation/pgr_ctl.md) — the command-line
  tool's man page: subcommands, options, exit status.
