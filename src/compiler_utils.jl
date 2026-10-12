import LLVM, GPUCompiler
using GPUCompiler: NativeCompilerTarget

# `ignore_throw` is part of the compiler configuration (rather than only a keyword to the
# analysis) so that cached analysis results are keyed by it.
struct NativeParams <: GPUCompiler.AbstractCompilerParams
    ignore_throw::Bool
end
NativeParams() = NativeParams(true)

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
