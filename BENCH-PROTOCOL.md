# A comparison protocol you can trust

Sixth companion. The other documents report single measurements. This one is the **method** used to
take them, written down so the same comparison can be repeated — including by you, on your card, and
including the ways we fooled ourselves first.

It exists because the most expensive mistakes here were not hardware: they were **benchmarks that
were not running**.

---

## The four conditions

**1. Force the work to actually happen.**
Diffusion front-ends cache aggressively. ComfyUI returns `execution_cached` for every node — and
finishes in seconds — when the workflow, parameters **and seed** are unchanged. A "5.1 s, 26 W"
image result was a cache hit.

* change an upstream parameter or the prompt **and** the seed between runs;
* confirm from the server's own log/queue that nodes executed;
* check the output file's timestamp moved.

**2. Measure the machine, not the app.**
An application's "engine time" excludes model loading, queueing and warm-up. Both numbers are
useful, but they answer different questions:

```
engine time   -> how fast is the compute
wall time     -> what the user waits
power/temp    -> what the machine pays
```

Report all three, and say which is which.

**3. Sample power and temperature on a fixed interval, and keep the raw data.**
2 s interval, one row per sample, flushed to disk, with the timestamp first. Then peaks, means and
windows can all be recomputed later without re-running anything. Our single most-corrected
conclusion came from re-slicing data we had already logged.

**4. Change one thing.**
State the variable in the report. If you changed two settings between two runs, you have two runs and
zero conclusions.

---

## The comparison matrix worth running (and what we know so far)

Fill in your own numbers; ours are in the other documents.

| # | Variable | Fixed | Measure | What we found |
|---|---|---|---|---|
| 1 | Encoder device (iGPU vs dGPU) | same image, same prompt | machine peak, encode time | **191 W vs 313 W**, encode ~2 s either way |
| 2 | Power profile (performance / silent) | same video workload | machine peak | up to **323 W vs ~227 W** |
| 3 | CPU maximum state | same image workload | CPU peak | 80% -> 75%: **124 W -> 98 W** |
| 4 | **CPU minimum state** | same job, timing | wall time | **20% -> 83.2 s, 50% -> 25.6 s, 100% -> 26.7 s** |
| 5 | Quantisation of the KV cache | same context length | VRAM used, whether it fits | `q8_0` is what makes 64K viable at 12 GB |
| 6 | Speculative decoding on/off | same model, same prompt | time to first token, total | enabled throughout here; A/B still to run |

**Rows 5 and 6 are the ones we have not done properly.** If you run them, please post the numbers —
they are the most useful gaps on this card.

---

## Template

```
Card / driver:
Adapter rating (W):
OS / build:

Variable changed:
Everything else held constant:

Workload (model, resolution, steps, frames):
  engine time:
  wall time:
  machine peak (W):        CPU peak:        GPU hot spot (C):
  VRAM used (MB):
  output verified? (seed changed / nodes executed / timestamp moved):

Unexpected:
```

---

## A note on reporting

Several numbers in this repository were wrong the first time. The pattern was always the same:
**the check was broken, not the machine** — a cache hit read as a fast run, a failed transfer read as
a fast link, a truncated capture read as a wrong answer.

So: when a result surprises you, **suspect the measurement first**. Change the check, re-run, and only
then believe the number. Corrections to these documents are welcome on the same basis.