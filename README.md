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
the agent — it has exactly one job and takes no command word. Name each folder
once; it is written through to preferences, and every later run needs no
arguments at all:

```
./Scripts/photogoroundd
```

`--add-folder` does not walk subdirectories; use `--add-folder-recursive` for a
folder that should be. By default everything lives under `.build`, where a
development run cannot disturb a real library — reaching the real one takes
`--prod`, typed on purpose.

## Documentation

- [`Documentation/photogoroundd.md`](Documentation/photogoroundd.md) — the
  agent's man page: options, environment, preferences, files.
- [`PLAN.md`](PLAN.md) — what this is, why it is shaped this way, and where it
  is going. The man page says what; the plan says why.
