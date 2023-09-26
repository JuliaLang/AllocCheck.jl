# AllocCheck.jl

<!-- [![Build Status](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml?query=branch%3Amain) -->

AllocCheck.jl is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl

#### Examples

```julia
julia> mymod(x) = mod(x, 2.5)

julia> length(check_allocs(mymod, (Float64,)))
0

julia> linsolve(a, b) = a \ b

julia> length(check_allocs(linsolve, (Matrix{Float64}, Vector{Float64})))
175
```

#### Known Limitations

 1. Error paths

   Allocations in error-throwing paths are not distinguished from other allocations:

```julia
julia> check_allocs(sin, (Float64,))[1]

Allocation of Float64 in ./special/trig.jl:28
  | @noinline sin_domain_error(x) = throw(DomainError(x, "sin(x) is only defined for finite x."))

Stacktrace:
 [1] sin_domain_error(x::Float64)
   @ Base.Math ./special/trig.jl:28
 [2] sin(x::Float64)
   @ Base.Math ./special/trig.jl:39
```
