# AllocCheck.jl

<!-- [![Build Status](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml?query=branch%3Amain) -->

[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliacomputing.github.io/AllocCheck.jl/dev/)

[AllocCheck.jl](https://github.com/JuliaComputing/AllocCheck.jl) is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl

AllocCheck operates on _functions_, trying to statically determine wether or not a function _may_ allocate memory, and if so, _where_ that allocation appears. This is different from measuring allocations using, e.g., `@time` or `@allocated`, which measures the allocations that _did_ happen during the execution of a function.

## Getting started

The primary entry point to check allocations is the macro [`@check_allocs`](@ref) which is used to annotate a function definition that you'd like to enforce allocation checks for:
```julia
julia> using AllocCheck

julia> @check_allocs multiply(x,y) = x * y
multiply (generic function with 1 method)

julia> multiply(1.5, 2.5) # call automatically checked for allocations
3.75

julia> multiply(rand(3,3), rand(3,3)) # result matrix requires an allocation
ERROR: @check_alloc function encountered 1 errors (1 allocations / 0 dynamic dispatches).
```

The `multiply(::Float64, ::Float64)` call happened without error, indicating that the function was proven not to allocate. On the other hand, the `multiply(::Matrix{Float64}, ::Matrix{Float64})` call raised an `AllocCheckFailure` due to one internal allocation.

The `errors` field can be used to inspect the individual errors:
```julia
julia> try multiply(rand(3,3), rand(3,3)) catch err err.errors[1] end
Allocation of Matrix{Float64} in ./boot.jl:477
  | Array{T,2}(::UndefInitializer, m::Int, n::Int) where {T} =

Stacktrace:
 [1] Array
   @ ./boot.jl:477 [inlined]
 [2] Array
   @ ./boot.jl:485 [inlined]
 [3] similar
   @ ./array.jl:418 [inlined]
 [4] *(A::Matrix{Float64}, B::Matrix{Float64})
   @ LinearAlgebra ~/.julia/juliaup/julia-1.10.0-rc1+0.x64.linux.gnu/share/julia/stdlib/v1.10/LinearAlgebra/src/matmul.jl:113
 [5] var"##multiply#235"(x::Matrix{Float64}, y::Matrix{Float64})
   @ Main ./REPL[13]:1
```

### Functions that throw exceptions

Some functions that we do not expect may allocate memory, like `sin`, actually may:
```julia
julia> @allocated try sin(Inf) catch end
48
```

The reason for this is that `sin` needs to allocate if it **throws an error**.

By default, `@check_allocs` ignores all such allocations and assumes that no exceptions are thrown. If you care about detecting these allocations anyway, you can use `ignore_throw=false`:
```julia
julia> @check_allocs mysin1(x) = sin(x)

julia> @check_allocs ignore_throw=false mysin2(x) = sin(x)

julia> mysin1(1.5)
0.9974949866040544

julia> mysin2(1.5)
ERROR: @check_alloc function encountered 2 errors (1 allocations / 1 dynamic dispatches).
```

#### Limitations

 Every call into a `@check_allocs` function behaves like a dynamic dispatch. This means that it can trigger compilation dynamically (involving lots of allocation), and even when the function has already been compiled, a small amount of allocation is still expected on function entry.

 For most applications, the solution is to use `@check_allocs` to wrap your top-level entry point or your main application loop, in which case those applications are only incurred once. `@check_allocs` will guarantee that no dynamic compilation or allocation occurs once your function has started running.
