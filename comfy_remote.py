#!/usr/bin/env python3
"""Minimal client for driving a remote ComfyUI from a machine that should not generate.

Companion to TWO-MACHINE-SPLIT.md. Builds an API-format workflow, submits it, polls
/history, and writes the result locally. No ComfyUI packages needed on this side.

Usage:
    python comfy_remote.py --host 100.x.y.z --port 8190 --prompt "a lighthouse in a storm" \
        --width 1024 --height 768 --out out.png

Environment:
    COMFY_HOST / COMFY_PORT override the defaults.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error

DEFAULT_UNET = "z_image_turbo_bf16.safetensors"
DEFAULT_CLIP = "qwen_3_4b.safetensors"   # loaded as type=qwen_image
DEFAULT_VAE  = "ae.safetensors"


def _post(url, obj, timeout=60):
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _get_json(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def build(positive, negative, w, h, seed, unet, clip, vae, steps, cfg):
    return {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": unet, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": clip, "type": "qwen_image"}},
        "3": {"class_type": "VAELoader",  "inputs": {"vae_name": vae}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": positive, "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
        "6": {"class_type": "EmptySD3LatentImage", "inputs": {"width": w, "height": h, "batch_size": 1}},
        "7": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": steps, "cfg": cfg, "sampler_name": "euler",
            "scheduler": "simple", "denoise": 1.0, "model": ["1", 0],
            "positive": ["4", 0], "negative": ["5", 0], "latent_image": ["6", 0]}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["7", 0], "vae": ["3", 0]}},
        "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "remote", "images": ["8", 0]}},
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default=os.environ.get("COMFY_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("COMFY_PORT", "8190")))
    p.add_argument("--prompt", required=True)
    p.add_argument("--negative", default="")
    p.add_argument("--width", type=int, default=1024)
    p.add_argument("--height", type=int, default=768)
    p.add_argument("--steps", type=int, default=8)
    p.add_argument("--cfg", type=float, default=1.0)
    p.add_argument("--seed", type=int, default=None,
                   help="change this between runs or ComfyUI will answer from its execution cache")
    p.add_argument("--unet", default=DEFAULT_UNET)
    p.add_argument("--clip", default=DEFAULT_CLIP)
    p.add_argument("--vae",  default=DEFAULT_VAE)
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--out", default="out.png")
    a = p.parse_args()

    base = "http://%s:%d" % (a.host, a.port)
    try:
        st = _get_json(base + "/system_stats", timeout=10)
        dev = (st.get("devices") or [{}])[0]
        print("[ok] %s  VRAM %.1f/%.1f GB  queue %d/%d" % (
            dev.get("name"), dev.get("vram_free", 0) / 1e9, dev.get("vram_total", 0) / 1e9,
            len(_get_json(base + "/queue")["queue_running"]),
            len(_get_json(base + "/queue")["queue_pending"])))
    except Exception as e:
        print("[!!] cannot reach ComfyUI at %s (%s)" % (base, type(e).__name__))
        return 2

    seed = a.seed if a.seed is not None else int(time.time()) & 0x7FFFFFFF
    wf = build(a.prompt, a.negative, a.width, a.height, seed, a.unet, a.clip, a.vae, a.steps, a.cfg)
    print("[..] submitting (seed %d, %dx%d, %d steps)" % (seed, a.width, a.height, a.steps))
    pid = _post(base + "/prompt", {"prompt": wf})["prompt_id"]

    t0 = time.time()
    images = None
    while time.time() - t0 < a.timeout:
        time.sleep(2.0)
        h = _get_json(base + "/history/%s" % pid)
        if pid in h:
            outs = h[pid].get("outputs", {})
            for node in outs.values():
                if node.get("images"):
                    images = node["images"]
                    break
            if images is not None:
                break
    if not images:
        print("[!!] no image after %ds - check the ComfyUI console" % a.timeout)
        return 1

    img = images[0]
    q = urllib.parse.urlencode({"filename": img["filename"],
                                "subfolder": img.get("subfolder", ""),
                                "type": img.get("type", "output")})
    with urllib.request.urlopen("%s/view?%s" % (base, q), timeout=120) as r:
        blob = r.read()
    with open(a.out, "wb") as f:
        f.write(blob)
    print("[ok] %s  (%.1f KB)  %.1fs wall" % (a.out, len(blob) / 1024.0, time.time() - t0))
    return 0


if __name__ == "__main__":
    import urllib.parse  # noqa: E402  (kept local so the module reads top-down)
    sys.exit(main())