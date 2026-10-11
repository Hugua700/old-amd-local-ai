> [English](REPRODUCTION.md) | [中文](REPRODUCTION.zh.md)

# 复现附录

README 中的所有内容都是在下文所述的这台机器上跑出来的。本文件列出了确切的命令和原始观测结果，以便读者复现或证伪。

## 被测机器

```
CPU/APU : AMD Ryzen 9 5900HX (Cezanne), integrated Radeon (gfx1031-class iGPU, Vulkan GPU0)
dGPU    : AMD Radeon RX 6800M, gfx1031, RDNA2 mobile, 12272 MB VRAM (Vulkan GPU1)
RAM     : 31.4 GB
OS      : Windows 11, build 26300
Adapter : 240 W
```

## 设备索引（双 GPU 笔记本上首先要确认的东西）

```bat
vulkaninfo --summary
```
```
GPU0: deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU  deviceName = AMD Radeon(TM) Graphics
GPU1: deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU    deviceName = AMD Radeon RX 6800M
```

再用一个 ggml Vulkan 构建交叉验证：

```bat
llama-server --list-devices
```
```
Vulkan0: AMD Radeon(TM) Graphics (16335 MiB, 15518 MiB free)
Vulkan1: AMD Radeon RX 6800M (12272 MiB, 11474 MiB free)
```

接着设置 `GGML_VK_VISIBLE_DEVICES`，此时只有被选中的设备可见：

```
GGML_VK_VISIBLE_DEVICES=0 -> Vulkan0: AMD Radeon(TM) Graphics
GGML_VK_VISIBLE_DEVICES=1 -> Vulkan0: AMD Radeon RX 6800M
```

**所以在这台机器上 `0` 就是 iGPU。** 别在你的机器上想当然 —— 要枚举确认。

## 实测的 9B 本地 LLM

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

## 双 GPU 功耗测量

LibreHardwareMonitor（经 pythonnet，`corelib` 在 `import clr` 之前加载）每 2 s 采样一次
CPU package power、GPU power 和温度，期间反复执行同一个图像请求。

```
encoder on RX 6800M (dGPU) : machine peak 313 W   encode ~2 s   answer exact
encoder on Cezanne  (iGPU) : machine peak 191 W   encode ~2 s   answer exact
```

## 断电事件的特征

```
event 6008, written at the NEXT boot:
  "The previous system shutdown at 1:24:21 on 2026/10/11 was unexpected."

no 6006 (clean shutdown)   no 1074 (process requested it)   no 109 (kernel shutdown transition)
no Kernel-Power 41
```

自发断电后观测到的停电时长，以及每次断电前 5 分钟内的负载：

```
duration   pre-cut peak    pre-cut GPU hot spot
 50.4 min      (no data)         (no data)
 22.7 min        34 W             56 C      <- idle
  9.0 min        55 W             66 C      <- light
 18.8 min       244 W            101 C      <- sustained
```

时长与温度或负载没有相关性。冷机恢复所需的时间反而比热机更长。
