# Repeatable benchmarks

## Local hardware run

```powershell
.\build.ps1
.\scripts\Benchmark.ps1 -ExePath .\dist\TrayLuma.exe -IdleSeconds 60 -Cycles 30 -Launches 5
```

The script launches an isolated `--benchmark --background` instance, measures
window-response readiness and first discovery, samples CPU/memory/resources
while hidden, performs repeated open/enumerate/close cycles, and measures idle
again. It terminates only its own test process, including after failures.

The test instance does not register hotkeys, rewrite autostart, change monitor
brightness, save settings, or create dimming overlays. Do not interact with the
test popups. Your installed instance is left running and untouched. For the most
controlled results, exit other monitor-control apps and avoid moving sliders
in your installed instance during the run.

Results: `%LOCALAPPDATA%\TrayLuma\Benchmarks\<UTC>-<hash>-<mode>\`:

- `report.json`: file hash, environment, configuration, timings, raw samples, summary.
- `samples.csv`: cumulative CPU milliseconds, working set, private bytes, peak
  working set, handles, threads, GDI objects and USER objects.
- `timings.csv`: each launch/refresh timing and returned row count.
- `summary.md`: concise results to share or analyze.

`index.md` and `index.json` in the parent benchmark directory are refreshed after
each default-location run. Rebuild the history with `scripts\Analyze-Benchmarks.ps1`.
It includes observed resource changes and the final-quarter private-memory trend
without presenting an allocator increase as a proven leak or a pass/fail guarantee.

Use `-OutputDirectory <folder>` for a fixed destination. A failed test saves
partial data and exits with an error. Local reports are not automatically
uploaded or committed. They omit username, host name and monitor serials.

## Demo and longer tests

```powershell
# Safe CI/smoke test: no monitor communication.
.\scripts\Benchmark.ps1 -ExePath .\dist\TrayLuma.exe -Demo -IdleSeconds 5 -Cycles 10 -Launches 3

# Longer local test: five minutes idle before AND after 100 refresh cycles.
.\scripts\Benchmark.ps1 -ExePath .\dist\TrayLuma.exe -IdleSeconds 300 -Cycles 100 -Launches 10
```

Clear `BRIGHTNESS_TRAY_DEMO` and `BRIGHTNESS_TRAY_SOFTWARE` for real hardware runs.
Do not compare demo timings with DDC/CI timings as if they represent the same work.

## Interpreting results

- Readiness is an initialized app window responding to a test message, **not**
  proof that Explorer has rendered the tray icon. These are observed launches
  using the current OS cache, not controlled cold-boot measurements.
- Read `idle_cpu_ms`, not just rounded Task Manager percentages. The summary
  includes both one-core CPU percentage and total-machine-normalized percentage.
- Working-set trimming can make resident memory very small without eliminating
  private committed memory. Report both counters. Raw lifetime peak working set
  is also recorded; this sampling is not a CPU profiler or peak-commit tracer.
- Resource deltas describe this run, not proof that a leak exists or cannot exist.
  Compare several runs; allocator caches can grow initially and then stabilize.
- DDC/CI discovery latency is highly dependent on the number of monitors, failed
  reads, retries, cable/dock and firmware. Save the setup description alongside
  reports before publishing a comparison.
- CI runs may lack Explorer/physical displays and use virtualized CPUs. They
  validate automation and regressions, not user-desktop performance claims.

## Still manual

Slider correctness/latency, global shortcuts, overlay GPU cost at non-100%
brightness, sleep/resume, HDR, physical hot-plugging, cold-boot tray visibility,
and power consumption require hardware or interactive testing. The automated
runner intentionally does not change your display settings or put your PC to
sleep. Use Windows Performance Recorder/Analyzer for detailed startup/CPU traces.
