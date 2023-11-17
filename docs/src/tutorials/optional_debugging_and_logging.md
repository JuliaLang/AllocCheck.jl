# Optional debugging and logging

For debugging purposes, it may sometimes be beneficial to include logging statements in a function, for example
```@example DEBUGGING
using AllocCheck # hide
@check_allocs function myfun(verbose::Bool)
    a = 0.0
    for i = 1:3
        a = a + i
        verbose && @info "a = $a"
    end
end
nothing # hide
```
Here, the printing of some relevant information is only performed if `verbose = true`. While the printing is optional, and not performed if `verbose = false`, [`check_allocs`](@ref) operates on _types rather than values_, i.e., `check_allocs` only knows that the argument is of type `Bool`, not that it may have the value `false`:
```@repl DEBUGGING
myfun(false)
```
Indeed, this function was determined to potentially allocate memory.

To allow such optional features while still being able to prove that a function does not allocate if the allocating features are turned off, we may [lift the _value_ `true` into the _type domain_](https://docs.julialang.org/en/v1/manual/types/#%22Value-types%22), we do this by means of the `Val` type:
```@example DEBUGGING
function typed_myfun(::Val{verbose}) where verbose
    a = 0.0
    for i = 1:3
        a = a + i
        verbose && @info "a = $a"
    end
end

length(check_allocs(typed_myfun, (Val{false},)))
```

The compiler, and thus also AllocCheck, now knows that the value of `verbose` is `false`, since this is encoded in the _type_ `Val{false}`. The compiler can use this knowledge to figure out that the `@info` statement won't be executed, and thus prove that the function will not allocate memory.

The user may still use this function with the debug print enabled by calling it like
```@example DEBUGGING
typed_myfun(Val{true}())
```


## Advanced: Constant propagation

Sometimes, code written without this trick will still work just fine with AllocCheck.

That's because in some limited scenarios, the compiler is able to use _constant propagation_ to determine what path through a program will be taken based on the _value of constants_.

We demonstrate this effect below, where the value `verbose = false` is hard-coded into the function:
```@example DEBUGGING
@check_allocs function constant_myfun()
    verbose = false
    a = 0.0
    for i = 1:3
        a = a + i
        verbose && @info "a = $a"
    end
    return a
end

constant_myfun()
```

When looking at `constant_myfun`, the compiler knows that `verbose = false` since this constant is hard coded into the program. Sometimes, the compiler can even propagate constant values all the way into called functions.

This is useful, but it's not guaranteed to happen in general. The `Val{T}` trick described here ensures that the variable is propagated as a constant everywhere it is required.

