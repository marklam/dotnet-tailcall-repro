# Helper-based tail call with a `Span<double>` argument corrupts the heap (Debug/MinOpts, x64)

## Description

A Debug build of deterministic, fully safe F# intermittently crashes with
`ExecutionEngineException` or `AccessViolationException`, computes wrong results, or wedges,
in roughly 2% of freshly started processes. Rebuilding the identical sources with
`-p:Tailcalls=false` — which removes the `tail.` prefix and nothing else — gives **0 failures
in 600 runs**.

The call that carries the `tail.` prefix passes a byref-like struct (`Span<double>`), so the
JIT cannot use a fast tail call and goes down the helper-based path:

```
; Assembly listing for method Sweep:<biasAll>__debug@163(System.Span`1[double],double) (MinOpts)
       call     (dynamicClass):IL_STUB_StoreTailCallArgs(System.Span`1[double],System.Object,System.Object)
       call     [System.Runtime.CompilerServices.RuntimeHelpers:DispatchTailCalls(nint,ptr,byref)]
```

There is **no unsafe memory operation anywhere in the repro**. The only `MemoryMarshal` use
is `Cast`, which is bounds-checked. There is no `unsafe`, no pointer arithmetic, no
`Unsafe.*`, no P/Invoke. Safe managed code should not be able to produce either exception.

The corruption is not confined to the data the program owns. One crash is an unhandled
`AccessViolationException` raised inside thread-pool bookkeeping, with no faulting module at
all (see the Event Log section), which is what a control transfer to a garbage address looks
like.

**This is not a regression in .NET 10.** It reproduces on 8.0.32, 9.0.21 and 10.0.13, all of
which emit the identical `StoreTailCallArgs` / `DispatchTailCalls` sequence.

## Reproduction

https://github.com/marklam/dotnet-tailcall-repro — two projects, ~400 lines of F#, no
dependency beyond `FSharp.Core`.

```
git clone https://github.com/marklam/dotnet-tailcall-repro
cd dotnet-tailcall-repro
run.cmd                             # 400 runs, 8 at a time; builds first
run.cmd 400 8 Debug -NoTailcalls    # the control: same sources, -p:Tailcalls=false
```

`./run.sh` and `NOTAILCALLS=1 ./run.sh` are the equivalents on a POSIX shell. Each run prints
the machine it ran on, and the runner prints a summary with failures grouped by signature.

The program computes nothing useful — the arithmetic is deliberately meaningless. It was
reduced from a larger numerical program, and all that remains is the shape: a pooled
byref-like struct, a span handed to a cross-assembly call in tail position, and ~1.8M of
those calls issued concurrently in a freshly started process. Correctness is checked with no
floating-point tolerance: the same deterministic pass runs twice per process and the two
results are compared bit-exactly, so any difference is memory corruption.

### Four conditions are required

Each was confirmed by breaking it and watching the fault disappear.

1. **`<Tailcalls>true</Tailcalls>`.** Not the F# default in Debug. Without it no `tail.`
   prefix is emitted.
2. **An unoptimised (MinOpts) build.** In Release the callee is inlined — there is no
   `biasAll` method in the JIT output at all — so no tail call exists. **A passing Release
   run is expected, not a failed reproduction.**
3. **The callee in a different assembly.** With the callee in the same assembly the JIT does
   not take the helper-based path, no `DispatchTailCalls` appears, and the repro goes silent.
   Hence two projects.
4. **Wide spans per call.** The crashes need a large span. At ~9 elements per call there were
   **0 crashes in 600 runs** while wrong-result failures continued at the same rate; at full
   width, 11 crashes in 600. The third CLI argument controls this and defaults to full width.

Concurrency and volume also matter: the work runs under `Parallel.For`, and the per-call
fault probability is on the order of 1e-8, so a variant making only ~12k calls per process
stays silent over hundreds of runs. The fault is concentrated in process **warm-up**, so it
must be run as many short processes — one long-running process making the same number of
calls does not reproduce it (an earlier reduction survived 90M calls across 8 processes, then
failed within 400 single-pass ones).

## Expected behaviour

The program either passes or fails deterministically, and in no case produces an
`ExecutionEngineException`, an `AccessViolationException`, or differing results between two
identical passes.

## Actual behaviour

Two machines, different CPU vendors, 400 runs each.

| | machine A | machine B |
|---|---|---|
| CPU | AMD Ryzen AI 9 HX 370 | Intel Core i7-4790K @ 4.00GHz |
| cores | 24 | 8 |
| OS | Windows 10.0.26300 | Windows 10.0.19045 |
| `vectorBits` | 256 | 256 |
| `avx2` / `avx512f` | true / **true** | true / **false** |
| runtime | .NET 10.0.13 | .NET 10.0.13 |
| runs | 400 | 400 |
| **failures** | **7** | **10** |
| crashes | 6 (5 x `0x80131506`, 1 x AV) | 5 (2 x `0x80131506`, 3 x AV) |

Full `env` lines as printed by the repro:

```
env runtime=.NET 10.0.13 os=Microsoft Windows 10.0.26300 arch=X64 cores=24 vectorBits=256 hwAccel=true avx2=true avx512f=true cpu=AMD Ryzen AI 9 HX 370 w/ Radeon 890M
env runtime=.NET 10.0.13 os=Microsoft Windows 10.0.19045 arch=X64 cores=8 vectorBits=256 hwAccel=true avx2=true avx512f=false cpu=Intel(R) Core(TM) i7-4790K CPU @ 4.00GHz
```

AVX-512 is absent on machine B, so it is not required.

### Wrong results

The two identical passes disagree. Some differences are gross, and some corrupt the *input*
array rather than the output:

```
FAIL KEY DIFFERS   row=N col=N first=-0.065799393079150434 second=-34.132764216192427
FAIL TOTAL DIFFERS row=N col=N first=-363.95468024412753   second=-398.0216450672408
FAIL KEY           row=N col=N expected=-0.40698391003859435 actual=-20.353361284170933
```

The last line is a key read back from the source array that no longer matches the value
written into it at startup; nothing in the program writes to that array after setup.

### Crashes, from the managed side

```
Fatal error.
Internal CLR error. (0x80131506)
   at Sweep.<biasAll>__debug@163(System.Span`1<Double>, Double)
   at Sweep+rowTotals@140.Invoke(System.ValueTuple`2<Double,Single>)
   at Sweep+sweep@132.Invoke(Int32, Double)
   at Prim+Fan+Pipe #1 input at line 120@124[[System.Double, System.__Canon]].Invoke(Int32)
   at System.Threading.Tasks.Parallel+<>c__DisplayClass19_0`2...
```

The frame is the tail call itself. A window-advancing helper called immediately before it is
the other site the fault lands on.

### Windows Event Log (machine B)

Two crashes 96 seconds apart. First, a fatal engine error — note the IP, and that the
faulting module is `coreclr.dll`:

```
=== 16/10/2026 18:44:36 | .NET Runtime | Id 1023 ===
Application: App.exe
CoreCLR Version: 10.0.1326.50504
.NET Version: 10.0.13
Description: The process was terminated due to an internal error in the .NET Runtime
at IP 0x00007FFFBCD73E9C (0x00007FFFBCCD0000) with exit code 0x80131506.

=== 16/10/2026 18:44:37 | Application Error | Id 1000 ===
Faulting application name: App.exe, version: 1.0.0.0, time stamp: 0x6ac20000
Faulting module name: coreclr.dll, version: 10.0.1326.50504, time stamp: 0x6ac2c627
Exception code: 0xc0000005
Fault offset: 0x00000000000a3e9c
Faulting module path: C:\Program Files\dotnet\shared\Microsoft.NETCore.App\10.0.13\coreclr.dll
```

`0x00007FFFBCD73E9C - 0x00007FFFBCCD0000 = 0xA3E9C`, matching the fault offset, so the access
violation is inside `coreclr.dll + 0xA3E9C`.

The second crash is an `AccessViolationException` surfacing in thread-pool bookkeeping, with
**no faulting module** — the fault address is not in any mapped image:

```
=== 16/10/2026 18:46:12 | .NET Runtime | Id 1026 ===
Application: App.exe
CoreCLR Version: 10.0.1326.50504
.NET Version: 10.0.13
Description: The process was terminated due to an unhandled exception.
Exception Info: System.AccessViolationException: Attempted to read or write protected memory.
This is often an indication that other memory is corrupt.
Stack:
   at System.Runtime.EH.DispatchEx(System.Runtime.StackFrameIterator ByRef, ExInfo ByRef)
   at System.Threading.ThreadInt64PersistentCounter.get_Count()
   at System.Threading.PortableThreadPool.AdjustMaxWorkersActive()
   at System.Threading.ThreadPoolWorkQueue.Dispatch()
   at System.Threading.PortableThreadPool+WorkerThread.WorkerThreadStart()
   at System.Threading.Thread.StartCallback()

=== 16/10/2026 18:46:13 | Application Error | Id 1000 ===
Faulting application name: App.exe, version: 1.0.0.0, time stamp: 0x6ac20000
Faulting module name: unknown, version: 0.0.0.0, time stamp: 0x00000000
Exception code: 0xc0000005
Fault offset: 0x00007fff5d23ffcc
Faulting module path: unknown
```

This is well away from the code the repro itself runs, and shows the corruption reaching
runtime data structures.

### Two further manifestations

* **Livelock.** A run occasionally neither crashes nor finishes, spinning at 100% of one core
  indefinitely — one was left for 66 minutes and 3958 CPU-seconds. `dotnet-stack report`
  could not attach; the diagnostics request never returned, i.e. the runtime was not reaching
  a safe point. A procdump capture showed 28 threads of which exactly **one** was in
  `Cooperative` GC mode, its stack inside a `while` loop whose bound had been corrupted.
* **A process that cannot be killed.** On machine B a run was left at 0% CPU with a single
  remaining thread, which `taskkill /F` refused to terminate even elevated — consistent with
  a deadlock partway through fatal-error shutdown. Only a reboot cleared it.

## Regression?

No. Reproduced on **.NET 8.0.32, 9.0.21 and 10.0.13**, with the identical helper-based
tail-call sequence emitted on each. Failure counts across 400 runs per runtime were 3, 14 and
10; at these rates those differences are noise rather than a trend.

## Ruled out

* **GC movement of the span while it sits in the tail-call argument buffer.** 90M calls with a
  forced gen0 collection immediately before each, and 110 passes with gen0 shrunk to 64KB
  (`DOTNET_GCgen0size=10000`), produced zero failures.
* **Tiering / rejit mid-dispatch.** With `DOTNET_TieredCompilation=0` the corruption continues
  (8 gross wrong results and 2 crashes in 400 runs), so tier transitions are not the
  mechanism.
* **Vector width.** `DOTNET_PreferredVectorBitWidth=512` behaves the same as the 256-bit
  default, and machine B has no AVX-512 at all.
* **Application-level unsafe code.** There is none; see above.

Not established: whether hardware SIMD is required at all. With `DOTNET_EnableHWIntrinsic=0`
one arm of 400 runs gave 1 failure against a control of 7 — suggestive, but within the noise
at that sample size.

## Configuration

* .NET SDK 10.0.402; runtime 10.0.13 (CoreCLR 10.0.1326.50504), also 9.0.21 and 8.0.32
* `FSharp.Core` 10.1.0.0
* x64, Debug (`Optimize=false`), `Tailcalls=true`
* Windows 10.0.26300 and Windows 10.0.19045
