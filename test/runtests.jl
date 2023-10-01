using AllocCheck
using Test

function alloc_in_catch()
   try
   catch
       return Any[] # in catch block: filtered by `ignore_throw=true`
   end
   return Int64[]
end

@testset "AllocCheck.jl" begin
    @test length(check_allocs(mod, (Float64,Float64))) == 0
    @test length(check_allocs(sin, (Float64,); ignore_throw=false)) > 0
    @test length(check_allocs(sin, (Float64,); ignore_throw=true)) == 0
    @test length(check_allocs(*, (Matrix{Float64},Matrix{Float64}))) != 0

    @test length(check_allocs(alloc_in_catch, (); ignore_throw=false)) == 2
    @test length(check_allocs(alloc_in_catch, (); ignore_throw=true)) == 1
end
