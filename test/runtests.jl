using AllocCheck
using Test

@testset "AllocCheck.jl" begin
    check_ir(sin, (Float64,)) # This should pass 
end
