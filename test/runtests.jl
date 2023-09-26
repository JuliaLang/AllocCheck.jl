using AllocCheck
using Test

@testset "AllocCheck.jl" begin
    @test length(check_allocs(mod, (Float64,Float64))) == 0
    @test length(check_allocs(sin, (Float64,))) != 0 # TODO: implement detection allocations for errors
    @test length(check_allocs(*, (Matrix{Float64},Matrix{Float64}))) != 0
end
