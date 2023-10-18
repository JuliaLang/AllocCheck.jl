# AllocCheck

[AllocCheck.jl](https://github.com/JuliaComputing/AllocCheck.jl) is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl

AllocCheck operates on _functions_, trying to statically determine wether or not a function _may_ allocate memory, and if so, _where_ that allocation appears. This is different from measuring allocations using, e.g., `@time` or `@allocated`, which measures the allocations that _did_ happen during the execution of a function. 

## Getting started

The main entry point to check allocations is the function [`check_allocs`](@ref), which takes the function to check as the first argument, and a tuple of argument types as the second argument:
```@example README
using AllocCheck
mymod(x) = mod(x, 2.5)

check_allocs(mymod, (Float64,))
```
This returned an empty array, indicating that the function was proven to not allocate any memory 🎉


When used on a function that may allocate memory
```@example README
linsolve(a, b) = a \ b

allocs = check_allocs(linsolve, (Matrix{Float64}, Vector{Float64}));
length(allocs)
```
we get a non-empty array of allocation instances. Each allocation instance contains some useful information, for example

```@example README
allocs[1]
```

we see what type of object was allocated, and where in the code the allocation appeared.


### Functions that throw exceptions
Some functions that we do not expect may allocate memory, like `sin`, actually may:
```@example README
length(check_allocs(sin, (Float64,)))
```
The reason for this is that `sin` may **throw an error**, and the exception object requires some allocations. We can ignore allocations that only happen when throwing errors by passing `ignore_throw=true`:

```@example README
length(check_allocs(sin, (Float64,); ignore_throw=true)) # ignore allocations that only happen when throwing errors
```

## Limitations

 1. Runtime dispatch
   Any runtime dispatch is conservatively assumed to allocate.