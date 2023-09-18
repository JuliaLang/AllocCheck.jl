using AllocCheck
using Test

@testset "AllocCheck.jl" begin
    @test check_ir(mod, (Float64,Float64)) === nothing
    @test check_ir(sin, (Float64,)) !== nothing
    @test check_ir(mod, (Float64,Float64), strict=true) === nothing
end
