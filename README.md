# Heap corruption and `ExecutionEngineException` from a helper-based tail call with a `Span<double>` argument

A Debug build of deterministic, fully safe F# either crashes, computes the wrong answer, or
livelocks, in roughly 2% of freshly started processes. Rebuilding the same sources with
`-p:Tailcalls=false` removes it entirely.

Reproduced on .NET **8.0.32, 9.0.21 and 10.0.13** — this is not a regression in 10.

## Running it

    ./run.sh                      # default 400 runs, 8 at a time; expect ~11 failures, ~7 crashes
    ./run.sh 600 8                # the sample the numbers below were measured on
    NOTAILCALLS=1 ./run.sh        # the control: same sources, -p:Tailcalls=false, expect 0

On Windows use `run.cmd` or `run.ps1`:

    run.cmd                              # default 400 runs
    run.cmd 600 8 Debug                  # explicit
    run.cmd 600 8 Debug -NoTailcalls     # the control

All three build first,
run N short processes, and print a summary. Every run prints the machine it ran on:

    env runtime=.NET 10.0.13 os=Microsoft Windows 10.0.26300 arch=X64 cores=24 vectorBits=256 hwAccel=true avx2=true avx512f=true cpu=AMD Ryzen AI 9 HX 370 w/ Radeon 890M

The fault is concentrated in process **warm-up**, so it has to be run as many short processes.
A single long-running process doing the same number of calls does not reproduce it: an earlier
reduction survived 90M calls in 8 processes, then failed within 400 single-pass ones.

## What the program is

Nothing. The arithmetic is meaningless by construction — the projection mixes both fields of
each pair, the offset comes from a loop counter rather than the data, and the accumulator
halves itself and folds in its own index. It was reduced from a larger numerical program by
renaming and mutation, and all that was kept is the *shape*: a pooled byref-like struct, a
span handed to a cross-assembly call in tail position, and ~1.8M of those calls issued
concurrently in a freshly started process.

**There is no unsafe memory operation anywhere in it.** The only `MemoryMarshal` use is
`Cast`, which is bounds-checked. Safe managed code should not be able to produce an
`AccessViolationException` or an `ExecutionEngineException`.

Correctness is judged without any floating-point tolerance: the same deterministic pass runs
twice in one process and the two results are compared bit-exactly, so any difference is
memory corruption.

## Symptom

Over 600 runs, 16 failed:

*   11 hard crashes — 9 × `Fatal error. Internal CLR error. (0x80131506)`
    (`ExecutionEngineException`) and 2 × `System.AccessViolationException: Attempted to read
    or write protected memory`. The stack is always the tail call itself:

        at Sweep.<biasAll>__debug@163(System.Span`1<Double>, Double)
        at Sweep+rowTotals@140.Invoke(System.ValueTuple`2<Double,Single>)
        at Sweep+sweep@132.Invoke(Int32, Double)
        at Prim+Fan+Pipe ...

    `advanceWindow` is the other site it lands on.
*   5 wrong results, e.g.

        FAIL TOTAL DIFFERS row=40 col=117 first=-241.75085256198827 second=-356.05764724395959

*   Occasionally a run **livelocks** instead, spinning at 100% of one core indefinitely. One
    was left for 66 minutes and 3958 CPU-seconds. `dotnet-stack report` cannot attach — the
    diagnostics request never returns, because the runtime is not reaching a safe point. A
    procdump capture showed 28 threads of which exactly one was in `Cooperative` GC mode, its
    stack inside a `while` loop whose bound had been corrupted. The runners cap each run
    (default 300s) and count a timeout as a failure so one stuck run cannot stall a batch.

## The construct

`Prim.Span.Simd.biasAll` ends with a call to `applyAll` in tail position, so with
`<Tailcalls>true</Tailcalls>` fsc emits `tail. call`. One argument is a byref-like struct
(`Span<double>`), so the JIT cannot use a fast tail call and takes the helper-based path:

    ; Assembly listing for method Sweep:<biasAll>__debug@163(System.Span`1[double],double) (MinOpts)
           call     (dynamicClass):IL_STUB_StoreTailCallArgs(System.Span`1[double],System.Object,System.Object)
           call     [System.Runtime.CompilerServices.RuntimeHelpers:DispatchTailCalls(nint,ptr,byref)]

`Prim.ArrayPool.give` separately compiles to `tail.jmp ArrayPool<double>:Return`. To see this:

    DOTNET_JitDisasm='*biasAll*' ./App/bin/Debug/net10.0/App.exe

## Four conditions, all required

Each was confirmed by breaking it and watching the fault disappear.

1.  **`<Tailcalls>true</Tailcalls>`** — not the F# default in Debug. Without it no `tail.`
    prefix is emitted. See the control arm below.
2.  **An unoptimised (MinOpts) build.** In Release `applyAll` is inlined — there is no
    `biasAll` method in the JIT output at all — so no tail call exists and the fault cannot
    occur. **A Release run passing is expected, not a failed reproduction.**
3.  **The callee in a different assembly.** With `applyAll` in the same assembly as its caller
    the JIT does not take the helper-based path, no `DispatchTailCalls` appears, and the repro
    goes silent. Hence two projects, `Lib` and `App`.
4.  **Wide spans.** The crashes need a large span per call. At ~9 elements per call there were
    **0 crashes in 600 runs** (though wrong-result failures continued at the same rate);
    at full width, 11 in 600. `App.exe [size] [spanA] [spanB] [seed]` — the third argument
    controls this, and the default is full width.

Concurrency and volume also matter: the work runs under `Parallel.For`, and the per-call
fault probability is on the order of 1e-8, so a reduction making only ~12k calls per process
stays silent over hundreds of runs.

## Evidence

Same sources, same compiler, only `-p:Tailcalls=false` differing:

| `tail.` | runs | failures | crashes |
|---------|------|----------|---------|
| on | 600 | 16 | 11 |
| **off** (`-p:Tailcalls=false`) | 600 | **0** | **0** |

Fisher exact on those two arms: p < 1e-5.

Earlier arms on the unobfuscated original: 13 failures in 800 runs with tail calls on against
**0 in 400** with them off (Fisher exact p ≈ 0.004), and 10/400 vs 0/400 on a self-contained
reduction (p ≈ 0.002).

## Ruled out

*   **GC movement of the span while it sits in the tail-call argument buffer.** 90M calls with
    a forced gen0 collection before each, and 110 passes with gen0 shrunk to 64KB
    (`DOTNET_GCgen0size=10000`), produced zero failures.
*   **Tiering.** With `DOTNET_TieredCompilation=0` the corruption continues — 8 gross wrong
    results and 2 crashes in 400 runs — so rejit mid-dispatch is not the mechanism.
*   **Vector width.** 512-bit (`DOTNET_PreferredVectorBitWidth=512`) behaves the same as the
    256-bit default.

Not established: whether hardware SIMD is required at all. With
`DOTNET_EnableHWIntrinsic=0` one arm of 400 runs gave 1 failure against a control's 7, which
is suggestive but inside the noise at that sample size.
