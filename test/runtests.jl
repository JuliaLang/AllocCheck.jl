using AllocCheck
using Test

function alloc_in_catch()
   try
       Base.inferencebarrier(nothing) # Prevent catch from being elided
   catch
       return Any[] # in catch block: filtered by `ignore_throw=true`
   end
   return Int64[]
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

    @test length(check_allocs(same_ccall, (); ignore_throw=false)) == 2
    @test length(check_allocs(same_ccall, (); ignore_throw=true)) == 2

    @test length(check_allocs(first, (Core.SimpleVector,); ignore_throw = false)) > 0
    @test length(check_allocs(first, (Core.SimpleVector,); ignore_throw = true)) == 0

    @test length(check_allocs(time, (); ignore_throw = false)) == 0
    @test length(check_allocs(throw_eof, (); ignore_throw = false)) == 0
    @test length(check_allocs(toggle_gc, (); ignore_throw = false)) == 0
    @test length(check_allocs(run_gc_explicitly, (); ignore_throw = false)) == 0

    @test_throws MethodError check_allocs(sin, (String,); ignore_throw=false)
end

if VERSION > v"1.11.0-DEV.753"
memory_alloc() = Memory{Int}(undef, 10)
end

@testset "Types of Allocations" begin
    if VERSION > v"1.11.0-DEV.753"
    @test alloc_type(check_allocs(memory_alloc, (); ignore_throw = false)[1]) == Memory{Int}
    end
end