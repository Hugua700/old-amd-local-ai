> [English](TWO-MACHINE-SPLIT.md) | [中文](TWO-MACHINE-SPLIT.zh.md)

# Two machines, one job: keep the old AMD card for the LLM and generate elsewhere

Fourth companion to the main README. The idea is simple and it solved the biggest practical problem
on this setup: **an old AMD laptop is a fine LLM host and a marginal image/video host.** Instead of
tuning until generation barely fits, put generation on another box and drive it over the network.

This is not only for people with two machines — it is also the sane answer for anyone whose card is
power- or thermal-marginal, which on RDNA2 mobile is most of them.

---

## 1. Why split at all

Three pressures push in the same direction:

* **VRAM.** One 9B with vision and a 64K context already uses ~10.8 GB of 12 GB (see
  `LLM-GFX1031.md`). Diffusion models want the same memory.
* **Power.** On this machine image generation peaked at **226-244 W** and video at up to
  **323 W**, against a **240 W adapter** that the machine hard-cuts above. LLM inference is far
  cheaper: 89-145 W.
* **Blast radius.** Generation is the workload that crashes this box. If it runs elsewhere, the
  LLM host stays up.

## 2. The division

```
Box A  (AMD, gfx1031, power-marginal)      Box B  (any GPU with a working ComfyUI)
  llama-server            :8085               ComfyUI              :8190
  LLM + vision, resident                       image / video / upscale
        |                                            ^
        +------------- HTTP over the LAN ------------+
                    POST /prompt -> poll /history -> GET /view
```

Both boxes on the same tailnet (or LAN). Box A never loads a diffusion model.

## 3. What Box B has to expose

ComfyUI's HTTP API is small and stable enough to drive from a script:

| Endpoint | Use |
|---|---|
| `POST /prompt` | submit `{"prompt": <api-format workflow>}` -> returns `prompt_id` |
| `GET /history/<prompt_id>` | poll until the run appears; outputs are in `outputs` |
| `GET /view?filename=..&subfolder=..&type=output` | fetch the produced file |
| `GET /queue` | running/pending counts, so you can wait for a quiet moment |
| `GET /system_stats` | device name, VRAM total/free |
| `POST /upload/image` | **see the security note in §6** |

Start it listening on the network (`--listen 0.0.0.0 --port 8190`) — and read §6 before you do.

## 4. A client that actually works

`comfy_remote.py` in this repo is the trimmed-down version of what runs here. It builds the
API-format workflow in code, submits it, polls, and writes the image out. The essential shape:

```python
wf = {
  "1": {"class_type": "UNETLoader",       "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
  "2": {"class_type": "CLIPLoader",       "inputs": {"clip_name": CLIP, "type": "qwen_image"}},
  "3": {"class_type": "VAELoader",        "inputs": {"vae_name": VAE}},
  "4": {"class_type": "CLIPTextEncode",   "inputs": {"text": PROMPT, "clip": ["2", 0]}},
  "5": {"class_type": "CLIPTextEncode",   "inputs": {"text": NEG,    "clip": ["2", 0]}},
  "6": {"class_type": "EmptySD3LatentImage", "inputs": {"width": W, "height": H, "batch_size": 1}},
  "7": {"class_type": "KSampler",         "inputs": {"seed": SEED, "steps": 8, "cfg": 1.0,
                                                     "sampler_name": "euler", "scheduler": "simple",
                                                     "denoise": 1.0, "model": ["1", 0],
                                                     "positive": ["4", 0], "negative": ["5", 0],
                                                     "latent_image": ["6", 0]}},
  "8": {"class_type": "VAEDecode",        "inputs": {"samples": ["7", 0], "vae": ["3", 0]}},
  "9": {"class_type": "SaveImage",        "inputs": {"filename_prefix": "remote", "images": ["8", 0]}},
}
```

Notes that cost us time:

* **These are API-format node graphs, not the UI workflow JSON.** The UI format has `nodes`/`links`
  arrays and will be rejected.
* **`SaveImage` is what puts the file on disk**; without it nothing is retrievable by `/view`.
* **Change the seed (or any upstream parameter) between runs.** Otherwise ComfyUI returns
  `execution_cached` for every node and the "run" finishes in seconds without computing anything —
  the single most common way to fool yourself when benchmarking (see `COMFYUI-GFX1031.md` §5).

## 5. What it costs in wall time (measured, on the remote box)

```
1024x768, 8 steps, cfg 1.0 : 20.4 s engine time   /   95.4 s wall including model load
 768x768                   : 45.3 s
```

The wall-vs-engine gap is model loading and queueing — which is exactly why the LLM host should
not also be the generation host: it would be competing for the same disk and the same GPU.

## 6. Security, honestly

**A ComfyUI bound to `0.0.0.0` with no authentication is an open endpoint on your network.** Anyone
who can reach the port can submit arbitrary workflows (i.e. make your machine compute and write
files) and can read the output directory.

We hit a concrete example: **`POST /upload/image` accepted an arbitrary file** and wrote it into
ComfyUI's `input/` directory. That is genuinely convenient — it is how a script got delivered to
the remote box in this setup — and it is also **an unauthenticated file-drop**, on the tailnet, for
any device that can reach the port. Both statements are true; decide accordingly.

Practical mitigations, cheapest first:

1. **Do not expose it to the internet.** Tailnet/LAN only.
2. **Restrict the port in the firewall** to the specific peers that should reach it (on Windows,
   a firewall rule scoped to the tailnet subnet or to individual addresses).
3. **Bind to one interface** (`--listen <tailnet-ip>`) instead of `0.0.0.0` where the driver allows.
4. **Put an authenticating reverse proxy in front** if more than a couple of machines need it.

We left ours reachable on the tailnet, deliberately, because tightening it would have broken a
working pipeline — but it is a decision, not an oversight, and it is written down here so it stays
a decision.

## 7. Honest boundaries

* The endpoints and the workflow shape above are **what this setup actually uses**; ComfyUI's API
  is not formally versioned, so re-check `/object_info` after a major upgrade.
* Timing figures are from one machine (an RTX 5070 Laptop) and will differ everywhere.
* The two-machine split removes *generation* load from the AMD box. It does **not** fix a hardware
  power fault — if your machine cuts under load for hardware reasons, that still needs fixing. It
  just stops you from deliberately triggering it.