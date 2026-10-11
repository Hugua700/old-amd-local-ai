# ComfyUI on a gfx1031 card: what runs, and what it costs in watts

Companion to the main README, same machine: **RX 6800M (gfx1031, RDNA2 mobile, 12272 MB VRAM)**,
240 W adapter, Windows 11. The short version: **generation on this card works, but the power bill
is the hard constraint, not the VRAM.**

Every number below was measured on this box with a 2 s-interval logger (CPU package power, GPU
power, CPU temperature, GPU core and hot-spot temperature) and cross-checked against the workload's
own timings.

---

## 1. The pack matters more than the card

A stock ComfyUI install is not what you want on an old AMD card. What is running here:

```
E:\AI_work_v5\ComfyUI          python_embeded + 31 custom_nodes -> 2351 nodes
(compare: a stock Comfy-Desktop install -> 1075 nodes, 13 custom_nodes)

AMD/ROCm-specific nodes in it:
  XB-SageAttn   attention tuned for ROCm on gfx1031
  XB-llama      llama.cpp integration built for ROCm
  JZL-llama     the same, alternate build
  + SeedVR2 optimisations
```

The difference is not cosmetic: the ROCm attention path is what makes the difference between
"this workflow runs" and "this workflow runs at a usable speed" on RDNA2.

**Launching:** a launcher `.bat` per port is enough. This box keeps two:
`AutoLaunch_ComfyUI.bat` (8188) and a second profile on 8194, so two configurations can run
side by side without fighting over the model cache.

**Model paths:** rather than duplicating multi-gigabyte checkpoints per install, add the other
install's tree to `extra_model_paths.yaml`. One entry gave this pack the whole z-image / LTXV
family that already existed elsewhere on disk.

## 2. What actually runs here

| Job | Model | Notes |
|---|---|---|
| Image generation | Z-Image Turbo (bf16) + Qwen-3 4B text encoder + `ae` VAE | 1024x768, 8 steps, cfg 1.0, euler/simple |
| Image generation | Qwen-Image 2.1 int8 | heavier, fits |
| Text-conditioned video | LTXV | 512x320x25 frames used for the power measurements below |
| Upscaling / restore | SeedVR2 | the pack ships tuned nodes for it |
| Image understanding | `strata-vision` (Vulkan, llama.cpp mtmd) | pinned to the iGPU — see §4 |

## 3. The power bill (the part nobody warns you about)

Same machine, same kind of workload, different settings. All peaks, 2 s sampling:

```
image generation          226 - 244 W
video generation          ---
   on the Performance/Turbo profile      up to 323 W
   on Silent                             ~227 W
   with a 45 W SMU power wall            ~125 W     (see §4 - not a path we kept)
local LLM inference       89 W (with a 45 W wall)  /  145 W (no wall)
```

**Context that matters:** the adapter is **240 W**, and this machine **hard-cuts power** when
peaks exceed it — no shutdown, no bugcheck. See the main README §5 for the event-log signature.
So on a thin laptop, a 323 W peak is not "hot", it is **a crash waiting for the right moment**.

**Cooling reality check:** the GPU hot spot reached **101-108 C** during these runs. The ACPI
thermal zone on this machine reports `_PSV = 0K` and `_AC0.._AC9 = 0K`, i.e. **Windows never
thermally throttles or shuts down here** — the only limiter is the firmware/EC cutting power.
The GPU fan sensor reads **0 in every sample**; whether that is a real fan fault or an
unsupported sensor is still open on this unit.

## 4. The four levers, in order of how much they actually help

**1. Pin the Vulkan image encoder to the integrated GPU. (-122 W, nearly free)**
On a two-GPU laptop the encoder's device choice moves the whole machine's peak by ~120 W while
the encode itself is only ~2 s of the request either way:

```
encoder on RX 6800M : peak 313 W
encoder on iGPU     : peak 191 W
```

Pin it in the config rather than with a wrapper — the config's `env` block reaches the encoder:

```json
"env": { "GGML_VK_VISIBLE_DEVICES": "0" }
```

Verify your indices first; do not assume `0` is the iGPU (it is here, via `vulkaninfo --summary`
and `llama-server --list-devices`, but that is machine-specific).

**2. Use the quiet fan profile. (-96 W on video)**
On the video workload the Silent profile cut the peak from **323 W to ~227 W**. Our first
measurement said "Silent helps little (191 -> 186 W)" — that was taken on the *wrong workload*
(an LLM) and was simply wrong. Re-measure per workload.

**3. Cap the CPU. (image CPU peak 124 -> 98 W)**
`PROCTHROTTLEMAX 80% -> 75%` cut the CPU peak during image generation by about 26 W.

But the real speed lever turned out to be a different setting: **`PROCTHROTTLEMIN`**.
On this machine, same job:

```
MIN 20%   -> 83.2 s
MIN 50%   -> 25.6 s      <- sweet spot
MIN 100%  -> 26.7 s
```

A low *minimum* processor state was the actual bottleneck. Set all four power schemes, and
re-check after the vendor tool (Armoury Crate here) switches schemes — it can clobber them.

**4. What we tried and abandoned: a 45 W SMU power wall.**
It was by far the most effective single lever (CPU 191 -> 53 W, exactly pinned at 45.0 W), and
it needed `ryzenadj` plus a kernel-level driver. **The driver tripped Windows Defender's
vulnerable-driver detection and was removed.** We are not recommending that path; if you want a
power wall, prefer firmware/BIOS or a vendor-supported tool.

## 5. Two benchmarking traps that will fool you

**Trap 1 — the execution cache.** ComfyUI will happily return `execution_cached` for every node
and finish in seconds if the workflow, parameters *and seed* are unchanged. A "5.1 s image test"
at 26 W is not a result, it is a cache hit. **Always change an upstream parameter or the prompt**
between runs, then confirm the queue actually executed and the output file's timestamp moved.

**Trap 2 — `POST /free`.** Calling it with `{"unload_models": true, "free_memory": true}` and then
running a workflow **hard-hangs this instance**; neither `/interrupt` nor clearing the queue
recovers it, and only restarting the instance does. If you need a cold load for a measurement,
restart the instance instead of calling `/free`.

## 6. When the card is not the right place to run it at all

The most useful architectural decision we made: **this machine does not generate images.**
It runs the local LLM; a second box on the same tailnet runs ComfyUI for images and video, driven
over HTTP from the AMD machine:

```
POST /prompt            -> prompt_id
GET  /history/<id>      -> outputs
GET  /view?filename=... -> the image
```

That is worth it when your AMD box is power-marginal: generation is exactly the workload that
pushes it over the adapter. Measure your own headroom first — if image generation peaks above
your adapter's rating, the second machine is not a luxury, it is the fix.

## 7. Honest boundaries

* **Image and video generation both work** on gfx1031 with a ROCm-tuned pack, within the power
  limits above.
* We have **not** verified this card against the newest attention/kernel paths from upstream
  ComfyUI releases; the tuned node pack is doing the heavy lifting.
* The `45 W wall` result is real but the method is one we removed. Treat the number as an upper
  bound on what good power management could give you, not as a recipe.
* The fan sensor reading 0 is unresolved. If your card does the same, check airflow physically
  before trusting anything else.