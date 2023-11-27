# AllocCheck

[AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl) is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl

AllocCheck operates on _functions_, trying to statically determine wether or not a function _may_ allocate memory, and if so, _where_ that allocation appears. This is different from measuring allocations using, e.g., `@time` or `@allocated`, which measures the allocations that _did_ happen during the execution of a function.

## Getting started

AllocCheck has two primary entry points
- [`check_allocs`](@ref)
- [`@check_allocs`](@ref)

The difference between them is subtle, but important in situations where you want to absolutely guarantee that the result of the static analysis holds at runtime.

Starting with **the macro** [`@check_allocs`](@ref), this is used to annotate a function definition that you'd like to enforce allocation checks for:
```@repl README
using AllocCheck
using Test # hide
@check_allocs mymod(x) = mod(x, 2.5)

mymod(1.5) # call automatically checked for allocations
```
This call happened without error, indicating that the function was proven to not allocate any memory after it starts 🎉


When used on a function that may allocate memory
```@repl README
@check_allocs linsolve(a, b) = a \ b

linsolve(rand(10,10), rand(10))
```
the function call raises an `AllocCheckFailure`.

The `errors` field allows us to inspect the individual errors to get some useful information. For example:

```@example README
try
  linsolve(rand(10,10), rand(10))
catch err
  err.errors[1]
end
```

we see what type of object was allocated, and where in the code the allocation appeared.

The **function** [`check_allocs`](@ref) is similar to the macro, but instead of passing or throwing an error, returns an array of informative objects indicating any presence of allocations, runtime dispatches, or allocating runtime calls:

```@example README
results = check_allocs(\, (Matrix{Float64}, Vector{Float64}))
length(results)
```
This called returned a long array of results, indicating that there are several potential allocations or runtime dispatches resulting form a function call with the specified signature. We have a look at how one of these elements look:

```@example README
results[1]
```

## The difference between `check_allocs` and `@check_allocs`
The function [`check_allocs`](@ref) performs analysis of a function call with the type signature specified in a very particular context, the state of the julia session at the time of the call to `check_allocs`. Code loaded after this analysis may invalidate the analysis, and any analysis performed in, for example, a test suite, may be invalid at runtime. Less obvious problems may appears as a result of the type-inference stage in the Julia compiler sometimes being sensitive to the order of code loading, making it possible for the inference result to differ between two subtly different Julia sessions. 

The macro [`@check_allocs`](@ref) on the other hand, performs the analysis _immediately prior_ to the execution of the analyzed function call, ensuring the validity of the analysis at the time of the call.

In safety-critical scenarios, this difference may be important, while in more casual scenarios, the difference may be safely ignored and whichever entry point is more convenient may be used.

### An example of invalidated analysis

In the example below we define a function and perform an analysis on it which indicates on issues. We then load additional code (which may be done by loading, e.g., a package) and perform the analysis again, which now indicates that issues have appeared.

```@example README
my_add(x, y) = x + y
check_allocs(my_add, (Int, Int))
```
As expected, no allocations are indicated. We now load additional code by defining a new method for this function
```@example README
my_add(x::Int, y) = BigInt(x) + y
length(check_allocs(my_add, (Int, Int)))
```
This time, several potential allocations are indicated. In this example, a method that was more specific for the analyzed signature was added, and this method may allocate memory.

### Functions that throw exceptions

Some functions that we do not expect may allocate memory, like `sin`, actually may:
```@example README
@allocated try sin(Inf) catch end
```

The reason for this is that `sin` needs to allocate if it **throws an error**.

By default, `@check_allocs` ignores all such allocations and assumes that no exceptions are thrown. If you care about detecting these allocations anyway, you can use `ignore_throw=false`:
```@example README
@check_allocs mysin1(x) = sin(x)
@check_allocs ignore_throw=false mysin2(x) = sin(x)

@test mysin1(1.5) == sin(1.5)
@test_throws AllocCheckFailure mysin2(1.5)
```

## Limitations

 Every call into a `@check_allocs` function behaves like a dynamic dispatch. This means that it can trigger compilation dynamically (involving lots of allocation), and even when the function has already been compiled, a small amount of allocation is still expected on function entry.

 For most applications, the solution is to use `@check_allocs` to wrap your top-level entry point or your main application loop, in which case those applications are only incurred once. `@check_allocs` will guarantee that no dynamic compilation or allocation occurs once your function has started running.
