# AllocCheck.jl

<!-- [![Build Status](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml?query=branch%3Amain) -->

[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliacomputing.github.io/AllocCheck.jl/dev/)

AllocCheck.jl is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl

#### Examples

```julia
julia> mymod(x) = mod(x, 2.5)

julia> length(check_allocs(mymod, (Float64,)))
0

julia> linsolve(a, b) = a \ b

julia> length(check_allocs(linsolve, (Matrix{Float64}, Vector{Float64})))
175

julia> length(check_allocs(sin, (Float64,)))
2

julia> length(check_allocs(sin, (Float64,); ignore_throw=true)) # ignore allocations that only happen when throwing errors
0
```

#### Limitations

 Every call into a `@check_allocs` function behaves like a dynamic dispatch. This means that it can trigger compilation dynamically (involving lots of allocation), and even when the function has already been compiled, a small amount of allocation is still expected on function entry.

 For most applications, the solution is to use `@check_allocs` to wrap your top-level entry point or your main application loop, in which case those applications are only incurred once. `@check_allocs` will guarantee that no dynamic compilation or allocation occurs once your function has started running.
