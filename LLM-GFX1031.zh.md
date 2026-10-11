> [English](LLM-GFX1031.md) | [中文](LLM-GFX1031.zh.md)

# 在 gfx1031 显卡上跑本地 LLM：配置、VRAM 预算，以及那个看起来像引擎 bug 的失败

主 README 的第三篇配套文档。同一台机器：**RX 6800M（gfx1031，RDNA2 移动版，12272 MB
VRAM）**，31.4 GB 内存，Windows 11，全程没有 CUDA。

本文要说明的是：**一块老 AMD 显卡完全可以在 VRAM 里完整跑起一个带视觉、带长上下文的可用
本地模型**，而当你贪心过头时它失败的方式具有*误导性*。

---

## 1. 先选对后端

在同一块卡上，两类不同的任务在这里需要两个不同的后端：

| 任务 | 后端 | 原因 |
|---|---|---|
| 对话 / 视觉，GGUF 模型 | **llama.cpp Vulkan** | 不需要装 ROCm，任何 Vulkan 1.2+ 驱动都能跑，Windows 有预编译包 |
| 为 AMD 构建的大型 MoE 引擎 | **HIP / ROCm**（针对 `gfx1031` 自行构建） | AMD 发布的引擎不包含这个架构 —— 见主 README §1 |

如果只是"我就想要一个本地模型回答问题，能收图片"，**Vulkan** 这条路径最短：下载一个 release
zip，运行 `llama-server.exe`，完事。不需要 ROCm，不需要编译器，也没有 `gfx1031` 的打包问题。

## 2. 在这台机器上能跑通的配置

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

在这块卡上实测：

```
port bound after start     ~5 s
model fully resident       ~1 min
VRAM used                  10846 MB of 12243 MB   (1397 MB free)
idle power                 ~20 W total, GPU hot spot 46 C
```

**`--jinja` 在当前构建里是默认值**；显式加上没有坏处，还能把意图写清楚。如果你需要旧行为，
那是 `--no-jinja`。

## 3. VRAM 预算，以及它在实践中的含义

一个 Q6_K 的 9B 大约有 8 GB 权重。真正吃掉显卡的是这些：

```
9B Q6_K weights            ~8.2 GB
mmproj (BF16 vision)       ~0.9 GB
64K KV cache at q8_0       ~1.5-1.7 GB
MTP draft head             small
                          ---------
                          ~10.8 GB of 12.2 GB   <- measured
```

**由此得出的规则，也是本文最有价值的一条：**

> **在 12 GB 的卡上，一个带视觉、64K 上下文的 9B 模型不会给第二个模型留下任何空间。**

这不是靠调参能绕过去的限制。它改变了你的运行方式：

* **不要**再留第二个 LLM 服务器在跑（Ollama、LM Studio、第二个 `llama-server`）——
  第二个要么加载失败，要么把第一个挤掉；
* **不要**打算在 LLM 常驻的同时用同一块卡跑图像生成 —— 扩散模型需要的是同一份 VRAM；
* 如果两个都想要，**把它们拆到不同机器上**（主 README §6）。

**针对这块卡的规模评估，如实标注：**

| 模型 | 量化 | 装得下吗？ | 状态 |
|---|---|---|---|
| 9B + vision + 64K KV | Q6_K | **装得下**，还很宽松 | 已实测，日常在用 |
| 9B | Q8_0 | 装得下，但 KV 余量更少 | 预期如此，本机未实测 |
| 27B | IQ2（~7.4 GB） | 应该装得下 | **本机未测试** |
| 27B | Q4_K_M（~16 GB） | 装不下 | 12 GB 塞不进去 |

## 4. 那个读起来像引擎 bug 的失败（其实不是）

在第一个模型常驻时启动第二个大模型，你会从 HIP 引擎得到这样的输出：

```
strata generate: expert cache auto: the 700 MiB reserve leaves too few slots on this card
                 (a working cache needs 379): a 484 MiB reserve instead -> 379 slots
strata generate: only 0 MiB free once the slots are written (reserve 484 MiB); shrinking...
strata serve: verify: needs the profile-filled VRAM expert tier (--expert-profile and
              --expert-cache); with --expert-cache auto, no VRAM was left for it
```

这段文字里没有任何一句说"有另一个进程正在占用 GPU"。它读起来像是配置写坏了，或者构建有问题。
**而真正的原因是：一个 9B 的 `llama-server` 占着 10.8 GB。**

在本机实测：

```
before stopping the 9B : D3D dedicated memory used = 10846 MB  (free  1397 MB)
after  stopping the 9B : D3D dedicated memory used =   251 MB  (free 11992 MB)
```

**去调试引擎之前，先核对 VRAM 的账。** `vulkaninfo --summary`、另一边的 `nvidia-smi`，
或者硬件监控软件里的 GPU 显存计数器，哪个都够用。

## 5. 不跟你对着干的自启动

如果你希望每次开机之后模型都在 —— 包括意外断电之后 —— 就把启动脚本做成**幂等**的，并且
**隐藏启动、不闪控制台窗口**：

```powershell
# start <model>.ps1
if (Get-NetTCPConnection -State Listen -LocalPort 8085 -ErrorAction SilentlyContinue) {
    exit 0                      # already serving - do not start a second copy
}
Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $dir `
    -WindowStyle Hidden -RedirectStandardOutput <log> -RedirectStandardError <err>
```

再从启动文件夹里通过一个很小的 VBS 去拉起这个脚本，这样窗口从一开始就是以隐藏方式创建的：

```vbs
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File <path>\start.ps1", 0, False
```

**不要**反过来把 `-WindowStyle Hidden` 放进这条链条里：那样会先创建一个可见的控制台，然后再
把它隐藏，正好就是你想要避免的那一下闪窗。窗口样式应该放在 `WshShell.Run` 里。

同时还有两件事值得做：**关掉其他 LLM 服务的自启动**（这里有个开机触发的 Ollama 服务在悄悄
回来抢显卡），以及**确认你删掉的那条启动项没有被某个计划任务重新匹配上** —— 我们这台就是
这样，每次开机它都回来了。

## 6. 真正起作用的调优要点

* **MTP 投机解码**（`--spec-type draft-mtp --spec-draft-n-max 4`）—— 用模型自带的多 token
  预测头作为 draft。只要 GGUF 里有它，就是白拿的速度。
* **量化 KV cache**（`q8_0`）是让 12 GB 上跑得起 64K 上下文的关键。不用它，64K 和视觉没法
  同时装下。
* **`--fit on` / `-fa auto`** 让构建自己挑合理的取值，而不用手工调。
* **`--parallel 1`** 对单用户来说：多余的 slot 只会复制 KV cache，没有任何收益。
* 把模型放在快盘上 —— 首次加载要读约 8 GB。

## 7. 诚实的边界

* 上面那套 9B 配置在这块卡上是**实测过的，并且日常在用**。
* 27B-at-IQ2 那一行是**从算术推出来的预期，不是实测** —— 把它当成"值得一试"，不要当成事实。
* §3 里的 VRAM 拆分是把实测总量与已知组件大小对账的结果；其中单行都是近似值。
* tokens/s 吞吐量**有意不写**：它取决于模型、量化、上下文长度和 prompt，脱离这些条件给出的
  单一数字只会误导人。要测就自己测，用固定的 prompt 和已经预热好的模型。
