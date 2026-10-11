# Local LLMs on a gfx1031 card: the config, the VRAM budget, and the failure that looks like a bug

Third companion to the main README. Same machine: **RX 6800M (gfx1031, RDNA2 mobile, 12272 MB
VRAM)**, 31.4 GB RAM, Windows 11, no CUDA anywhere.

The point of this document is that **an old AMD card can serve a capable local model with vision
and a long context, entirely in VRAM**, and the way it fails when you get greedy is *misleading*.

---

## 1. Pick the right backend first

Two different jobs on the same card need two different backends here:

| Job | Backend | Why |
|---|---|---|
| Chat / vision, GGUF models | **llama.cpp Vulkan** | no ROCm install, works on any Vulkan 1.2+ driver, ships prebuilt for Windows |
| Large MoE engines built for AMD | **HIP / ROCm** (self-built for `gfx1031`) | the published AMD engine did not include this arch — see the main README §1 |

For "I just want a local model answering questions, with image input", the **Vulkan** path is the
short one: download a release zip, run `llama-server.exe`, done. No ROCm, no compiler, no
`gfx1031` packaging problem.

## 2. The configuration that works here

```
llama-server.exe
  -m      models/<9B>-Q6_K.gguf
  --mmproj models/mmproj-BF16.gguf            # vision
  --host 127.0.0.1 --port 8085
  -c      65536                                # 64K context
  --fit on -fa auto --jinja
  --parallel 1
  --cache-type-k q8_0 --cache-type-v q8_0      # quantised KV cache
  --spec-type draft-mtp --spec-draft-n-max 4   # MTP speculative decoding
  -n      65536
```

Measured on this card:

```
port bound after start     ~5 s
model fully resident       ~1 min
VRAM used                  10846 MB of 12243 MB   (1397 MB free)
idle power                 ~20 W total, GPU hot spot 46 C
```

**`--jinja` is the default in current builds**; passing it is harmless and makes the intent
explicit. If you need the old behaviour, it is `--no-jinja`.

## 3. The VRAM budget, and what it means in practice

A 9B at Q6_K is roughly 8 GB of weights. What actually consumes the card:

```
9B Q6_K weights            ~8.2 GB
mmproj (BF16 vision)       ~0.9 GB
64K KV cache at q8_0       ~1.5-1.7 GB
MTP draft head             small
                          ---------
                          ~10.8 GB of 12.2 GB   <- measured
```

**The rule that follows from this, and it is the most useful thing in this document:**

> **On a 12 GB card, one 9B with vision and a 64K context leaves no room for a second model.**

This is not a limitation you can tune around. It changes how you run things:

* do **not** leave a second LLM server running (Ollama, LM Studio, a second `llama-server`) —
  the second one either fails to load or evicts the first;
* do **not** plan to run image generation on the same card while the LLM is resident — the
  diffusion models need the same VRAM;
* if you want both, **split them across machines** (main README §6).

**Sizing for this card, honestly labelled:**

| Model | Quant | Fits? | Status |
|---|---|---|---|
| 9B + vision + 64K KV | Q6_K | **yes**, comfortably | measured, running daily |
| 9B | Q8_0 | yes, with less KV headroom | expected, not measured here |
| 27B | IQ2 (~7.4 GB) | should fit | **not tested on this machine** |
| 27B | Q4_K_M (~16 GB) | no | won't fit in 12 GB |

## 4. The failure that reads like an engine bug (it is not)

Start a second large model while the first is resident and you get this, from a HIP engine:

```
strata generate: expert cache auto: the 700 MiB reserve leaves too few slots on this card
                 (a working cache needs 379): a 484 MiB reserve instead -> 379 slots
strata generate: only 0 MiB free once the slots are written (reserve 484 MiB); shrinking...
strata serve: verify: needs the profile-filled VRAM expert tier (--expert-profile and
              --expert-cache); with --expert-cache auto, no VRAM was left for it
```

Nothing in that text says "another process is using the GPU". It reads like a broken
configuration or a bad build. **The actual cause was a 9B `llama-server` holding 10.8 GB.**

Measured, on this machine:

```
before stopping the 9B : D3D dedicated memory used = 10846 MB  (free  1397 MB)
after  stopping the 9B : D3D dedicated memory used =   251 MB  (free 11992 MB)
```

**Check the VRAM accounting before you debug the engine.** `vulkaninfo --summary`,
`nvidia-smi` on the other side, or a hardware monitor's GPU memory counters are all enough.

## 5. Autostart that does not fight you

If you want the model up after every boot — including after an unexpected power loss — make the
starter **idempotent** and **hidden without flashing a console**:

```powershell
# start <model>.ps1
if (Get-NetTCPConnection -State Listen -LocalPort 8085 -ErrorAction SilentlyContinue) {
    exit 0                      # already serving - do not start a second copy
}
Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $dir `
    -WindowStyle Hidden -RedirectStandardOutput <log> -RedirectStandardError <err>
```

and launch that script from the Startup folder through a tiny VBS so the window is created
hidden from the start:

```vbs
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File <path>\start.ps1", 0, False
```

**Do not** put `-WindowStyle Hidden` inside the chain instead: that creates a visible console
and then hides it, which is the flash you were trying to avoid. The window style belongs in
`WshShell.Run`.

Two things worth doing at the same time: **disable other LLM services' autostart** (a boot-triggered
Ollama service was quietly returning here and competing for the card), and **check the startup
entry you removed is not matched by a scheduled task** — ours was, and it came back every boot.

## 6. Tuning notes that actually moved the needle

* **MTP speculative decoding** (`--spec-type draft-mtp --spec-draft-n-max 4`) — uses the model's
  own multi-token-prediction head as the draft. Free speed where the GGUF has it.
* **Quantised KV cache** (`q8_0`) is what makes a 64K context affordable on 12 GB. Without it,
  64K does not fit alongside vision.
* **`--fit on` / `-fa auto`** let the build choose sensible values instead of hand-tuning.
* **`--parallel 1`** for a single user: extra slots duplicate KV cache for no benefit.
* Keep the model on a fast disk — the first load reads ~8 GB.

## 7. Honest boundaries

* The 9B configuration above is **measured and in daily use** on this card.
* The 27B-at-IQ2 line is an **expectation from the arithmetic, not a measurement** — treat it as
  "worth trying", not as a fact.
* The VRAM breakdown in §3 is a reconciliation of the measured total against known component
  sizes; individual lines are approximate.
* Throughput in tokens/s is **deliberately absent**: it depends on the model, the quant, the
  context length and the prompt, and a single number without those conditions would mislead.
  Measure your own, with a fixed prompt and a warmed-up model.