/// Deliberately meaningless arithmetic over a 2D array of (key, weight) pairs. The results are
/// nonsense by construction: the projection mixes both fields, the offset comes from a loop
/// counter, and the accumulator folds in its own index. Only the SHAPE matters -- a pooled
/// byref-like struct, a span passed to a cross-assembly call in tail position, and ~1.8M of
/// them issued concurrently in a freshly started process.
///
/// Nothing here is unsafe. The only MemoryMarshal use is Prim's Cast, which is bounds-checked.
module Sweep

open System
open System.Buffers
open System.Numerics
open System.Runtime.CompilerServices

open Prim
open Prim.Span

let baseScale = 2.0 / ((Math.PI ** 0.25) * (sqrt 3.0))

[<Struct>]
type Shape =
    {
        ScaleA : float
        ScaleB : float
        Offset : float
        Weight : float
    }

    interface IKernel<float> with
        [<MethodImpl(MethodImplOptions.AggressiveInlining)>]
        member this.Wide(y : Vector<float>) = y * Vector this.ScaleA

        [<MethodImpl(MethodImplOptions.AggressiveInlining)>]
        member this.Narrow(y : float) = y * this.ScaleB

let makeShape (spanA : float, spanB : float) =
    let pads = 7.0 * spanA, 7.0 * spanB
    let scaleA = 1.0 / (spanA * spanA)
    let scaleB = 1.0 / (spanB * spanB)
    let norm = baseScale * sqrt ((spanA + spanB) / 2.0)

    let sel =
        fun (x : float) ->
            let ratioA = x * x * scaleA
            {
                ScaleA = scaleA
                ScaleB = scaleB
                Offset = 1.0 - ratioA
                Weight = norm * exp (-0.5 * ratioA)
            }

    (pads, sel)

let inline firstOf (struct (value, _)) =
    value

let inline widenWindow
    ([<InlineIfLambda>] sel : 'x -> float)
    centerIndex
    (targetDiff : float)
    struct (lowStart : int, highStart : int)
    (values : ReadOnlySpan<'x>)
    =
    let targetVal = sel values[centerIndex]
    let mutable upperIndex = highStart
    let mutable dun = false
    let n = values.Length
    while not dun && upperIndex < n do
        if sel values[upperIndex] - targetVal > targetDiff then
            dun <- true
            upperIndex <- upperIndex - 1
        else
            upperIndex <- upperIndex + 1

    let mutable lowerIndex = lowStart
    dun <- false
    while not dun && lowerIndex >= 0 do
        let diff = targetVal - sel values[lowerIndex]
        if diff >= targetDiff then
            dun <- true
            if diff > targetDiff then
                lowerIndex <- lowerIndex + 1
        else
            lowerIndex <- lowerIndex - 1

    (max 0 lowerIndex, min (n - 1) upperIndex)

let inline advanceWindow
    ([<InlineIfLambda>] sel : 'x -> float)
    (targetValue : float)
    (targetDiff : float)
    struct (lowStart : int, highStart : int)
    (data : ReadOnlySpan<'x>)
    =
    let n = data.Length
    let mutable lowerIndex = lowStart
    let mutable upperIndex = highStart
    let mutable dun = false
    if (lowerIndex = 0) && (upperIndex = 0) then
        match Span.locate sel (targetValue - targetDiff) data with
        | Match i -> lowerIndex <- i
        | BeforeFirst -> lowerIndex <- 0
        | AfterLast n -> lowerIndex <- n
        | Between(close, _) -> lowerIndex <- close

    while not dun && (lowerIndex < n - 1) do
        if targetValue - sel data[lowerIndex] <= targetDiff then
            dun <- true
        else
            lowerIndex <- lowerIndex + 1

    upperIndex <- min (n - 1) (max upperIndex (lowerIndex + 1))
    dun <- false
    while not dun && (upperIndex <= n - 1) do
        if sel data[upperIndex] - targetValue > targetDiff then
            dun <- true
            upperIndex <- upperIndex - 1
        else
            upperIndex <- upperIndex + 1

    (lowerIndex, min (n - 1) upperIndex)

let inline sweep<'sel when 'sel :> IKernel<float> and 'sel : struct>
    token
    (keys : float[])
    (slices : struct (float * single)[][])
    ((padRow : float, padCol : float), shape : float -> 'sel)
    =
    let pool = ArrayPool<float>.Shared

    keys
    |> Fan.mapi token (fun iRow tag ->
        let firstSlice = slices[iRow]
        let (rowLo, rowHi) = widenWindow id iRow padRow (iRow, iRow) (ReadOnlySpan keys)
        let len = rowHi - rowLo + 1
        let windowCache = Array.zeroCreate len

        let rowTotals =
            firstSlice
            |> Array.map (fun struct (key, _) ->
                let tagRange = ReadOnlySpan(keys, rowLo, len)
                let sliceRange = ReadOnlySpan(slices, rowLo, len)
                let mutable total = 0.0

                for iSlice = 0 to len - 1 do
                    let slice = sliceRange[iSlice]

                    if slice.Length <> 0 then
                        let (lower, upper) =
                            advanceWindow
                                firstOf
                                key
                                padCol
                                windowCache[iSlice]
                                (ReadOnlySpan slice)

                        windowCache[iSlice] <- struct (lower, upper)
                        let width = upper - lower + 1
                        let window = ReadOnlySpan(slice, lower, width)
                        let res = ArrayPool.take pool width

                        Span.project (fun struct (k, w) -> float w * 0.25 - k) window res.Write
                        Span.Simd.biasAll (res.Write, float iSlice * 0.5 - key)
                        // Step A: second pooled span, its project and Span.Simd.dot removed; a scalar
                        // sum is simpler and still reads every element back.
                        for i = 0 to width - 1 do
                            total <- total * 0.5 + res.Read[i] - float i
                        ArrayPool.give pool res

                struct (key, total))

        (tag, rowTotals))
