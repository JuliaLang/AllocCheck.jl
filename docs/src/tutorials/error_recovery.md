# Guaranteed Error Recovery

Safety-critical real-time systems are often required to have performance critical error-recovery logic. While errors are not supposed to occur, they sometimes do anyways 😦, and when they do, we may want to make sure that the recovery logic runs with minimum latency.

In the following example, we are executing a loop that may throw an error. We can tell [`check_allocs`](@ref) that we allow allocations on the error path by passing `ignore_throw=true`, but a bigger problem may arise, the garbage collector may be invoked by the allocation, and introduce an unbounded latency before we execute the error recovery logic.

To guard ourselves against this, we may follow these steps
1. Prove that the function does not allocate memory except for on exception paths.
2. Since we have proved that we are not allocating memory, we may disable the garbage collector. This prevents it from running before the error recovery logic.
3. To make sure that the garbage collector is re-enabled after an error has been recovered from, we re-enable it in a `finally` block.



```@example ERROR
function treading_lightly()
    a = 0.0
    GC.enable(false) # Turn off the GC before entering the loop
    try
        for i = 10:-1:-1
            a += sqrt(i) # This throws an error for negative values of i
        end
    catch
        exit_gracefully() # This function is supposed to run with minimum latency
    finally
        GC.enable(true) # Always turn the GC back on before exiting the function
    end
    a
end
exit_gracefully() = println("Calling mother")

using AllocCheck, Test
allocs = check_allocs(treading_lightly, (); ignore_throw=true) # Check that it's safe to proceed
```

[`check_allocs`](@ref) returned zero allocations.

```@example ERROR
val = treading_lightly()
@test val ≈ 22.468278186204103  # hide
```

