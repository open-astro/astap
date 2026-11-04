# OpenAstro branch `ara`

This branch is Han Kleijn's ASTAP (https://github.com/han-k59/astap, branch `main`) plus a
small OpenAstro patch to the command-line solver. OpenAstro Ara builds `astap_cli` from this
branch (submodule `third_party/astap`). Changes here are not sent upstream.

## What the patch adds

Han's astap_cli threads the spiral search. This branch also spreads the work before the
search over the same threads, which takes about 1 s of a hinted solve on a 4-core
Raspberry Pi:

- 16-bit FITS read and conversion (`convert_rows_16`, unit_command_line_general.pas)
- mono/bin/crop (`bin_rows`, unit_command_line_solving.pas)
- star detection in row bands with an in-order replay (`find_stars_band`, `collect_bands`),
  so the star list is exactly that of the single-core `find_stars`
- `unit_cli_parallel.pas`: the worker pool. Its thread count follows Han's rule
  (`-threads`, `ASTAP_THREADS`, physical cores)

The output is identical to Han's build at any `-threads` value. CM4 (4 cores, 26 MP frame,
D80): hinted 1.60 s -> 0.63 s, blind 3.71 s -> 2.72 s.

## Syncing with Han

```
git remote add han https://github.com/han-k59/astap.git   # once
git fetch han
git checkout ara
git merge han/main
```

Conflicts are limited to `find_stars`, `bin_mono_and_crop`, `load_fits` (16-bit branch) and
the `HFD` local `r_aperture`. If Han changes the star test in `find_stars`, port it to
`star_candidate` and the thresholds in `find_stars`, then check that `-threads 1` and the
default give the same `.ini` as Han's own build on a set of frames (normal, faint, colour,
float, 8-bit, BSCALE<>1, truncated) at `-z 0..5`.
