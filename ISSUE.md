# Draft issue for dotnet/runtime

Paste each section into the matching field of the **Bug Report** template
(https://github.com/dotnet/runtime/issues/new?template=01_bug_report.yml).

Suggested title:

    Helper-based tail call with a Span<double> argument corrupts memory (Windows x64, Debug/MinOpts)

---

## Description

A Debug build of deterministic, fully safe F# intermittently crashes with
`ExecutionEngineException` (`0x80131506`) or `AccessViolationException`, computes wrong
results, or wedges — in roughly 2% of freshly started processes. Rebuilding the identical
sources with `-p:Tailcalls=false`, which removes the `tail.` prefix and nothing else, gives
**0 failures in 600 runs**.

The call carrying the `tail.` prefix passes a byref-like struct (`Span<double>`), so the JIT
cannot use a fast tail call and takes the helper-based path:

```
; Assembly listing for method Sweep:<biasAll>__debug@163(System.Span`1[double],double) (MinOpts)
       call     (dynamicClass):IL_STUB_StoreTailCallArgs(System.Span`1[double],System.Object,System.Object)
       call     [System.Runtime.CompilerServices.RuntimeHelpers:DispatchTailCalls(nint,ptr,byref)]
```

There is **no unsafe memory operation anywhere in the repro** — no `unsafe`, no pointer
arithmetic, no `Unsafe.*`, no P/Invoke. The only `MemoryMarshal` use is `Cast`, which is
bounds-checked. Safe managed code should not be able to produce either exception.

The corruption is not confined to the data the program owns: one crash is an unhandled
`AccessViolationException` inside thread-pool bookkeeping, faulting at an address in no
mapped image.

This appears to be **Windows x64 only** — on Linux x64 and arm64 the same `tail.` prefix is
satisfied by a fast tail call, so the helper is never involved (details under Configuration).

Full write-up, with all the evidence:
https://github.com/marklam/dotnet-tailcall-repro/blob/main/BUGREPORT.md

## Reproduction Steps

Repro: https://github.com/marklam/dotnet-tailcall-repro — two projects, ~400 lines of F#,
no dependency beyond `FSharp.Core`.

```
git clone https://github.com/marklam/dotnet-tailcall-repro
cd dotnet-tailcall-repro
run.cmd                             # 400 runs, 8 at a time; builds first
run.cmd 400 8 Debug -NoTailcalls    # control: same sources, -p:Tailcalls=false
```

`./run.sh` and `NOTAILCALLS=1 ./run.sh` are the POSIX equivalents. Each run prints the
machine it ran on; the runner prints a summary grouped by failure signature.

The program computes nothing useful — the arithmetic is deliberately meaningless. It was
reduced from a larger numerical program and all that remains is the shape: a pooled
byref-like struct, a span handed to a cross-assembly call in tail position, and ~1.8M such
calls issued concurrently in a freshly started process. Correctness is checked with no
floating-point tolerance: the same deterministic pass runs twice per process and the two
results are compared bit-exactly, so any difference is memory corruption.

**Four conditions are required**, each confirmed by breaking it and watching the fault go
away:

1. `<Tailcalls>true</Tailcalls>` — not the F# default in Debug. Without it, no `tail.`
   prefix is emitted.
2. An unoptimised (MinOpts) build. In Release the callee is inlined — there is no `biasAll`
   method in the JIT output at all — so no tail call exists. **A passing Release run is
   expected, not a failed reproduction.**
3. The callee in a different assembly. With it in the same assembly the JIT does not take
   the helper-based path and the repro goes silent. Hence two projects.
4. Wide spans per call. At ~9 elements per call there were 0 crashes in 600 runs (wrong
   results continued); at full width, 11 in 600.

Concurrency and volume matter too: the work runs under `Parallel.For`, and the per-call
fault probability is on the order of 1e-8. The fault is concentrated in process **warm-up**,
so it must be run as many short processes — one long-running process making the same number
of calls does not reproduce it.

## Expected behavior

The program either passes or fails deterministically, and in no case produces an
`ExecutionEngineException`, an `AccessViolationException`, or differing results between two
identical passes.

## Actual behavior

Two local machines of different CPU vendors, 400 runs each:

| | machine A | machine B |
|---|---|---|
| CPU | AMD Ryzen AI 9 HX 370 (24 cores) | Intel Core i7-4790K (8 cores) |
| OS | Windows 10.0.26300 | Windows 10.0.19045 |
| `avx512f` | true | **false** |
| failures | **7** | **10** |
| crashes | 6 (5 × `0x80131506`, 1 × AV) | 5 (2 × `0x80131506`, 3 × AV) |

It also reproduces on a **GitHub-hosted runner**, i.e. hardware outside our control:
https://github.com/marklam/dotnet-tailcall-repro/actions/runs/38977023902 — job
`windows-latest`, runner image `windows-2025-vs2026`, AMD EPYC 9V74, 4 vCPU, 2 failures in
200 runs with the control arm at 0 in the same job. (Hosted runners are 4 vCPU, so the rate
there is low; a later dispatch gave 0 in 200.)

**Managed stack** — the frame is the tail call itself:

```
Fatal error.
Internal CLR error. (0x80131506)
   at Sweep.<biasAll>__debug@163(System.Span`1<Double>, Double)
   at Sweep+rowTotals@140.Invoke(System.ValueTuple`2<Double,Single>)
   at Sweep+sweep@132.Invoke(Int32, Double)
   at Prim+Fan+Pipe #1 input at line 120@124[[System.Double, System.__Canon]].Invoke(Int32)
   at System.Threading.Tasks.Parallel+<>c__DisplayClass19_0`2...
```

**Windows Event Log**, machine B, two crashes 96 seconds apart. The first faults inside
`coreclr.dll`:

```
.NET Runtime, Id 1023:
Description: The process was terminated due to an internal error in the .NET Runtime
at IP 0x00007FFFBCD73E9C (0x00007FFFBCCD0000) with exit code 0x80131506.

Application Error, Id 1000:
Faulting module name: coreclr.dll, version: 10.0.1326.50504, time stamp: 0x6ac2c627
Exception code: 0xc0000005
Fault offset: 0x00000000000a3e9c
```

`0x00007FFFBCD73E9C - 0x00007FFFBCCD0000 = 0xA3E9C`, matching the fault offset.

The second is an `AccessViolationException` in thread-pool bookkeeping, with **no faulting
module** — the address is in no mapped image:

```
.NET Runtime, Id 1026:
Description: The process was terminated due to an unhandled exception.
Exception Info: System.AccessViolationException: Attempted to read or write protected memory.
Stack:
   at System.Runtime.EH.DispatchEx(System.Runtime.StackFrameIterator ByRef, ExInfo ByRef)
   at System.Threading.ThreadInt64PersistentCounter.get_Count()
   at System.Threading.PortableThreadPool.AdjustMaxWorkersActive()
   at System.Threading.ThreadPoolWorkQueue.Dispatch()
   at System.Threading.PortableThreadPool+WorkerThread.WorkerThreadStart()

Application Error, Id 1000:
Faulting module name: unknown, version: 0.0.0.0
Exception code: 0xc0000005
Fault offset: 0x00007fff5d23ffcc
```

**Wrong results.** The two identical passes disagree, and sometimes the *input* array is
corrupted:

```
FAIL KEY DIFFERS   row=N col=N first=-0.065799393079150434 second=-34.132764216192427
FAIL TOTAL DIFFERS row=N col=N first=-363.95468024412753   second=-398.0216450672408
FAIL KEY           row=N col=N expected=-0.40698391003859435 actual=-20.353361284170933
```

The last line is a key read back from the source array that no longer matches what was
written at startup; nothing writes to that array after setup.

**Two further manifestations.** A run occasionally livelocks, spinning at 100% of one core
indefinitely (one ran 66 minutes / 3958 CPU-seconds). `dotnet-stack report` could not attach
— the diagnostics request never returned — and a procdump capture showed 28 threads of which
exactly one was in `Cooperative` GC mode, its stack inside a loop whose bound had been
corrupted. Separately, one run was left at 0% CPU with a single remaining thread that
`taskkill /F` refused to terminate even elevated, consistent with a deadlock partway through
fatal-error shutdown.

## Regression?

No. Reproduced on **.NET 8.0.32, 9.0.21 and 10.0.13**, each emitting the identical
`StoreTailCallArgs` / `DispatchTailCalls` sequence. Failure counts over 400 runs per runtime
were 3, 14 and 10 — at these rates those differences are noise, not a trend.

## Known Workarounds

Build with `<Tailcalls>false</Tailcalls>`. For F# that is already the default in Debug; this
only bites projects that turn it on explicitly. Release is unaffected regardless, because
the callee is inlined and no tail call is emitted.

## Configuration

* .NET SDK 10.0.402; runtime 10.0.13 (CoreCLR 10.0.1326.50504); also 9.0.21 and 8.0.32
* `FSharp.Core` 10.1.0.0
* x64, Debug (`Optimize=false`), `Tailcalls=true`
* Windows 10.0.26300, Windows 10.0.19045, and a `windows-2025-vs2026` hosted runner

**It looks specific to Windows x64.** The same `tail.` prefix is in the IL everywhere, but
the JIT satisfies it three different ways. Disassembly of the same method on four
GitHub-hosted runners:

| platform | how the method leaves | runs | failures |
|---|---|---|---|
| Windows x64 | `StoreTailCallArgs` + `DispatchTailCalls` | 200 + 200 | 2, then 0 |
| Linux x64 | `tail.jmp [Prim+Span+Simd:applyAll...]` | 200 | 0 |
| Windows arm64 | `ldp fp, lr, [sp], #0x60` then `br x4` | 200 | 0 |
| Linux arm64 | no helper call emitted | 200 | 0 |

Linux x64 and both arm64 targets use a **fast** tail call, so the helper is never involved.
Their clean results are therefore *not* evidence that those platforms are unaffected — the
construct does not arise there at all.

## Other information

**Ruled out:**

* *GC movement of the span while it sits in the tail-call argument buffer.* 90M calls with a
  forced gen0 collection immediately before each, and 110 passes with gen0 shrunk to 64KB
  (`DOTNET_GCgen0size=10000`), produced zero failures.
* *Tiering / rejit mid-dispatch.* With `DOTNET_TieredCompilation=0` the corruption continues
  (8 gross wrong results and 2 crashes in 400 runs).
* *Vector width.* `DOTNET_PreferredVectorBitWidth=512` behaves the same as the 256-bit
  default, and machine B has no AVX-512 at all.

**Not established:** whether hardware SIMD is required. With `DOTNET_EnableHWIntrinsic=0`,
one arm of 400 runs gave 1 failure against a control of 7 — suggestive, but within the noise
at that sample size.

**A guess, offered only as a starting point:** `Span<double>` is a 16-byte byref-like struct,
and the Windows x64 ABI passes structs larger than 8 bytes by hidden reference into
caller-allocated memory with only four integer argument registers, so a tail call may not be
able to reuse the outgoing argument space safely. SysV x64 and arm64 have more argument
registers and can pass a 16-byte struct in registers, so a plain branch suffices. We have not
verified this.

A 115MB procdump of the livelocked process is available on request.

> [!NOTE]
> This issue was drafted with AI assistance (Claude). The reproduction, measurements and logs
> are real and were verified by hand.
