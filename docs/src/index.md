# AllocCheck

[AllocCheck.jl](https://github.com/JuliaComputing/AllocCheck.jl) is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl

AllocCheck operates on _functions_, trying to statically determine wether or not a function _may_ allocate memory, and if so, _where_ that allocation appears. This is different from measuring allocations using, e.g., `@time` or `@allocated`, which measures the allocations that _did_ happen during the execution of a function. 

## Getting started

The primary entry point to check allocations is the macro [`@check_allocs`](@ref) which is used to annotate a function definition that you'd like to enforce allocation checks for:
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
  err.allocs[1]
end
```

we see what type of object was allocated, and where in the code the allocation appeared.


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
