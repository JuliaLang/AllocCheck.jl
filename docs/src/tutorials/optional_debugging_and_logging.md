# Optional debugging and logging

For debugging purposes, it may sometimes be beneficial to include logging statements in a function, for example
```@example DEBUGGING
function myfun(verbose::Bool)
    a = 0.0
    for i = 1:3
        a = a + i
        verbose && @info "a = $a"
    end
end
nothing # hide
```
Here, the printing of some relevant information is only performed if `verbose = true`. While the printing is optional, and not performed if `verbose = false`, [`check_allocs`](@ref) operates on _types rather than values_, i.e., `check_allocs` only knows that the argument is of type `Bool`, not that it may have the value `false`:
```@example DEBUGGING
using AllocCheck
check_allocs(myfun, (Bool,)) |> length
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

check_allocs(typed_myfun, (Val{false},)) |> length
```

The compiler, and thus also AllocCheck, now knows that the value of `verbose` is `false`, since this is encoded in the _type_ `Val{false}`. The compiler can use this knowledge to figure out that the `@info` statement won't be executed, and thus prove that the function will not allocate memory.

The user may still use this function with the debug print enabled by calling it like
```@example DEBUGGING
typed_myfun(Val{true}())
```


## Advanced: Constant propagation
Sometimes, the compiler is able to use _constant propagation_ to determine what path through a program will be taken based on the _value of constants_. We demonstrate this effect below, where the value `verbose = false` is hard-coded
```@example DEBUGGING
my_outer_function() = myfun(false) # Hard coded value false
check_allocs(my_outer_function, ()) |> length
```
When looking at `my_outer_function`, the compiler knows that `verbose = false` since this constant is hard coded into the program, and the compiler thus has the same amount of information here as when the value was lifted into the type domain. Constant propagation is considered a performance optimization that the compiler may or may not perform, and it is thus recommended to use the `Val` type to lift values into the type domain to guarantee that the compiler will use this information.