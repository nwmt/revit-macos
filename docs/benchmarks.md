# Benchmarks

We measure with the [RFO Benchmark](https://www.revitforum.org) (RevitForum.org): a set of Revit journals that build a
model, switch views, export and render, and log the time of every step.

## How we measure

- **Machine:** Apple M5 MacBook, 10 cores (4 performance + 6 efficiency), 16 GB, macOS 26, CrossOver 26.3.
  Revit runs under Rosetta 2 on top of Wine.
- **Set:** Full_Simplified (modeling + graphics), 3 runs in a row, average. The Mac is not used during the runs.
- **Anti-aliasing off** for 2023 and newer. `./revit install` sets this default for 2024 and newer: Revit runs
  better under Wine without it. The benchmark's own `Revit.ini` template turns it on; we turn it off. Revit 2020 is
  measured with anti-aliasing on, as in the benchmark template: it works well there.
- **Same bottle as a normal install.** No extra tuning for the benchmark.

Lower is better. Each Revit year has its own benchmark set, so rows for different years are not comparable with each
other. These are our numbers on one machine, not a promise for yours.

## Results

Full_Simplified, average of 3 runs.

| Revit | Modeling | Graphics | Anti-aliasing | Windows reference |
|---|---:|---:|---|---|
| 2020 | 121.3 s | 24.9 s | on (benchmark template) | Intel i7-10750H laptop: 193.3 s / 43.9 s (over remote desktop) |
| 2023 | 115.1 s | 27.1 s | **off** | Intel i9-13900KS + RTX 4090 desktop: 55.0 s modeling |
| 2024 | 122.9 s | 29.9 s | **off** | Intel i9-13900KS + RTX 4090 desktop: 60.2 s modeling |
| 2025 | 128.1 s | 31.9 s | **off** | Intel i9-13900KS virtual machine (Hyper-V): 84.7 s modeling |
| 2026 | 128.0 s | 32.4 s | on (benchmark template) | none |
| 2027 | 99.0 s | 27.9 s | **off** | Intel Core Ultra 9 275HX + RTX 5090 laptop: 65.2 s modeling |

## Windows references

The Windows numbers for 2023, 2024, 2025 and 2027 come from the reference report that ships with the benchmark. Its
graphics test is a different set, so only modeling is compared. The 2020 reference is an older run of ours on a
Windows laptop, done over remote desktop, which lowers its graphics score.

## Notes per version

- **2020:** measured with anti-aliasing on, on purpose.
- **2023:** runs were steady: modeling 115.4 / 115.4 / 114.4 s, graphics 27.2 / 27.2 / 26.9 s. With anti-aliasing on
  (earlier, same bottle) it was 115.6 s and 28.3 s: modeling is the same, graphics about 4% slower.
- **2024:** measured on 2024.3.6 (build 24.3.60.12). Runs were steady: modeling 123.2 / 122.4 / 123.1 s, graphics
  29.7 / 29.9 / 30.0 s. Windows reference: Revit 2024.0 on the same desktop as for 2023. The Mac takes about 2× as
  long for modeling.
- **2025:** measured on 2025.5 (build 25.5.0.57). Runs were steady: modeling 128.0 / 129.6 / 126.6 s, graphics
  31.9 / 32.0 / 31.9 s. Windows reference: Revit 2025.0 in a Hyper-V virtual machine on an Intel i9-13900KS, 5 GB.
  The Mac takes about 1.5× as long for modeling.
- **2026:** measured on 2026.0, with anti-aliasing on, before we switched to measuring without it; other apps were
  using a lot of CPU during the run. To be re-measured. There is no Windows reference for 2026.
- **2027:** measured on 2027.3 (build 27.3.0.28). Runs were steady: modeling 100.2 / 98.5 / 98.2 s, graphics
  28.0 / 27.9 / 27.9 s. Windows reference: Revit 2027.0 on a laptop with an Intel Core Ultra 9 275HX and 128 GB.
  The Mac takes about 1.5× as long for modeling.
