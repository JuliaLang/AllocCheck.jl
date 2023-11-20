using AllocCheck
using Test

mutable struct Foo{T}
    val::T
end

function alloc_in_catch()
   try
       if Base.inferencebarrier(false)
           # Prevent catch from being elided
           error()
       end
   catch
       return Foo{Float64}(1.5) # in catch block: filtered by `ignore_throw=true`
   end
   return Foo{Int}(1)
end

function same_ccall()
    a = Array{Int}(undef,5,5)
    b = Array{Int}(undef,5,5)
    a,b
end

function throw_eof()
    throw(EOFError())
end

function toggle_gc()
    GC.enable(false)
    GC.enable(true)
end

function run_gc_explicitly()
    GC.gc()
end

@testset "Number of Allocations" begin
    @test length(check_allocs(mod, (Float64,Float64); ignore_throw=false)) == 0
    @test length(check_allocs(sin, (Float64,); ignore_throw=false)) > 0
    @test length(check_allocs(sin, (Float64,); ignore_throw=true)) == 0
    @test length(check_allocs(*, (Matrix{Float64},Matrix{Float64}); ignore_throw=true)) != 0

    @test length(check_allocs(alloc_in_catch, (); ignore_throw=false)) == 2
    @test length(check_allocs(alloc_in_catch, (); ignore_throw=true)) == 1

    @test length(check_allocs(same_ccall, (); ignore_throw=false)) > 0
    @test length(check_allocs(same_ccall, (); ignore_throw=true)) > 0

    @test length(check_allocs(first, (Core.SimpleVector,); ignore_throw = false)) > 0
    @test length(check_allocs(first, (Core.SimpleVector,); ignore_throw = true)) == 0

    @test length(check_allocs(time, (); ignore_throw = false)) == 0
    @test length(check_allocs(throw_eof, (); ignore_throw = false)) == 0
    @test length(check_allocs(toggle_gc, (); ignore_throw = false)) == 0
    @test length(check_allocs(run_gc_explicitly, (); ignore_throw = false)) == 0

    @test_throws MethodError check_allocs(sin, (String,); ignore_throw=false)
end

@testset "@check_allocs macro (syntax)" begin

    struct Bar
        val::Float64
    end

    # Standard function syntax
    @check_allocs function my_mod0()
        return 1.5
    end
    @check_allocs function my_mod1(x, y)
        return mod(x, y)
    end
    @check_allocs function my_mod2(x::Float64, y)
        return mod(x, y)
    end
    @check_allocs function my_mod3(::Float64, y)
        return y * y
    end
    @check_allocs function my_mod4(::Float64, y::Float64)
        return y * y
    end
    @check_allocs function (x::Bar)(y::Float64)
        return mod(x.val, y)
    end

    x,y = Base.rand(2)
    @test my_mod0() == 1.5
    @test my_mod1(x, y) == mod(x, y)
    @test my_mod2(x, y) == mod(x, y)
    @test my_mod3(x, y) == y * y
    @test my_mod4(x, y) == y * y
    @test Bar(x)(y) == mod(x, y)

    # Standard function syntax (w/ kwargs)
    @check_allocs function my_mod5(; offset=1.0)
        return 2 * offset
    end
    @check_allocs function my_mod6(x, y; offset=1.0)
        return mod(x, y) + offset
    end
    @check_allocs function my_mod7(x::Float64, y; offset)
        return mod(x, y) + offset
    end
    @check_allocs function (x::Bar)(y::Float64; a, b)
        return mod(x.val, y) + a + b
    end
    @check_allocs function (x::Bar)(y::Float32; a, b=1.0)
        return mod(x.val, y) + a + b
    end

    offset = Base.rand()
    a,b = Base.rand(2)
    @test my_mod5(; offset) == 2 * offset
    @test my_mod5() == 2.0
    @test my_mod6(x, y; offset) == mod(x, y) + offset
    @test my_mod6(x, y) == mod(x, y) + 1.0
    @test my_mod7(x, y; offset) == mod(x, y) + offset
    @test Bar(x)(y; a, b) == mod(x, y) + a + b
    @test Bar(x)(y; b, a) == mod(x, y) + a + b
    @test Bar(x)(Float32(y); b, a) == mod(x, Float32(y)) + a + b
    @test Bar(x)(Float32(y); a) == mod(x, Float32(y)) + a + 1.0

    # (x,y) -> x*y
    f0 = @check_allocs () -> 1.5
    @test f0() == 1.5
    f1 = @check_allocs (x,y) -> x * y
    @test f1(x, y) == x * y
    f2 = @check_allocs (x::Int,y::Float64) -> x * y
    @test f2(3, y) == 3 * y
    f3 = @check_allocs (::Int,y::Float64) -> y * y
    @test f3(1, y) == y * y

    # foo(x) = x^2
    @check_allocs mysum0() = 1.5
    @test mysum0() == 1.5
    @check_allocs mysum1(x, y) = x + y
    @test mysum1(x, y) == x + y
    @check_allocs mysum2(x::Float64, y::Float64) = x + y
    @test mysum2(x, y) == x + y
    @check_allocs (x::Bar)(y::Bar) = x.val + y.val
    @test Bar(x)(Bar(y)) == x + y
end


@testset "@check_allocs macro (behavior)" begin

    # The check should raise errors only for problematic argument types
    @check_allocs mymul(x,y) = x * y
    @test mymul(1.5, 2.5) == 1.5 * 2.5
    @test_throws AllocCheckFailure mymul(rand(10,10), rand(10,10))

    # If provided, ignore_throw=false should include allocations that
    # happen only on error paths
    @check_allocs ignore_throw=false alloc_on_throw1(cond) =
        (cond && (error("This exception allocates");); return 1.5)
    @test_throws AllocCheckFailure alloc_on_throw1(false)
    @check_allocs ignore_throw=true alloc_on_throw2(cond) =
        (cond && (error("This exception allocates");); return 1.5)
    @test alloc_on_throw2(false) === 1.5
end

if VERSION > v"1.11.0-DEV.753"
memory_alloc() = Memory{Int}(undef, 10)
end

@testset "Types of Allocations" begin
    if VERSION > v"1.11.0-DEV.753"
        @test any(x.type == Memory{Int} for x in check_allocs(memory_alloc, (); ignore_throw = false))
        @test any(x.type == Memory for x in check_allocs(()->copy(Memory{Int}(undef, 10)),()))

        # TODO: Add support jl_genericmemory_copy_slice
        # @test any(x.type == Memory for x in check_allocs((x)->copy(x),(Vector{Int}),))
    end

    @test any(alloc.type == Base.RefValue{Int} for alloc in check_allocs(()->Ref{Int}(), ()))

    allocs1 = check_allocs(()->Ref{Vector{Int64}}(Int64[]), ())
    @test any(alloc.type == Base.RefValue{Vector{Int64}} for alloc in allocs1)
    @test any(alloc.type == Vector{Int64} for alloc in allocs1)
end

@testset "Error types" begin

    # All error types should support Base.show()
    iob = IOBuffer()
    alloc_with_no_bt = AllocCheck.AllocationSite(Float32, Base.StackTraces.StackFrame[])
    show(iob, alloc_with_no_bt)
    @test occursin("unknown location", String(take!(iob)))

    alloc_with_bt = AllocCheck.AllocationSite(Float32, Base.stacktrace())
    show(iob, alloc_with_bt) === nothing
    @test !occursin("unknown location", String(take!(iob)))

    call_with_no_bt = AllocCheck.AllocatingRuntimeCall("jl_subtype", Base.StackTraces.StackFrame[])
    show(iob, call_with_no_bt)
    @test occursin("unknown location", String(take!(iob)))

    call_with_bt = AllocCheck.AllocatingRuntimeCall("jl_subtype", Base.stacktrace())
    show(iob, call_with_bt) === nothing
    @test !occursin("unknown location", String(take!(iob)))

    dispatch_with_no_bt_nothing = AllocCheck.DynamicDispatch(Base.StackTraces.StackFrame[], nothing)
    show(iob, dispatch_with_no_bt_nothing)
    @test occursin("unknown location", String(take!(iob)))

    dispatch_with_no_bt_foo = AllocCheck.DynamicDispatch(Base.StackTraces.StackFrame[], :foo)
    show(iob, dispatch_with_no_bt_foo)
    @test occursin("to function foo", String(take!(iob)))

    dispatch_with_bt_nothing = AllocCheck.DynamicDispatch(Base.stacktrace(), nothing)
    show(iob, dispatch_with_bt_nothing) === nothing
    @test !occursin("unknown location", String(take!(iob)))

    dispatch_with_bt_foo = AllocCheck.DynamicDispatch(Base.stacktrace(), :foo)
    show(iob, dispatch_with_bt_foo) === nothing
    @test !occursin("unknown location", String(take!(iob)))

    # All error types should implement the required Base.:(==) and Base.hash for uniquing
    uniqued = unique([
        alloc_with_no_bt, alloc_with_bt, call_with_no_bt, call_with_bt,
        dispatch_with_no_bt_nothing, dispatch_with_bt_nothing,
        dispatch_with_no_bt_foo, dispatch_with_bt_foo,
        alloc_with_no_bt, alloc_with_bt, call_with_no_bt, call_with_bt,
        dispatch_with_no_bt_nothing, dispatch_with_bt_nothing,
        dispatch_with_no_bt_foo, dispatch_with_bt_foo,
    ])

    @test uniqued == [
        alloc_with_no_bt, alloc_with_bt, call_with_no_bt, call_with_bt,
        dispatch_with_no_bt_nothing, dispatch_with_bt_nothing,
        dispatch_with_no_bt_foo, dispatch_with_bt_foo,
    ]
end

@testset "repeated allocations" begin
    send_control(u) = sum(abs2, u) # Dummy control function
    calc_control() = 1.0
    get_measurement() = [1.0]

    function example_loop(data, t_start, y_start, y_old, ydf, Ts, N, r)
        for i = 1:N
            t = time() - t_start
            y = get_measurement()[] - y_start # Subtract initial position for a smoother experience
            yd = (y - y_old) / Ts
            ydf = 0.9*ydf + 0.1*yd
            # r = 45sin(2π*freq*t)
            u = calc_control()
            send_control([u])
            log = [t, y, ydf, u, r(t)]
            data[:, i] .= log
            y_old = y
        end
    end

    ## Generate some example input data
    r = t->(2 + 2floor(t/4)^2)
    N = 10
    data = Matrix{Float64}(undef, 5, N)
    t_start = 1.0
    y_start = 0.0
    y_old = 0.0
    ydf = 0.0
    Ts = 1.0

    typetuple = typeof.((data, t_start, y_start, y_old, ydf, Ts, N, r))
    @test allunique(check_allocs(example_loop, typetuple, ignore_throw=true))
    foobar() = stacktrace()
    stack1 = foobar()
    stack2 = stacktrace()
    allocs = [AllocCheck.AllocationSite(Any,stack1), AllocCheck.AllocationSite(Any,stack2), AllocCheck.AllocationSite(Any,stack1)]
    @test !allunique(allocs)
    @test length(unique(allocs)) == 2
end
