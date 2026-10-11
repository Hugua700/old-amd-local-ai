# Seeking repair advice: a laptop that cuts its own power and then powers itself back on — no OS shutdown event, no thermal-throttle path, no power threshold

**This is a request for hypotheses, not a bug report against any software.** The machine's power
behaviour is documented in the README (§5); this issue is the full case file, because the pattern does
not match anything we have been able to find described elsewhere.

---

## The machine

| | |
|---|---|
| Model | ASUS ROG laptop (Ryzen 9 5900HX + Radeon RX 6800M, `gfx1031`, RDNA2 mobile) |
| RAM / OS | 31.4 GB · Windows 11, build 26300 |
| Adapter | **240 W** |
| Battery | 69,530 / 90,005 mWh design (**77.3 %**), cycle count **0-7** (calendar-aged, not cycled) |
| Repair history | **The EC was replaced around 2026-09-03.** The cut rate got noticeably **worse** afterwards — see below. |

## The symptom

The machine **loses power instantly**, with **no shutdown sequence of any kind**, and then **powers
itself back on** after a delay of minutes. It is not a crash, not a thermal shutdown, and not a
user action.

## Evidence 1 — what the OS event log does *not* contain

At the next boot, exactly one relevant event appears:

```
6008  "The previous system shutdown at 1:24:21 on 2026/10/11 was unexpected."
```

**Absent, in every case:**

```
6006  (clean shutdown)                    - not present
1074  (a process requested shutdown)      - not present
109   (kernel initiated shutdown)         - not present in most cases (see below)
Kernel-Power 41 (unexpected power loss)   - ZERO in the whole recent window
```

So nothing in the OS asked for this, and the usual "unexpected power loss" marker is missing too.
`6008` is written at the *next boot* and its **message body** carries the real time of the loss —
the timestamp of the event itself is the reboot, not the cut.

## Evidence 2 — there is no power threshold

2 s-interval logging of CPU package power, GPU power, CPU temperature, GPU core and hot-spot
temperature. Peak in the 5 minutes before each cut:

| cut time | machine peak before the cut | CPU temp | GPU hot spot | outage length |
|---|---|---|---|---|
| 09:43:12 | (no data) | - | - | **50.4 min** |
| 19:31:26 | **34 W** | 56.6 C | 56.0 C | **22.7 min** |
| 21:59:10 | **55 W** | 70.3 C | 66.0 C | **9.0 min** |
| 01:24:21 | **244 W** | 79.0 C | 101.0 C | **18.8 min** |

**It cut while idle (34 W, 56 C).** And the outage length does **not** track temperature or load at
all — a cold machine took 22.7 minutes to return, a hot one 18.8.

(For scale: the machine peaks at **313 W** on some workloads, against a 240 W adapter. But the idle
cut is the datum that rules out a simple power-budget explanation.)

## Evidence 3 — the OS has no thermal path at all

```
ACPI _TZ.TZ01 reports:   _PSV = 0K    and   _AC0 .. _AC9 = 0K
```

So Windows never thermally throttles and never initiates a thermal shutdown on this box. **Any
thermal protection that acts here is firmware/EC level and silent.**

## Evidence 4 — the behaviour changed when the EC was replaced

* The cut rate became roughly **3.7x more frequent** after the ~2026-09-03 EC replacement.
* **The event signature changed too**: historically the log showed a mix of `6008` **and**
  `Kernel-Power 41` events. **After the replacement, `41` stopped appearing entirely** and only
  `6008` remains. (About 10 `41` events existed before, all before 2026-09-14; zero since.)

That correlation is the single strongest clue we have, and it is why this is written up as a hardware
question rather than a software one.

## Evidence 5 — the fan sensor never moves

A hardware monitor reads the **GPU fan at 0 rpm in every single sample**, all day, under every load.
Whether that is a genuinely stopped fan or an unsupported sensor read is unresolved. (The GPU hot
spot does reach 101-108 C, and the machine is a thin chassis.)

## What we have already ruled out (as far as we can)

* **Thermal shutdown by the OS** — no `_PSV`/`_AC*` trip points exist (Evidence 3).
* **A simple power ceiling** — it cut at idle 34 W (Evidence 2).
* **Thermal hysteresis / "cut hot, return when cool"** — outage length is uncorrelated with
  temperature (Evidence 2).
* **A software or user shutdown** — no 6006 / 1074 (Evidence 1).
* **A classic crash** — no bugcheck, no Kernel-Power 41 in the recent window.
* **Battery capacity** — 77.3 % of design, with 0-7 cycles; degradation is calendar-based.

## What we would like to ask

1. **Has anyone seen a laptop that self-cuts and then auto-powers-on, with `6008` as the only trace
   and no Kernel-Power `41`?** What did it turn out to be?
2. **Is the `41` → `6008`-only shift meaningful?** Does the disappearance of `Kernel-Power 41` after an
   EC replacement point at a specific class of fault (e.g. the EC now cutting a rail in a way that
   leaves no crash-dump path), or is it just a logging artefact?
3. **EC firmware / BIOS matching**: what should be verified after an EC replacement on an ASUS ROG
   board — is there a documented requirement that the EC firmware and BIOS be flashed as a matched
   pair, and what happens if they are mismatched?
4. **Battery BMS tripping**: can a BMS trip and self-reset produce exactly this signature (instant cut,
   no OS event, automatic return after minutes, variable delay)? What would distinguish a BMS trip
   from an EC protection cut with a multimeter / vendor diagnostic?
5. **VRM / mainboard** — is a transient VRM fault consistent with cutting at **idle**, or does that
   point away from the VRM?
6. **Is there a datapoint in the fan staying at 0 rpm?** Could a genuinely stopped GPU fan cause a
   silent firmware-level cut, and would we expect that at idle too?

## What we have done in the meantime

* Documented everything, with raw 2 s-interval logs kept (`REPRODUCTION.md` describes the method).
* Moved all long-running workloads off this machine, so we stop deliberately provoking it
  (see `TWO-MACHINE-SPLIT.md`).
* Stopped using any tool that needs a kernel-level driver to set power limits — one such tool
  tripped Windows Defender's vulnerable-driver detection and was removed. We are not pursuing that
  direction.

**Any hypothesis, however speculative, is welcome — especially a way to distinguish an EC cut from a
BMS cut from a VRAM fault with tools that do not require a kernel driver.**

---

# 中文版

## 求助：一台会"自己断电、又自己开机"的笔记本 —— 无系统关机事件、无热降频通路、无功率阈值

**这是在求假设，不是在报某个软件的 bug。** 这台机器的电源行为已写进 README §5；这里给出完整案卷，因为**我们找不到任何与此模式相符的公开描述**。

### 机器

ASUS ROG 笔记本（R9 5900HX + RX 6800M / `gfx1031` / RDNA2 移动版）· 31.4 GB · Windows 11 build 26300 ·
**适配器 240 W** · 电池 **77.3 %**（69530/90005 mWh，循环 **0–7** 次，属日历老化）·
**EC 于 2026-09-03 前后更换过** —— 切电频率约恶化 **3.7 倍**。

### 症状

**瞬间掉电**，**没有任何关机流程**，然后在**数分钟后自己开机**。既不是崩溃，也不是热关机，更不是人操作。

### 证据一：事件日志里"没有什么"

下次开机只出现一条：
```
6008  "The previous system shutdown at 1:24:21 on 2026/10/11 was unexpected."
```
**每次都缺**：`6006`（正常关机）· `1074`（有程序请求关机）· `109`（内核发起关机，多数情况）· **`Kernel-Power 41`（整个近期窗口为 0 次）**。
⇒ 系统里没有任何东西要求关机，连"非正常掉电"那个惯常标记都没有。
**注意**：`6008` 写在【下次开机】时，**真正的掉电时刻要看它的正文**。

### 证据二：不存在功率阈值

2 秒间隔记录 CPU 包功耗、GPU 功耗、CPU 温度、GPU 核心与热点温度，取每次切电前 5 分钟的峰值：

| 切电时刻 | 切前整机峰值 | CPU 温 | GPU 热点 | 断电时长 |
|---|---|---|---|---|
| 09:43:12 | （无数据） | — | — | **50.4 分** |
| 19:31:26 | **34 W** | 56.6 °C | 56.0 °C | **22.7 分** |
| 21:59:10 | **55 W** | 70.3 °C | 66.0 °C | **9.0 分** |
| 01:24:21 | **244 W** | 79.0 °C | 101.0 °C | **18.8 分** |

**它会在空闲（34 W / 56 °C）时切电** ⇒ 这一条就否掉了"简单功率预算"的解释。
**而且断电时长与温度、负载都不相关** —— 冷机反而用了 22.7 分钟才回来，热机只要 18.8 分钟。

### 证据三：系统层根本没有热保护通路

```
ACPI _TZ.TZ01:  _PSV = 0K      _AC0 .. _AC9 = 0K
```
⇒ **Windows 在这台机器上从不热降频、也不会发起热关机** —— 任何在此生效的热保护都是**固件/EC 层且无声的**。

### 证据四：换 EC 之后行为变了（我们手上最强的一条线索）

- 切电频率约恶化 **3.7 倍**；
- **事件签名也变了**：历史上是 `6008` **与** `Kernel-Power 41` 混合出现；**换 EC 之后 `41` 完全消失**，只剩 `6008`（此前约 10 次 `41`，全在 2026-09-14 之前；此后为 0）。

### 证据五：风扇传感器从不变化

硬件监视器读到的 **GPU 风扇转速在所有样本里恒为 0**，全天、各种负载下都是 0。
到底是风扇真停转，还是传感器不支持读取 —— **未定**。（GPU 热点确实到过 101–108 °C，且是薄机身。）

### 我们已尽力排除的

OS 热关机（无 `_PSV`/`_AC*` 触发点）· 简单功率上限（空闲 34 W 也切）· 热滞后/"热了切凉了回"（时长与温度无关）·
软件或人为关机（无 6006/1074）· 经典崩溃（无 bugcheck、无 41）· 电池容量（77.3 %，循环 0–7）。

### 想请教的问题

1. **有人见过"自切 + 自动开机，只留 `6008`、没有 Kernel-Power 41"的机器吗？最后查出是什么？**
2. **`41` → 只剩 `6008` 这个转变有意义吗？** 换 EC 后 `41` 消失，是否指向某类特定故障（例如 EC 现在以不留崩溃转储路径的方式切某条供电轨），还是纯粹的日志行为差异？
3. **EC 固件与 BIOS 的匹配**：ASUS ROG 主板换 EC 之后应当核对什么？是否存在"EC 固件与 BIOS 必须成对刷写"的硬性要求？不匹配会表现成什么？
4. **电池 BMS 跳闸后自复位**，能否产生完全相同的签名（瞬间切断、无系统事件、数分钟后自动恢复、延迟可变）？用万用表或厂商诊断工具，**怎样区分 BMS 跳闸与 EC 保护性切断**？
5. **VRM / 主板**：瞬时 VRM 故障与"**空闲时也切**"相符吗，还是这一条反而把 VRM 排除了？
6. **风扇恒为 0 这条有参考价值吗？** 风扇真停转能否导致固件层的无声切断？若是，空闲时也会切吗？

### 我们同时已经做的

把所有长任务搬离这台机器（不再主动去触发它，见 `TWO-MACHINE-SPLIT.md`）；完整记录并保留原始 2 秒间隔日志（复现方法见 `REPRODUCTION.md`）；**停用一切需要内核级驱动去设功耗上限的工具** —— 其中一个触发了 Windows Defender 的脆弱驱动检测，已移除，我们不再走这个方向。

**任何假设都欢迎，越具体越好 —— 尤其是有没有办法，用不需要内核驱动的工具，把 EC 切断 / BMS 跳闸 / VRAM 故障区分开。**