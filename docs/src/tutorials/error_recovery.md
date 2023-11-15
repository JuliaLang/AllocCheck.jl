# Guaranteed Error Recovery

Safety-critical real-time systems are often required to have performance critical error-recovery logic. While errors are not supposed to occur, they sometimes do anyways 😦, and when they do, we may want to make sure that the recovery logic runs with minimum latency.

In the following example, we are executing a loop that may throw an error. By default [`check_allocs`](@ref) allows allocations on the error path, i.e., allocations that occur as a consequence of an exception being thrown. This can cause the garbage collector to be invoked by the allocation, and introduce an unbounded latency before we execute the error recovery logic.

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
allocs = check_allocs(treading_lightly, ()) # Check that it's safe to proceed
```
```@example ERROR
@test isempty(allocs)
```

[`check_allocs`](@ref) returned zero allocations. If we invoke [`check_allocs`](@ref) with the flag `ignore_throw = false`, we will see that the function may allocate memory on the error path:

```@example ERROR
allocs = check_allocs(treading_lightly, (); ignore_throw = false)
length(allocs)
```

Finally, we test that the function is producing the expected result:

```@example ERROR
val = treading_lightly()
@test val ≈ 22.468278186204103  # hide
```

In this example, we accepted an allocation on the exception path with the motivation that it occurred once only, after which the program was terminated. Implicit in this approach is an assumption that the exception path does not allocate too much memory to execute the error recovery logic before the garbage collector is turned back on. We should thus convince ourselves that this assumption is valid, e.g., by means of testing:
    
```@example ERROR
treading_lightly() # Warm start
allocated_memory = @allocated treading_lightly() # A call that triggers the exception path
# @test allocated_memory < 1e4
```

The allocations sites reported with the flag `ignore_throw = false` may be used as a guide as to what to test.
