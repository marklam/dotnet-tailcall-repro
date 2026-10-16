/// Small span and pooling helpers. This is a SEPARATE ASSEMBLY on purpose: with these in the
/// same assembly as the caller the JIT does not take the helper-based tail-call path and the
/// fault does not occur.
module Prim

open System
open System.Buffers
open System.Collections.Generic
open System.Numerics
open System.Runtime.CompilerServices
open System.Runtime.InteropServices
open System.Threading
open System.Threading.Tasks

type IKernel<'T> =
    abstract Wide : Vector<'T> -> Vector<'T>
    abstract Narrow : 'T -> 'T

module ArrayPool =
    [<IsByRefLike; Struct>]
    type Block<'T> = { Backing : 'T[]; Write : Span<'T>; Read : ReadOnlySpan<'T> }

    let inline take<'T> (pool : ArrayPool<'T>) (size : int) : Block<'T> =
        let rented = pool.Rent size
        let span = Span(rented, 0, size)
        { Backing = rented; Write = span; Read = Span.op_Implicit span }

    /// Compiles to `tail.jmp ArrayPool<double>:Return` — one of the two tail-call sites.
    let inline give<'T> (pool : ArrayPool<'T>) (poolSpan : Block<'T>) : unit =
        pool.Return poolSpan.Backing

type Probe =
    | Match of int
    | BeforeFirst
    | AfterLast of int
    | Between of int * int

module Span =
    let decodeProbe length i =
        if i >= 0 then
            Match i
        else
            let iNext = ~~~i
            if iNext = 0 then BeforeFirst
            elif iNext = length then AfterLast(iNext - 1)
            else Between(iNext - 1, iNext)

    let locateWith<'T, 'TArg> (x : 'TArg) (values : ReadOnlySpan<'T>) from upto (comparer : 'T -> 'TArg -> int) =
        let mutable min = from
        let mutable max = upto
        let mutable dun = false
        while not dun && min <= max do
            let mid = (min + max) / 2
            let comparison = comparer values[mid] x
            if comparison = 0 then
                dun <- true
                min <- mid
            elif comparison < 0 then
                min <- mid + 1
            else
                max <- mid - 1
        if dun then min else ~~~min

    let locate (sel : 'T -> 'k) (x : 'k) (values : ReadOnlySpan<'T>) =
        let c = Comparer<'k>.Default
        locateWith x values 0 (values.Length - 1) (fun y x -> c.Compare(sel y, x))
        |> decodeProbe values.Length

    let inline project ([<InlineIfLambda>] f : 'T -> 'U) (inSpan : ReadOnlySpan<'T>) (outSpan : Span<'U>) =
        let len = inSpan.Length
        if len <> outSpan.Length then
            invalidArg (nameof outSpan) "The spans have different lengths."
        for i = 0 to len - 1 do
            outSpan[i] <- f inSpan[i]

    module Simd =
        let inline applyAll
            (data : Span<'T>, [<InlineIfLambda>] mapV : Vector<'T> -> Vector<'T>, [<InlineIfLambda>] mapS : 'T -> 'T)
            =
            let vectored =
                if Vector.IsHardwareAccelerated then
                    let vecData = MemoryMarshal.Cast<'T, Vector<'T>>(data)
                    for i = 0 to vecData.Length - 1 do
                        vecData[i] <- mapV vecData[i]
                    vecData.Length * Vector<'T>.Count
                else
                    0
            for i = vectored to data.Length - 1 do
                data[i] <- mapS data[i]

        /// The call to applyAll is in tail position. With <Tailcalls>true</Tailcalls> fsc emits
        /// `tail. call`, and because an argument is a byref-like struct (Span<double>) the JIT uses
        /// the helper-based path: IL_STUB_StoreTailCallArgs then RuntimeHelpers.DispatchTailCalls.
        let inline biasAll (xs : Span<'T>, value : 'T) =
            let vvalue = Vector<'T> value
            applyAll (xs, (fun x -> x - vvalue), (fun x -> x - value))

        let inline dot (data1 : ReadOnlySpan<'T>, data2 : ReadOnlySpan<'T>) =
            let mutable acc = Unchecked.defaultof<'T>
            let vectored =
                if Vector.IsHardwareAccelerated then
                    let mutable vacc = Vector<'T>.Zero
                    let vecData1 = MemoryMarshal.Cast<'T, Vector<'T>>(data1)
                    let vecData2 = MemoryMarshal.Cast<'T, Vector<'T>>(data2)
                    for i = 0 to vecData1.Length - 1 do
                        vacc <- vacc + (vecData1[i] * vecData2[i])
                    acc <- Vector.Dot(vacc, Vector<'T>.One)
                    vecData1.Length * Vector<'T>.Count
                else
                    0
            for i = vectored to data1.Length - 1 do
                acc <- acc + (data1[i] * data2[i])
            acc

module Fan =
    let p = Environment.ProcessorCount

    let mapi token f (xs : _[]) =
        let result = Array.zeroCreate xs.Length
        Parallel.For(
            0,
            xs.Length,
            ParallelOptions(CancellationToken = token, MaxDegreeOfParallelism = p),
            fun i -> result[i] <- f i xs[i]
        )
        |> ignore<ParallelLoopResult>
        result
