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
    if VERSION >= v"1.10.0-beta1"
        return ccall(:jl_get_cpu_features, String, ())
    end

    @static if Sys.ARCH == :x86_64 ||
               Sys.ARCH == :x86
        return "+mmx,+sse,+sse2,+fxsr,+cx8" # mandated by Julia
    else
        return ""
    end
end

if VERSION >= v"1.10-beta3"
    function build_newpm_pipeline!(pb::LLVM.PassBuilder, mpm::LLVM.NewPMModulePassManager, speedup=2, size=0, lower_intrinsics=true,
        dump_native=false, external_use=false, llvm_only=false,)
        ccall(:jl_build_newpm_pipeline, Cvoid,
            (LLVM.API.LLVMModulePassManagerRef, LLVM.API.LLVMPassBuilderRef, Cint, Cint, Cint, Cint, Cint, Cint),
            mpm, pb, speedup, size, lower_intrinsics, dump_native, external_use, llvm_only)
    end
else
    function build_oldpm_pipeline!(pm::LLVM.ModulePassManager, opt_level=2, lower_intrinsics=true)
        ccall(:jl_add_optimization_passes, Cvoid,
                    (LLVM.API.LLVMPassManagerRef, Cint, Cint),
                    pm, opt_level, lower_intrinsics)
    end
end
