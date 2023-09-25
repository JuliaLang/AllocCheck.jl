using AllocCheck
using Test

@testset "AllocCheck.jl" begin
    @test length(check_ir(mod, (Float64,Float64))) == 0
    @test length(check_ir(sin, (Float64,))) != 0 # TODO: implement detection allocations for errors
    @test length(check_ir(*, (Matrix{Float64},Matrix{Float64}))) != 0
end
