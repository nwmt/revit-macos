# Benchmarks

We measure with the [RFO Benchmark](https://www.revitforum.org) (RevitForum.org): a set of Revit journals that build a
model, switch views, export and render, and log the time of every step. Lower is better. Each Revit year has its own
benchmark set, so rows for different years are not comparable with each other.

These are our numbers on one machine, not a promise for yours.

## How we run it

- **Machine:** Apple M5 MacBook, 10 cores (4 performance + 6 efficiency), 16 GB, macOS 26, CrossOver 26.3.
  Revit runs under Rosetta 2 on top of Wine.
- **Set:** Full_Simplified (modeling + graphics), 3 runs in a row, average. The Mac is not used during the runs.
- **Anti-aliasing off.** This is the default of our install for 2026 and newer: Revit runs better under Wine without
  it. The benchmark's own `Revit.ini` template turns it on; from now on we do not take that part of the template.
- **Same bottle as a normal install.** No extra tuning for the benchmark.

## Results

Full_Simplified, average of 3 runs.

| Revit | Modeling | Graphics | Anti-aliasing | Windows reference |
|---|---:|---:|---|---|
| 2020 | 121.3 s | 24.9 s | on (benchmark template) | Intel i7-10750H laptop: 193.3 s / 43.9 s (over remote desktop) |
| 2023 | 115.1 s | 27.1 s | **off** | Intel i9-13900KS + RTX 4090 desktop: 55.0 s modeling |
| 2026 | 128.0 s | 32.4 s | on (benchmark template) | none |
| 2027 | 99.0 s | 27.9 s | **off** | Intel Core Ultra 9 275HX + RTX 5090 laptop: 65.2 s modeling |

**The 2020 and 2026 numbers were taken with anti-aliasing on**, before we switched to measuring without it.
They will be re-measured with anti-aliasing off. One earlier 2020 run without anti-aliasing (on another day) gave 130.9 s / 27.1 s,
so do not expect the new numbers to be lower.

### Notes per version

- **2020:** the Windows laptop run is older and was done over remote desktop, which lowers its graphics score.
- **2023:** runs were steady: modeling 115.4 / 115.4 / 114.4 s, graphics 27.2 / 27.2 / 26.9 s. With anti-aliasing on
  (earlier, same bottle) it was 115.6 s and 28.3 s: modeling is the same, graphics about 4 % slower. The Windows
  numbers come from the reference report that ships with the benchmark; its graphics test is a different set, so it
  is left out.
- **2027:** measured on 2027.3 (build 27.3.0.28). Runs were steady: modeling 100.2 / 98.5 / 98.2 s, graphics
  28.0 / 27.9 / 27.9 s. The Windows numbers come from the reference report that ships with the benchmark (Revit 2027.0,
  a laptop with an Intel Core Ultra 9 275HX and 128 GB): the Mac takes about 1.5× as long for modeling. Its graphics
  test is a different set, so it is left out.
- **2026:** measured on 2026.0. There is no Windows reference for 2026, and other apps were using a lot of CPU during
  the run.
