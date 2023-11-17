# Allocations followed by a hot loop
A common pattern in high-performance Julia code, as well as in real-time systems, is to initially allocate some working memory, followed by the execution of a performance sensitive _hot loop_ that should perform no allocations. In the example below, we show a function `run_almost_forever` that resembles the implementation of a simple control system. The function starts by allocating a large `logvector` in which some measurement data is to be saved, followed by the execution of a loop which should run with as predictable timing as possible, i.e., we do not want to perform any allocations or invoke the garbage collector while executing the loop.
```@example HOT_LOOP
function run_almost_forever()
    N = 100_000 # A large number
    logvector = zeros(N) # Allocate a large vector for storing results
    for i = 1:N # Run a hot loop that may not allocate
        y = sample_measurement()
        logvector[i] = y
        u = controller(y)
        apply_control(u)
        Libc.systemsleep(0.01)
    end
end

# Silly implementations of the functions used in the example
sample_measurement() = 2.0
controller(y) = -2y
apply_control(u) = nothing
nothing # hide
```

Here, the primary concern is the loop, while the preamble of the function should be allowed to allocate memory. The recommended strategy in this case is to refactor the function into a separate preamble and loop, like this
```@example HOT_LOOP
function run_almost_forever2() # The preamble that performs allocations
    N = 100_000 # A large number
    logvector = zeros(N) # Allocate a large vector for storing results
    run_almost_forever!(logvector)
end

function run_almost_forever!(logvector) # The hot loop that is allocation free
    for i = eachindex(logvector) # Run a hot loop that may not allocate
        y = sample_measurement()
        @inbounds logvector[i] = y
        u = controller(y)
        apply_control(u)
        Libc.systemsleep(0.01)
    end
end
nothing # hide
```

We may now analyze the loop function `run_almost_forever!` to verify that it does not allocate memory:
```@example HOT_LOOP
using AllocCheck, Test
allocs = check_allocs(run_almost_forever!, (Vector{Float64},));
@test isempty(allocs)
```


## More complicated initialization
In practice, a function may need to perform several distinct allocations upfront, including potentially allocating objects of potentially complicated types, like closures etc. In situations like this, the following pattern may be useful:
```julia
struct Workspace
    # All you need to run the hot loop, for example:
    cache1::Vector{Float64}
    cache2::Matrix{Float64}
end

function setup(max_iterations::Int = 100_000)
    # Allocate and initialize the workspace
    cache1 = zeros(max_iterations)
    cache2 = zeros(max_iterations, max_iterations)
    return Workspace(cache1, cache2)
end

function run!(workspace::Workspace)
    # The hot loop
    for i = eachindex(workspace.cache1)
        workspace.cache1[i] = my_important_calculation() # The allocated cache is modified in place
        ...
    end
end

function run()
    workspace = setup()
    run!(workspace)
end
```

Here, `workspace` is a custom struct designed to serve as a workspace for the hot loop, but it could also be realized as a simple tuple of all the allocated objects required for the computations. Note, the struct `Workspace` in this example was not marked as mutable. However, its contents, the two cache arrays, are. This means that the `run!` function may modify the contents of the cache arrays.

The benefit of breaking the function up into two parts which are called from a third, is that we may now create the workspace object individually, and use it to compute the type of the arguments to the `run!` function that we are interested in analyzing:
```julia
workspace = setup()
allocs = check_allocs(run!, (typeof(workspace),))
```