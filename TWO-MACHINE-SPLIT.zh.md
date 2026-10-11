> [English](TWO-MACHINE-SPLIT.md) | [中文](TWO-MACHINE-SPLIT.zh.md)

# 两台机器，一份活：老 AMD 卡负责 LLM，生成放到别处

主 README 的第四篇配套文档。思路很简单，而且它解决了这套配置上最大的实际难题：**老 AMD 笔记本当
LLM 主机很称职，当图像/视频主机就非常勉强。** 与其反复调参、硬把生成塞进这台机器，不如把生成放到
另一台机器上，通过网络远程驱动。

这并不只适合有两台机器的人 —— 对于任何显卡在功耗或散热上处于边缘的人来说，这都是理性的答案；而在
RDNA2 移动平台上，大多数卡都属于这种情况。

---

## 1. 为什么要拆分

三股压力指向同一个方向：

* **显存。** 一个带视觉的 9B 模型加 64K 上下文，已经用掉 12 GB 中的约 10.8 GB（见
  `LLM-GFX1031.md`）。扩散模型想要的是同一块内存。
* **功耗。** 在这台机器上，图像生成峰值达到 **226-244 W**，视频最高到 **323 W**，而适配器只有
  **240 W**，超过就会被硬切断。LLM 推理便宜得多：89-145 W。
* **波及范围。** 把机器搞崩的负载是生成。如果它跑在别处，LLM 主机就能一直在线。

## 2. 分工

```
Box A  (AMD, gfx1031, power-marginal)      Box B  (any GPU with a working ComfyUI)
  llama-server            :8085               ComfyUI              :8190
  LLM + vision, resident                       image / video / upscale
        |                                            ^
        +------------- HTTP over the LAN ------------+
                    POST /prompt -> poll /history -> GET /view
```

两台机器在同一个 tailnet（或局域网）里。Box A 从不加载扩散模型。

## 3. Box B 需要暴露什么

ComfyUI 的 HTTP API 足够小、也足够稳定，可以用脚本驱动：

| 端点 | 用途 |
|---|---|
| `POST /prompt` | 提交 `{"prompt": <api-format workflow>}` -> 返回 `prompt_id` |
| `GET /history/<prompt_id>` | 轮询直到这次运行出现；输出在 `outputs` 里 |
| `GET /view?filename=..&subfolder=..&type=output` | 取回产出的文件 |
| `GET /queue` | 运行中/排队中的数量，方便你等一个空闲时机 |
| `GET /system_stats` | 设备名、显存总量/剩余 |
| `POST /upload/image` | **见 §6 的安全说明** |

让它监听网络（`--listen 0.0.0.0 --port 8190`）—— 但在这么做之前先读 §6。

## 4. 一个真正能用的客户端

本仓库里的 `comfy_remote.py`，就是这里实际运行版本的精简版。它在代码里构造 API 格式的工作流，
提交、轮询，然后把图像写出来。核心结构如下：

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

几条让我们花掉过时间的注意事项：

* **这些是 API 格式的节点图，不是 UI 工作流 JSON。** UI 格式带 `nodes`/`links` 数组，会被拒绝。
* **文件落盘靠的是 `SaveImage`**；没有它，用 `/view` 什么也取不到。
* **每次运行之间要改 seed（或任何上游参数）。** 否则 ComfyUI 会对每个节点返回
  `execution_cached`，这次"运行"几秒钟就结束，实际上什么都没算 —— 这是做基准测试时最常见的
  一种自欺方式（见 `COMFYUI-GFX1031.md` §5）。

## 5. 墙钟时间上要花多少（在远端机器上实测）

```
1024x768, 8 steps, cfg 1.0 : 20.4 s engine time   /   95.4 s wall including model load
 768x768                   : 45.3 s
```

墙钟时间和引擎时间之间的差距，来自模型加载和排队 —— 这正是 LLM 主机不该同时充当生成主机的原因：
它会去争抢同一块磁盘和同一块 GPU。

## 6. 关于安全，说实话

**一个绑定在 `0.0.0.0` 且没有认证的 ComfyUI，就是你网络上的一个开放端点。** 任何能访问到这个端口
的人，都可以提交任意工作流（也就是让你的机器去算东西、写文件），并且可以读取输出目录。

我们撞上过一个具体的例子：**`POST /upload/image` 接受任意文件**，并把它写进 ComfyUI 的 `input/`
目录。这确实很方便 —— 在这套配置里，脚本就是这样被送到远端机器上的 —— 但它同时也是**一个无需
认证的文件投放口**，就在 tailnet 上，对任何能访问该端口的设备开放。这两句话都成立；请自行权衡。

实用的缓解措施，按成本从低到高：

1. **不要把它暴露到公网。** 只用 tailnet/局域网。
2. **在防火墙上限制该端口**，只放行应当访问它的那些对端（在 Windows 上，就是一条限定到 tailnet
   子网或具体地址的防火墙规则）。
3. **只绑定单个网卡接口**（`--listen <tailnet-ip>`），在驱动允许的情况下不要用 `0.0.0.0`。
4. **在前面加一个带认证的反向代理**，如果需要的机器不止两三台的话。

我们是故意让它在 tailnet 上保持可达的，因为收紧限制会弄坏一条已经在跑的流水线 —— 但这是一个决定，
不是疏忽，写在这里就是为了让它始终是一个决定。

## 7. 诚实的边界

* 上面的端点和 workflow 结构是**这套配置实际在用的**；ComfyUI 的 API 并没有正式版本化，所以在
  一次大版本升级之后要重新核对 `/object_info`。
* 时间数据来自一台机器（RTX 5070 Laptop），换到任何别的地方都会有差异。
* 双机拆分只是把*生成*负载从 AMD 机器上移走。它**并不能**修复硬件层面的供电故障 —— 如果你的机器
  因为硬件原因在负载下断电，那仍然需要去修。它只是让你不再故意去触发它。
