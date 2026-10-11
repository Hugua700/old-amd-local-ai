> [English](COMFYUI-GFX1031.md) | [中文](COMFYUI-GFX1031.zh.md)

# ComfyUI 在 gfx1031 显卡上：能跑什么，代价是多少瓦

主 README 的姊妹篇，同一台机器：**RX 6800M（gfx1031，RDNA2 移动版，12272 MB 显存）**，
240 W 电源适配器，Windows 11。简版结论：**在这张卡上生成是能跑的，但真正的硬约束是功耗，
不是显存。**

下面每个数字都是在这台机器上用 2 s 间隔的日志器测出来的（CPU package 功耗、GPU 功耗、
CPU 温度、GPU 核心与热点温度），并与工作负载自身的计时做了交叉核对。

---

## 1. 用哪个整合包，比用哪张卡更重要

在老旧 AMD 卡上，原版 ComfyUI 安装并不是你想要的。这里跑的是：

```
E:\AI_work_v5\ComfyUI          python_embeded + 31 custom_nodes -> 2351 nodes
(compare: a stock Comfy-Desktop install -> 1075 nodes, 13 custom_nodes)

AMD/ROCm-specific nodes in it:
  XB-SageAttn   attention tuned for ROCm on gfx1031
  XB-llama      llama.cpp integration built for ROCm
  JZL-llama     the same, alternate build
  + SeedVR2 optimisations
```

这个差别不是表面功夫：在 RDNA2 上，正是 ROCm 的 attention 路径决定了"这个工作流能跑"
还是"这个工作流能以可用的速度跑"。

**启动：** 每个端口配一个启动器 `.bat` 就够了。这台机器保留了两个：
`AutoLaunch_ComfyUI.bat`（8188）和 8194 上的第二套 profile，这样两套配置可以并排运行，
不必争抢模型缓存。

**模型路径：** 与其为每个安装各复制一份几 GB 的 checkpoint，不如把另一个安装的目录树加进
`extra_model_paths.yaml`。只加一条条目，这个整合包就拿到了磁盘上别处已有的整个
z-image / LTXV 家族。

## 2. 这里实际能跑什么

| 任务 | 模型 | 说明 |
|---|---|---|
| 图像生成 | Z-Image Turbo (bf16) + Qwen-3 4B text encoder + `ae` VAE | 1024x768, 8 steps, cfg 1.0, euler/simple |
| 图像生成 | Qwen-Image 2.1 int8 | 更重，但装得下 |
| 文本条件视频 | LTXV | 下面的功耗测量用的是 512x320x25 帧 |
| 放大 / 修复 | SeedVR2 | 整合包自带为它调优的节点 |
| 图像理解 | `strata-vision`（Vulkan，llama.cpp mtmd） | 固定在 iGPU 上——见 §4 |

## 3. 功耗账单（没人会提醒你的那部分）

同一台机器，同类工作负载，不同设置。全部为峰值，2 s 采样：

```
image generation          226 - 244 W
video generation          ---
   on the Performance/Turbo profile      up to 323 W
   on Silent                             ~227 W
   with a 45 W SMU power wall            ~125 W     (see §4 - not a path we kept)
local LLM inference       89 W (with a 45 W wall)  /  145 W (no wall)
```

**关键背景：** 适配器是 **240 W**，而这台机器在峰值超出它时会**硬切电**——不是关机，也不是
bugcheck。事件日志特征见主 README §5。所以在一台轻薄的笔记本上，323 W 的峰值不是"有点热"，
而是**一个等着合适时机发作的崩溃**。

**散热现实核查：** 这些运行期间 GPU 热点达到 **101-108 C**。这台机器的 ACPI thermal zone
报告 `_PSV = 0K` 和 `_AC0.._AC9 = 0K`，也就是说**Windows 在这里从不会因温度而降频或关机**——
唯一的限制器是固件/EC 直接切电。GPU 风扇传感器在**每一次采样中都读到 0**；这究竟是真实的风扇
故障，还是不支持的传感器，在这台机器上仍然没有定论。

## 4. 四个杠杆，按实际帮助大小排序

**1. 把 Vulkan 图像编码器固定到集成显卡。（-122 W，几乎零成本）**
在双 GPU 笔记本上，编码器选哪个设备会让整机峰值移动约 120 W，而编码本身无论选哪种都只占
请求里约 2 s：

```
encoder on RX 6800M : peak 313 W
encoder on iGPU     : peak 191 W
```

在配置里固定它，而不是用一层包装脚本——配置的 `env` 块能作用到编码器：

```json
"env": { "GGML_VK_VISIBLE_DEVICES": "0" }
```

先自己确认索引；不要假设 `0` 就是 iGPU（在这台机器上它是，通过 `vulkaninfo --summary`
和 `llama-server --list-devices` 确认，但这是因机器而异的）。

**2. 用安静的风扇 profile。（视频上 -96 W）**
在视频工作负载上，Silent profile 把峰值从 **323 W 降到约 227 W**。我们第一次测量结论是
"Silent 帮助不大（191 -> 186 W）"——那是在*错误的工作负载*（一个 LLM）上测的，就是错的。
按工作负载重新测。

**3. 限制 CPU。（图像 CPU 峰值 124 -> 98 W）**
`PROCTHROTTLEMAX 80% -> 75%` 把图像生成期间的 CPU 峰值降了约 26 W。

但真正的速度杠杆其实是另一个设置：**`PROCTHROTTLEMIN`**。
在这台机器上，同一任务：

```
MIN 20%   -> 83.2 s
MIN 50%   -> 25.6 s      <- sweet spot
MIN 100%  -> 26.7 s
```

过低的*最低*处理器状态才是真正的瓶颈。四个电源方案都要设置，并且在厂商工具（这里是
Armoury Crate）切换方案之后重新检查——它可能把这些设置覆盖掉。

**4. 我们试过又放弃的：45 W SMU 功耗墙。**
它是单个杠杆里效果最明显的（CPU 191 -> 53 W，精确钉在 45.0 W），而且需要 `ryzenadj`
加上一个内核级驱动。**这个驱动触发了 Windows Defender 的易受攻击驱动检测，已被移除。**
我们不推荐这条路；如果你想要功耗墙，优先用固件/BIOS 或厂商支持的工具。

## 5. 两个会让你判断失误的基准测试陷阱

**陷阱 1 —— 执行缓存。** 如果工作流、参数*以及随机种子*都没变，ComfyUI 会愉快地对每个节点
返回 `execution_cached`，几秒内就结束。一个 26 W 的"5.1 s 图像测试"不是结果，是缓存命中。
**每次运行之间都要改一个上游参数或提示词**，然后确认队列确实执行了、输出文件的时间戳动了。

**陷阱 2 —— `POST /free`。** 用 `{"unload_models": true, "free_memory": true}` 调用它，
然后再跑工作流，会**把这个实例硬挂住**；`/interrupt` 和清空队列都救不回来，只有重启实例才行。
如果你为了测量需要冷加载，重启实例，别调 `/free`。

## 6. 什么时候这张卡根本不该用来跑

我们做过的最有用的架构决策：**这台机器不生成图像。** 它跑本地 LLM；同一 tailnet 上的
第二台机器跑 ComfyUI 做图像和视频，由这台 AMD 机器通过 HTTP 驱动：

```
POST /prompt            -> prompt_id
GET  /history/<id>      -> outputs
GET  /view?filename=... -> the image
```

当你的 AMD 机器功耗余量本就紧张时，这么做是值得的：生成恰恰是那种会把它推过适配器上限的
工作负载。先测量你自己的余量——如果图像生成峰值超过适配器的额定值，第二台机器就不是奢侈品，
而是解决方案。

## 7. 诚实的边界

* 在 gfx1031 上配合 ROCm 调优的整合包，**图像和视频生成都能跑**，前提是不超过上面的功耗限制。
* 我们**没有**把这张卡和上游 ComfyUI 发布中最新的 attention/kernel 路径做过验证；重活是调优节点包在干。
* `45 W 墙`的结果是真的，但方法已被我们移除。把这个数字当作良好功耗管理可能带来的上界，而不是配方。
* 风扇传感器读 0 这件事仍未解决。如果你的卡也一样，先物理检查风道，再相信别的结论。
