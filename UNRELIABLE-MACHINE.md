# Working on a machine that can vanish

Fifth companion to the main README. This one is not about AMD specifically. It is what changed in
how we work after a machine started cutting power without warning — measured facts about the box in
the main README §5, process here.

If your machine crashes, thermal-cuts, loses its network, or reboots on its own often enough that you
start planning around it, these are the habits that paid off.

---

## 1. Decide what "done" means before you start

A long job on this machine is a bet. So each job is split into **steps that each end in a durable
state**:

* a file written, or nothing;
* a commit pushed, or nothing;
* a result *read out* of the machine, or nothing.

**A step that leaves its result only inside the machine's memory has not happened.** The failure mode
to design against is not "the job fails" — it is "the job succeeds and the evidence dies with the
box".

## 2. Push everything that matters, immediately

Notes, scripts, configs, the thing you just worked out — into a git repository, pushed, as part of
finishing the step rather than afterwards. On this setup that repository is also synced to a third
machine, because a single remote is a single point of failure too.

The cost of pushing a small commit is seconds. The cost of reconstructing two hours of reasoning from
memory is two hours you do not have.

## 3. Copy to another machine — and **zip first**

Measured on a 31 ms-RTT link between two of these machines:

| payload | size | time | effective rate |
|---|---|---|---|
| one archive | 126.6 MB | 22.8 s | **5.29 MB/s** |
| 1183 loose files | **11.6 MB** | **447.9 s** | **0.026 MB/s** |

**200x difference, and the loose files were eleven times smaller.** Small-file transfer is dominated
by round-trip latency, not bandwidth. **One archive beats a directory tree, always.**

And test the *route*, not just the endpoints: the same pair moved data at 3.3-5.3 MB/s directly and at
**0.05 MB/s** through an intermediate host — because that path was relayed rather than direct.
`tailscale ping <host>` tells you which one you have.

## 4. Start and stop things from outside your own process tree

If the tool you drive things from also owns the processes, killing a child can take down the parent.
We crashed our own job runner twice by killing a process we had started ourselves with a
tree-killing flag.

**What works instead:** put the start/stop action in a **scheduled task** (Task Scheduler,
`schtasks /create` + `/run`) and let the scheduler own the process. It survives your session ending,
and killing it does not touch you.

Corollary: **never use a tree-kill flag on a process you started**. Kill by image name, or by pid,
without `/T`.

## 5. Capture output, or you are blind

A job that runs without logging is a job you cannot diagnose. The first version of one long build
here produced **no output at all** for 100 minutes, because the script's own error handling was
terminating it silently and the scheduled task discarded the console. The monitor reported "still
running" for an hour and a half.

**Every unattended job redirects both streams to a file:**

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File job.ps1 >> D:\work\job-all.log 2>&1
echo ----- RC=%ERRORLEVEL% at %TIME% ----- >> D:\work\job-all.log
```

and the monitor watches **the log's growth**, distinguishes "still growing" from "finished" from
"failed", and prints the tail when it ends. A monitor that cannot tell "no output yet" from "my own
command failed" is not a monitor.

## 6. Verify with foreign evidence

Two failures of this kind in one day:

* **Matching a value you sent proves nothing.** A check looked for a sentinel string in the output
  of a remote command — and matched the command's own echo in an error message, reporting success
  for a connection that had been refused. Use the **exit code** and a value **the remote generated**.
* **Never compute a rate from a failed transfer.** A copy failed in 1.2 s; dividing the file size by
  that produced a confident "101 MB/s". Require exit code 0 **and** a byte-count match before
  quoting any number.

## 7. Make the machine's behaviour a measurement, not a story

Keep a logger running that samples power and temperature on a fixed interval and flushes each line.
Ours writes every 2 s and has settled more arguments than any reasoning: it showed cuts at idle
(34 W), at light load (55 W) and at sustained load (244 W), and that the outage length afterwards
does **not** track temperature at all — which is what ruled out the thermal explanation we started
with.

Cross-check it against the OS event log, and read the log's *message body* rather than its timestamp:
event `6008` ("the previous shutdown was unexpected") is written at the **next boot**, and its body
carries the actual time of the loss.

## 8. Separate the unreliable machine from the work

The most effective single decision: **the unreliable box does not run the heavyweight workloads.**
It holds the small always-needed service (a local model server), and everything expensive runs on a
machine that stays up (see TWO-MACHINE-SPLIT.md).

That is not defeat. The unreliable machine still earns its place — it just stops being the place
where a 40-minute job goes to die.

## 9. Honest boundaries

Everything above is from one machine with one particular fault. The habits generalise; the specific
numbers do not. The underlying rule does: **assume the machine will stop at the worst moment, and
arrange for that to cost you one step rather than one day.**