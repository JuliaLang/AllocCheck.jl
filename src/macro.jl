using ExprTools: splitdef, combinedef
using MacroTools: splitarg, combinearg

_is_func_def(ex) = Meta.isexpr(ex, :function) || Base.is_short_function_def(ex) || Meta.isexpr(ex, :->)
_is_call(ex) = Meta.isexpr(ex, :call)

function extract_keywords(ex0)
    kws = Dict{Symbol, Any}()
    arg = ex0[end]
    for i in 1:length(ex0)-1
        x = ex0[i]
        if x isa Expr && x.head === :(=) # Keyword given of the form "foo=bar"
            if length(x.args) != 2
               error("Invalid keyword argument: $x")
            end
            if x.args[1] != :ignore_throw || !(x.args[2] isa Bool)
                return error("@check_allocs received unexpected argument: $(x)")
            end
            kws[x.args[1]] = x.args[2]
        else
            return error("@check_allocs expects only one non-keyword argument")
        end
    end
    return kws, arg
end

"""
    @check_allocs ignore_throw=true (function def)

Wraps the provided function definition so that all calls to it will be automatically
checked for allocations.

If the check fails, an `AllocCheckFailure` exception is thrown containing the detailed
failures, including the backtrace for each defect.

Note: All calls to the wrapped function are effectively a dynamic dispatch, which
means they are type-unstable and may allocate memory at function _entry_. `@check_allocs`
only guarantees the absence of allocations after the function has started running.

# Example
```jldoctest
julia> @check_allocs multiply(x,y) = x*y
multiply (generic function with 1 method)

julia> multiply(1.5, 3.5) # no allocations for Float64
5.25

julia> multiply(rand(3,3), rand(3,3)) # matmul needs to allocate the result
ERROR: @check_alloc function contains 1 allocations.

Stacktrace:
 [1] macro expansion
   @ ~/repos/AllocCheck/src/macro.jl:134 [inlined]
 [2] multiply(x::Matrix{Float64}, y::Matrix{Float64})
   @ Main ./REPL[2]:133
 [3] top-level scope
   @ REPL[5]:1
```
"""
macro check_allocs(ex...)
    kws, body = extract_keywords(ex)
    if _is_func_def(body)
        return _check_allocs_macro(body, __module__, __source__; kws...)
    else
        error("@check_allocs used on something other than a function definition")
    end
end

function normalize_args!(func_def)
    name = get(func_def, :name, :(__anon))
    if haskey(func_def, :name)
        # e.g. function (f::Foo)(a::Int, b::Int)
        func_def[:name] isa Expr && (pushfirst!(func_def[:args], name);)
        func_def[:name] = gensym(name isa Symbol ? name : gensym())
    end
    if haskey(func_def, :kwargs)
        if !haskey(func_def, :args)
            func_def[:args] = Any[]
        end
        for arg in func_def[:kwargs]
            Meta.isexpr(arg, :kw) && (arg = arg.args[1];)
            push!(func_def[:args], arg)
        end
        empty!(func_def[:kwargs])
    end
end

"""
Takes a function definition and returns the expressions needed to forward the arguments to an inner function.

For example `function foo(a, ::Int, c...; x, y=1, z...)` will
1. modify the function to `gensym()` nameless arguments
2. return `(:a, gensym(), :(c...)), (:x, :y, :(z...)))`
"""
function forward_args!(func_def)
    args = []
    if haskey(func_def, :name) && func_def[:name] isa Expr
        name, type, splat, default = splitarg(func_def[:name])
        name = something(name, gensym())
        push!(args, splat ? :($name...) : name)
        func_def[:name] = combinearg(name, type, splat, default)
    end
    if haskey(func_def, :args)
        func_def[:args] = map(func_def[:args]) do arg
            name, type, splat, default = splitarg(arg)
            name = something(name, gensym())
            push!(args, splat ? :($name...) : name)
            combinearg(name, type, splat, default)
        end
    end
    kwargs = []
    if haskey(func_def, :kwargs)
        for arg in func_def[:kwargs]
            name, type, splat, default = splitarg(arg)
            push!(kwargs, splat ? :($name...) : name)
        end
    end
    args, kwargs
end

function _check_allocs_macro(ex::Expr, mod::Module, source::LineNumberNode; ignore_throw=true)

    # Transform original function to a renamed version with flattened args
    def = splitdef(deepcopy(ex))
    normalize_args!(def)
    original_fn = combinedef(def)
    f_sym = haskey(def, :name) ? gensym(def[:name]) : gensym()

    # Next, create a wrapper function that will compile the original function on-the-fly.
    def = splitdef(ex)
    fwd_args, fwd_kwargs = forward_args!(def)
    haskey(def, :name) && (def[:name] = esc(def[:name]);)
    haskey(def, :args) && (def[:args] = esc.(def[:args]);)
    haskey(def, :kwargs) && (def[:kwargs] = esc.(def[:kwargs]);)
    haskey(def, :whereparams) && (def[:whereparams] = esc.(def[:whereparams]);)

    # The way that `compile_callable` works is by doing a dynamic dispatch and
    # on-the-fly compilation.
    def[:body] = quote
        callable_tt = Tuple{map(Core.Typeof, ($(esc.(fwd_args)...),$(esc.(fwd_kwargs)...)))...}
        callable = $compile_callable($f_sym, callable_tt; ignore_throw=$ignore_throw)
        if (length(callable.analysis) > 0)
            throw(AllocCheckFailure(callable.analysis))
        end
        callable($(esc.(fwd_args)...), $(esc.(fwd_kwargs)...))
    end

    # Replace function definition line number node with that from source
    @assert def[:body].args[1] isa LineNumberNode
    def[:body].args[1] = source

    wrapper_fn = combinedef(def)
    return quote
        local $f_sym = $(esc(original_fn))
        $(wrapper_fn)
    end
end

"""
    @check_allocs_call ignore_throw=true (function call)

Calls `check_allocs(func, types; ignore_throw)` where `types` is a tuple of the types of the arguments
passed to `func` in the function call expression that `@check_allocs_call` is applied to.
For example, `@check_allocs_call 1 + 2.0` is equivalent to `check_allocs(+, (Int, Float64))`.
"""
macro check_allocs_call(ex...)
    kws, body = extract_keywords(ex)
    if _is_call(body)
        return _check_allocs_call_macro(body, __module__, __source__; kws...)
    else
        error("@check_allocs_call used on something other than a function call")
    end
end

function _check_allocs_call_macro(ex::Expr, mod::Module, source::LineNumberNode; ignore_throw=true)
    func = ex.args[1]
    args = ex.args[2:end]

    quote
        types = map(typeof, ($(esc.(args)...),))
        check_allocs($(esc(func)), types; ignore_throw = $ignore_throw)
    end
end
