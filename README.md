# Crap - A fork of [poop](https://github.com/andrewrk/poop)

Stop flushing your performance down the drain.

## Overview

This command line tool uses Linux's `perf_event_open` and macOS `kperf` functionality to compare the performance of multiple commands
with a colorful terminal user interface.

<img width="1049" height="400" alt="Screenshot 2025-12-06 at 11 29 16" src="https://github.com/user-attachments/assets/1ab6f31c-ce49-470e-b04d-9bb8acdf19d4" />

## Usage

```
Usage: crap [options] <command1> ... <commandN>

Compares the performance of the provided commands.

Options:
 --duration <ms>    (default: 5000) how long to repeatedly sample each command

```

## Building from Source

Tested with [Zig](https://ziglang.org/) `0.15.2`.

```
zig build
```

## Comparison with Hyperfine

Crap (so far) is brand new, whereas
[Hyperfine](https://github.com/sharkdp/hyperfine) is a mature project with more
configuration options and generally more polish.

However, crap does report peak memory usage as well as 5 other hardware
counters, which I personally find useful when doing performance testing. Hey,
maybe it will inspire the Hyperfine maintainers to add the extra data points!

Crap does not support running the commands in a shell. This has the upside of
not including shell spawning noise in the data points collected, and the
downside of not supporting strings inside the commands. Hyperfine by default
runs the commands in a shell, with command line options to disable this.

Crap treats the first command as a reference and the subsequent ones relative
to it, giving the user the choice of the meaning of the coloring of the deltas.
Hyperfine by default prints the wall-clock-fastest command first, with a command
line option to select a different reference command explicitly.

Note: on macos to get some of the extra performance counters, sudo privelage is needed.


## Credits
 - [andrewrk](https://github.com/andrewrk): original author of poop, also known for advocating to [flush](https://www.youtube.com/watch?v=f30PceqQWko).
 - [tensorrush](https://codeberg.org/tensorush): made support for macos possible, [original pr](https://github.com/andrewrk/poop/pull/70)
