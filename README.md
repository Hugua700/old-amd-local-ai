# Local LLMs and diffusion on an old AMD Radeon — measured, reproducible notes

> Companion documents:
> * **[ComfyUI on a gfx1031 card: what runs, and what it costs in watts](COMFYUI-GFX1031.md)**
> * **[Local LLMs on a gfx1031 card: the config, the VRAM budget, and the failure that looks like a bug](LLM-GFX1031.md)**

Field notes from one machine that the ecosystem does not officially serve:
**AMD Radeon RX 6800M, `gfx1031`, RDNA2 mobile, Windows 11**, one 240 W adapter.

Most local-AI tooling targets CUDA. Where AMD is supported, the published binaries usually
cover the cards the maintainers own — `gfx1100/1101/1102/1200/1201`, sometimes `gfx1030`.
`gfx1031` is regularly left out, which is how a laptop GPU ends up with no ready-made engine
at all. These notes are what it took to make that machine useful, with the numbers measured
rather than assumed.

Everything below was run on this card. Numbers are single-machine medians or peaks from a
2 s-interval logger, and each one says how it was measured.

---

## 1. What actually works on gfx1031

| Job | Stack | Result |
|---|---|---|
| Local LLM chat/vision | `llama.cpp` **Vulkan** build (`llama-server`) | 9B Q6_K + BF16 mmproj, 64K context, MTP speculative decoding — fully in 12 GB VRAM |
| Big MoE inference | **Strata** HIP engine, **self-built for gfx1031** | works where the published engine refuses: "your GPU is gfx1031" |
| Image understanding | `strata-vision`, **Vulkan**, pinned to the **iGPU** | correct on a 768x512 test image |
| Image/video generation | ComfyUI on a second machine (RTX 5070 laptop), driven over the LAN | keeps the AMD box free for LLM duty |

Two facts worth stating plainly, because they cost the most time to learn:

* **Building for gfx1031 does not need an AMD GPU.** The Strata engine build is a
  cross-compile: ROCm's clang compiles the device code, MSVC supplies headers and the linker.
  We built the gfx1031 engine on an **NVIDIA-only Windows box**, and it serves correctly on
  the AMD card.
* **The published AMD engine omitted `gfx1031` even though the build script's default
  `STRATA_HIP_ARCHS` list contains it.** Building it ourselves with `-Archs gfx1031` took
  ~4 minutes, produced a 126 MB zip (`blas_lib_gfx1031.kpack` inside), and serves fine.
  That asymmetry is reported upstream.

## 2. The one build trap that blocks everything (Windows, MSVC)

Building the **Vulkan** image encoder on Windows fails with

```
Could not find a package configuration file provided by "SPIRV-Headers"
```

**even with `VULKAN_SDK` set**, because older Vulkan SDKs (1.4.304 here) ship
`SPIRV-HeadersConfig.cmake` directly in `Lib\cmake\` rather than in a `SPIRV-Headers\`
subdirectory, which CMake's prefix search does not match. Fix:

```bat
cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DSPIRV-Headers_DIR="%VULKAN_SDK%\Lib\cmake"
```

(Newer SDKs, e.g. 1.4.350, do have the subdirectory and are found from `VULKAN_SDK` alone.
Both are now documented upstream.)

A second trap on VS-2026-only machines: `find_vcvars()` applied CUDA's
`[16.0,18.0)` version range to *every* caller, so a machine whose only C++ tools are
Visual Studio 2026 (version 18) got `None` back and could not build the encoder at all.
Fixed upstream: non-CUDA callers now ask `vswhere` for no range, and `STRATA_VCVARS`
can point at a `vcvars64.bat` by hand.

## 3. On a laptop with two GPUs, the encoder's card choice costs ~120 W

This machine exposes two Vulkan devices:

```
GPU0 = AMD Radeon(TM) Graphics   PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU   (Cezanne iGPU)
GPU1 = AMD Radeon RX 6800M       PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
```

The encoder honours `GGML_VK_VISIBLE_DEVICES`. Measured with the same request both ways,
LibreHardwareMonitor sampling CPU package power and GPU power every 2 s:

| encoder device | machine peak | image encode | answer |
|---|---|---|---|
| RX 6800M (dGPU) | **313 W** | ~2 s | exact |
| Cezanne iGPU | **191 W** | ~2 s | exact |

**The encode is only about 2 s of the request either way**, so pinning it to the integrated
GPU removes a ~120 W spike for nothing in speed. On this machine the adapter is 240 W, so
that spike is not academic.

Worth knowing: when `GGML_VK_VISIBLE_DEVICES` is unset, `clip.cpp` prefers a discrete GPU and
falls back to an integrated one only if there is none — so the *default* here is the 313 W
case. Pin it explicitly:

```json
"env": { "GGML_VK_VISIBLE_DEVICES": "0" }
```

## 4. Local LLM sizing on a 12 GB card (measured, not guessed)

`llama.cpp` Vulkan build, 9B Q6_K, BF16 mmproj, 64K context, `q8_0` KV cache,
int8 KV, MTP speculative decoding enabled:

```
:8085 ready ~5 s after start, model fully resident
VRAM: 10846 MB used of 12243 MB  (1397 MB free)
idle: ~20 W total, GPU hot spot 46 C
```

The practical lesson: **on a 12 GB card, a 9B with vision + a 64K KV cache leaves no room
for anything else.** Running a second LLM server alongside it (Ollama, LM Studio) will either
fail to load or force evictions. A second large model — a 125B MoE engine, for instance —
cannot start at all until the 9B is stopped; the failure looks like an engine bug
(`no VRAM was left`) but is purely a resource conflict.

## 5. Power and thermals on a thin 240 W laptop (the part that bites)

This machine **hard-cuts power** under load — no shutdown, no bugcheck, no `Kernel-Power 41`:

```
next boot: 6008 "The previous system shutdown at <time> was unexpected"
```

Measured facts (all from the 2 s logger, cross-checked against the event log):

* Cuts happened at **idle (34 W, 56 C)**, at **light load (55 W, 66 C)**, and at
  **sustained load (214-246 W, GPU hot spot 91-101 C)**. **No power or thermal threshold
  explains all of them.**
* After a cut the machine **powers itself back on** — outage lengths observed:
  **9.0 / 18.8 / 22.7 / 50.4 minutes**, and they do **not** correlate with temperature or
  load. A cold machine took 22.7 minutes; a hot one took 18.8.
* The OS never thermally throttles on this box: `ACPI _TZ.TZ01` reports `_PSV = 0K` and
  `_AC0.._AC9 = 0K`. The cut is firmware/EC-level and silent.
* **The GPU fan sensor reads 0 in every sample, all day.** Whether that is a real fan fault
  or an unsupported sensor is unresolved; physically checking exhaust airflow is the
  cheap next step.

**Conclusion for anyone on a similar machine: software cannot make this safe.** Document your
device's behaviour, keep the work off the machine where you can, and treat the power path
(battery, BMS, VRM, EC) as the suspect.

## 6. An architecture that survives an unreliable machine

Two Windows boxes on one tailnet:

* **Box A (the AMD one, power-unreliable):** local LLM only — `llama-server` on `:8085`,
  registered to start at logon, idempotent (skips when the port is already bound).
* **Box B (NVIDIA):** ComfyUI, driven by `POST /prompt` + `GET /history/<id>` from Box A.
  Image and video generation never touch Box A's VRAM.

Then, because Box A can vanish at any moment:

* **Everything that matters lives in a git repo and is pushed** — notes, scripts, configs.
* **A copy is pushed to a third machine** — packaged as one zip per theme, never as loose
  files: on a 31 ms-RTT link, one 126 MB file moved at **5.3 MB/s** while 1183 small files
  totalling 11.6 MB crawled at **0.026 MB/s**. **Zip before you copy.**
* **A direct link beats a relay.** The same pair of machines moved data at 3.3-5.3 MB/s
  direct and at **0.05 MB/s** through an intermediate host on a relayed path.

## 7. Traps worth repeating (they cost hours each)

1. **`$ErrorActionPreference = 'Stop'` plus native tools is a landmine.** `git`, `cmake` and
   friends write normal progress to stderr; PowerShell turns that into a terminating error,
   so a script dies *after a successful command* with no output at all — invisible when it
   runs from a scheduled task. Use `Continue` and check `$LASTEXITCODE`.
2. **Function names can collide with aliases.** `R` is `Invoke-History`; aliases win over
   functions, so a helper named `R` silently became "print history".
3. **Nested quoting across PowerShell -> ssh -> cmd splits arguments at spaces.** Write the
   command into a `.cmd` or `.ps1`, copy the file, then run it with one simple command.
4. **Never `taskkill /T` a process you started yourself** — if it is in your job tree you
   take the tree down with it.
5. **`Compress-Archive` fails entirely if any file is held open** (a log being written, a
   model server's stderr). Copy with `FileShare.ReadWrite` first, then zip.
6. **`Get-ChildItem -Include` returns nothing** without `-Recurse` or a `\*` path — silently.
7. **Verify with foreign evidence, not your own echo.** Matching a sentinel that you sent
   proves nothing; use the exit code and a value the remote generated.
8. **Never compute a rate from a failed transfer.** Require exit code 0 *and* a byte-count
   match before quoting a number.

## 8. What is upstream, and what is still open

Reported and merged/credited upstream:

* `find_vcvars()` without CUDA asks `vswhere` for no version range, plus `STRATA_VCVARS`
  (in v0.1.42).
* `SPIRV-Headers_DIR` on older Windows Vulkan SDKs, and the two-GPU power measurement
  (both in `docs/AMD_HIP.md`).

Open: whether the published engine matrix will include `gfx1031`, so that RX 6700 XT /
6800M owners no longer have to self-build for a card the build script already targets by
default.

---

*If you run an old AMD card and any of this saves you an afternoon, that is the point of
writing it down. Corrections and counter-measurements are welcome — several of the numbers
above were wrong the first time and only got fixed by measuring again.*