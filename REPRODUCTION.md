> [English](REPRODUCTION.md) | [中文](REPRODUCTION.zh.md)

# Reproduction appendix

Everything in the README was run on the machine described below. This file lists the exact
commands and the raw observations, so a reader can repeat or falsify them.

## Machine under test

```
CPU/APU : AMD Ryzen 9 5900HX (Cezanne), integrated Radeon (gfx1031-class iGPU, Vulkan GPU0)
dGPU    : AMD Radeon RX 6800M, gfx1031, RDNA2 mobile, 12272 MB VRAM (Vulkan GPU1)
RAM     : 31.4 GB
OS      : Windows 11, build 26300
Adapter : 240 W
```

## Device indices (the thing to check first on any two-GPU laptop)

```bat
vulkaninfo --summary
```
```
GPU0: deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU  deviceName = AMD Radeon(TM) Graphics
GPU1: deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU    deviceName = AMD Radeon RX 6800M
```

Cross-check with a ggml Vulkan build:

```bat
llama-server --list-devices
```
```
Vulkan0: AMD Radeon(TM) Graphics (16335 MiB, 15518 MiB free)
Vulkan1: AMD Radeon RX 6800M (12272 MiB, 11474 MiB free)
```

Then, with `GGML_VK_VISIBLE_DEVICES` set, only the selected device is visible:

```
GGML_VK_VISIBLE_DEVICES=0 -> Vulkan0: AMD Radeon(TM) Graphics
GGML_VK_VISIBLE_DEVICES=1 -> Vulkan0: AMD Radeon RX 6800M
```

**So on this machine `0` is the iGPU.** Do not assume that on yours — enumerate.

## The 9B local LLM as measured

```
llama-server.exe -m models/<9B>-Q6_K.gguf --mmproj models/mmproj-BF16.gguf \
  --host 127.0.0.1 --port 8085 -c 65536 --fit on -fa auto --jinja \
  --parallel 1 --cache-type-k q8_0 --cache-type-v q8_0 \
  --spec-type draft-mtp --spec-draft-n-max 4 -n 65536
```

```
port bound                : ~5 s after start
model fully resident      : ~1 min
/health                   : {"status":"ok"}
VRAM used                 : 10846 MB of 12243 MB   (1397 MB free)
idle power                : ~20 W total, GPU hot spot 46 C
```

## The two-GPU power measurement

LibreHardwareMonitor (via pythonnet, `corelib` loaded before `import clr`) sampled
CPU package power, GPU power and temperatures every 2 s while the same image request ran.

```
encoder on RX 6800M (dGPU) : machine peak 313 W   encode ~2 s   answer exact
encoder on Cezanne  (iGPU) : machine peak 191 W   encode ~2 s   answer exact
```

## The power-cut event signature

```
event 6008, written at the NEXT boot:
  "The previous system shutdown at 1:24:21 on 2026/10/11 was unexpected."

no 6006 (clean shutdown)   no 1074 (process requested it)   no 109 (kernel shutdown transition)
no Kernel-Power 41
```

Outage lengths observed after self-cuts, with the load in the 5 minutes before each cut:

```
duration   pre-cut peak    pre-cut GPU hot spot
 50.4 min      (no data)         (no data)
 22.7 min        34 W             56 C      <- idle
  9.0 min        55 W             66 C      <- light
 18.8 min       244 W            101 C      <- sustained
```

Length does not track temperature or load. A cold machine took longer to return than a hot one.