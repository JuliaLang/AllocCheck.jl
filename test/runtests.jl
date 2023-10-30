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

@testset "AllocCheck.jl" begin
    @test length(check_allocs(mod, (Float64,Float64))) == 0
    @test length(check_allocs(sin, (Float64,); ignore_throw=false)) > 0
    @test length(check_allocs(sin, (Float64,); ignore_throw=true)) == 0
    @test length(check_allocs(*, (Matrix{Float64},Matrix{Float64}))) != 0

    @test length(check_allocs(alloc_in_catch, (); ignore_throw=false)) == 2
    @test length(check_allocs(alloc_in_catch, (); ignore_throw=true)) == 1

    @test length(check_allocs(same_ccall, (), ignore_throw=false)) == 2
    @test length(check_allocs(same_ccall, (), ignore_throw=true)) == 2

    @test length(check_allocs(first, (Core.SimpleVector,); ignore_throw = false)) == 3
    @test length(check_allocs(first, (Core.SimpleVector,); ignore_throw = true)) == 0
    @test length(check_allocs(time, ())) == 0
    @test length(check_allocs(throw_eof, ())) == 0
end
