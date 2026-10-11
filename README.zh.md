> [English](README.md) | [中文](README.zh.md)

# 老 AMD Radeon 上的本地 LLM 与扩散模型——实测、可复现的笔记

> 配套文档：
> * **[gfx1031 显卡上的 ComfyUI：能跑什么，代价是多少瓦](COMFYUI-GFX1031.md)**
> * **[gfx1031 显卡上的本地 LLM：配置、VRAM 预算，以及那个看起来像 bug 的故障](LLM-GFX1031.md)**
> * **[两台机器，一件事](TWO-MACHINE-SPLIT.md)**（附可直接运行的客户端 comfy_remote.py）

来自一台生态圈并不正式支持的机器的现场笔记：
**AMD Radeon RX 6800M、`gfx1031`、RDNA2 移动版、Windows 11**，一个 240 W 电源适配器。

大多数本地 AI 工具链都冲着 CUDA 去。在支持 AMD 的地方，官方发布的二进制通常
只覆盖维护者自己手上的卡——`gfx1100/1101/1102/1200/1201`，偶尔有 `gfx1030`。
`gfx1031` 经常被漏掉，于是一块笔记本 GPU 最后连一个现成的引擎都没有。这些笔记记录的
就是让那台机器变得有用所付出的代价，数字都是实测的，不是假设的。

下面所有内容都在这一块卡上跑过。数字来自单机、2 s 间隔的日志记录器，取中位数或峰值，
每一个都会说明是怎么测出来的。

---

## 1. gfx1031 上究竟什么能跑

| 任务 | 技术栈 | 结果 |
|---|---|---|
| 本地 LLM 对话/视觉 | `llama.cpp` 的 **Vulkan** 构建（`llama-server`） | 9B Q6_K + BF16 mmproj，64K 上下文，MTP 投机解码——完全放进 12 GB VRAM |
| 大 MoE 推理 | **Strata** HIP 引擎，**为 gfx1031 自行构建** | 官方引擎拒绝的地方它能跑："your GPU is gfx1031" |
| 图像理解 | `strata-vision`，**Vulkan**，固定到 **iGPU** | 在 768x512 测试图上结果正确 |
| 图像/视频生成 | 第二台机器（RTX 5070 笔记本）上的 ComfyUI，通过局域网驱动 | 让 AMD 这台机器空出来专门跑 LLM |

有两个事实值得直说，因为弄明白它们花的时间最多：

* **为 gfx1031 构建并不需要一块 AMD GPU。** Strata 引擎的构建是交叉编译：ROCm 的 clang
  编译设备代码，MSVC 提供头文件和链接器。我们在一台**只有 NVIDIA 的 Windows 机器**上
  构建出了 gfx1031 引擎，它在 AMD 卡上服务正常。
* **官方发布的 AMD 引擎漏掉了 `gfx1031`，尽管构建脚本默认的 `STRATA_HIP_ARCHS`
  列表里就有它。** 我们自己用 `-Archs gfx1031` 构建，花了约 4 分钟，产出一个 126 MB 的
  zip（里面有 `blas_lib_gfx1031.kpack`），服务正常。
  这个不对称已经反馈给上游。

## 2. 挡住一切的那个构建陷阱（Windows、MSVC）

在 Windows 上构建 **Vulkan** 图像编码器会失败，报错是

```
Could not find a package configuration file provided by "SPIRV-Headers"
```

**即使设置了 `VULKAN_SDK` 也一样**，因为较老的 Vulkan SDK（这里是 1.4.304）把
`SPIRV-HeadersConfig.cmake` 直接放在 `Lib\cmake\` 下，而不是放在 `SPIRV-Headers\`
子目录里，CMake 的前缀搜索匹配不到。修法：

```bat
cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DSPIRV-Headers_DIR="%VULKAN_SDK%\Lib\cmake"
```

（更新的 SDK，比如 1.4.350，确实有那个子目录，只靠 `VULKAN_SDK` 就能找到。
两种情况现在都已写进上游文档。）

只有 VS-2026 的机器上还有第二个陷阱：`find_vcvars()` 把 CUDA 的
`[16.0,18.0)` 版本范围套用到了*每一个*调用方，于是一台 C++ 工具链只有
Visual Studio 2026（版本 18）的机器拿到的是 `None`，根本没法构建编码器。
已在上游修复：非 CUDA 的调用方现在向 `vswhere` 请求时不带版本范围，
而且可以用 `STRATA_VCVARS` 手动指向一个 `vcvars64.bat`。

## 3. 双 GPU 笔记本上，编码器选哪块卡要花约 120 W

这台机器暴露两个 Vulkan 设备：

```
GPU0 = AMD Radeon(TM) Graphics   PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU   (Cezanne iGPU)
GPU1 = AMD Radeon RX 6800M       PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
```

编码器遵循 `GGML_VK_VISIBLE_DEVICES`。同一个请求用两种走法都测过，
用 LibreHardwareMonitor 每 2 s 采样 CPU 封装功耗和 GPU 功耗：

| 编码器所用设备 | 整机峰值 | 图像编码 | 答案 |
|---|---|---|---|
| RX 6800M（dGPU） | **313 W** | ~2 s | 精确 |
| Cezanne iGPU | **191 W** | ~2 s | 精确 |

**两种走法下编码本身都只占这次请求约 2 s**，所以把它固定到集成 GPU 能消掉一个约 120 W
的尖峰，而速度上什么也没换来。这台机器的适配器是 240 W，所以这个尖峰不是学术问题。

值得知道的是：当 `GGML_VK_VISIBLE_DEVICES` 未设置时，`clip.cpp` 会优先选独显，
只有在没有独显时才回落到集显——所以这里*默认*就是 313 W 那种情况。要显式固定：

```json
"env": { "GGML_VK_VISIBLE_DEVICES": "0" }
```

## 4. 12 GB 卡上的本地 LLM 规模测算（实测，不是猜的）

`llama.cpp` Vulkan 构建，9B Q6_K，BF16 mmproj，64K 上下文，`q8_0` KV cache，
int8 KV，启用 MTP 投机解码：

```
:8085 ready ~5 s after start, model fully resident
VRAM: 10846 MB used of 12243 MB  (1397 MB free)
idle: ~20 W total, GPU hot spot 46 C
```

实际教训：**在 12 GB 卡上，一个带视觉的 9B 加上 64K KV cache 就没给别的任何东西留空间了。**
在它旁边再跑一个 LLM 服务（Ollama、LM Studio）要么加载失败，要么被迫驱逐。
第二个大模型——比如一个 125B MoE 引擎——在 9B 停掉之前根本起不来；这个失败看起来像
引擎 bug（`no VRAM was left`），但纯粹是资源冲突。

## 5. 240 W 轻薄本上的功耗与散热（真正咬人的那部分）

这台机器在负载下**硬断电**——不关机、不蓝屏、也没有 `Kernel-Power 41`：

```
next boot: 6008 "The previous system shutdown at <time> was unexpected"
```

实测事实（全部来自那个 2 s 记录器，并与事件日志交叉核对）：

* 断电发生在**空闲（34 W，56 C）**、**轻载（55 W，66 C）**以及
  **持续负载（214-246 W，GPU 热点 91-101 C）**。**没有任何功耗或温度阈值能解释全部这些情况。**
* 断电之后机器**会自己重新开机**——观察到的断电时长：
  **9.0 / 18.8 / 22.7 / 50.4 分钟**，而且它们**与温度或负载都不相关**。一台冷机器用了 22.7 分钟；
  一台热机器用了 18.8。
* 在这台机器上操作系统从不做温度降频：`ACPI _TZ.TZ01` 报告 `_PSV = 0K`，
  `_AC0.._AC9 = 0K`。断电是固件/EC 层面的，而且静默。
* **GPU 风扇传感器在每一个采样里都读 0，一整天都是。**这到底是真的风扇故障
  还是传感器不受支持，尚未有结论；物理检查出风气流是下一步最省事的做法。

**给用类似机器的人的结论：软件没法让它变安全。**记录你设备的行为，能不在本机干的活
就别在本机干，并把供电链路（电池、BMS、VRM、EC）当作嫌疑对象。

## 6. 一套能扛住不可靠机器的架构

同一个 tailnet 上的两台 Windows 机器：

* **A 机（AMD 那台，供电不可靠）：**只跑本地 LLM——`:8085` 上的 `llama-server`，
  注册为登录时启动，幂等（端口已被占用时跳过）。
* **B 机（NVIDIA）：**ComfyUI，由 A 机通过 `POST /prompt` + `GET /history/<id>` 驱动。
  图像和视频生成永远不碰 A 机的 VRAM。

然后，因为 A 机随时可能消失：

* **所有要紧的东西都放在一个 git 仓库里并推送出去**——笔记、脚本、配置。
* **另推一份副本到第三台机器**——按主题各打一个 zip，绝不用散文件：在 31 ms RTT 的
  链路上，一个 126 MB 的文件跑到 **5.3 MB/s**，而 1183 个小文件总共 11.6 MB 却只有
  **0.026 MB/s**。**先打包，再拷贝。**
* **直连胜过中继。**同样两台机器，直连时是 3.3-5.3 MB/s，经过一个中间主机走中继路径时
  只有 **0.05 MB/s**。

## 7. 值得反复讲的坑（每个都花掉好几个小时）

1. **`$ErrorActionPreference = 'Stop'` 加上原生命令行工具就是地雷。** `git`、`cmake` 之类
   会把正常的进度写到 stderr；PowerShell 把它变成终止性错误，于是脚本会在*一条成功的命令之后*
   死掉，而且完全没有输出——从计划任务里跑的时候根本看不见。用 `Continue`，然后检查 `$LASTEXITCODE`。
2. **函数名会和别名撞车。** `R` 是 `Invoke-History`；别名优先于函数，所以一个叫 `R` 的
   辅助函数静悄悄地变成了「打印历史」。
3. **PowerShell -> ssh -> cmd 之间嵌套引号会在空格处把参数切开。**把命令写进一个
   `.cmd` 或 `.ps1`，把文件拷过去，然后用一条简单命令运行它。
4. **绝不要 `taskkill /T` 你自己启动的进程**——如果它在你自己的作业树里，你会连整棵树一起带走。
5. **只要有文件被占用，`Compress-Archive` 就会整体失败**（正在写的日志、模型服务的
   stderr）。先用 `FileShare.ReadWrite` 拷一份，再打包。
6. **`Get-ChildItem -Include` 在没有 `-Recurse` 或 `\*` 路径时什么都返回不了**——静默地返回。
7. **用外部证据验证，而不是你自己的回显。**匹配到你自己发出去的哨兵值什么也证明不了；
   要用退出码和远端生成的值。
8. **绝不用一次失败的传输去算速率。**在引用任何数字之前，要求退出码为 0 *并且*字节数吻合。

## 8. 哪些已经到上游了，哪些还悬着

已上报并合入/致谢于上游：

* 不带 CUDA 的 `find_vcvars()` 向 `vswhere` 请求时不带版本范围，外加 `STRATA_VCVARS`
  （在 v0.1.42）。
* 老版本 Windows Vulkan SDK 上的 `SPIRV-Headers_DIR`，以及双 GPU 功耗测量
  （两者都在 `docs/AMD_HIP.md`）。

悬着的：官方引擎矩阵是否会纳入 `gfx1031`，好让 RX 6700 XT / 6800M 的用户不再需要
为一块构建脚本默认就已经瞄准的卡自行构建。

---

*如果你用的是一块老 AMD 卡，而这里的任何内容帮你省下一个下午，那正是把它写下来的意义。
欢迎指正和反测——上面有好几个数字第一次都是错的，是靠重新测量才修好的。*
