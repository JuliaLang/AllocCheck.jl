import LLVM, GPUCompiler
using GPUCompiler: NativeCompilerTarget

struct NativeParams <: GPUCompiler.AbstractCompilerParams end

DefaultCompilerTarget(; kwargs...) = NativeCompilerTarget(; jlruntime=true, kwargs...)

function llvm_codegen_level(opt_level::Integer)
    if opt_level < 2
        optlevel = LLVM.API.LLVMCodeGenLevelNone
    elseif opt_level == 2
        optlevel = LLVM.API.LLVMCodeGenLevelDefault
    else
        optlevel = LLVM.API.LLVMCodeGenLevelAggressive
    end
end

function cpu_name()
    ccall(:jl_get_cpu_name, String, ())
end

function cpu_features()
    return ccall(:jl_get_cpu_features, String, ())
end
