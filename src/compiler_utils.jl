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

mutable struct PipelineConfig
    Speedup::Cint
    Size::Cint
    lower_intrinsics::Cint
    dump_native::Cint
    external_use::Cint
    llvm_only::Cint
    always_inline::Cint
    enable_early_simplifications::Cint
    enable_early_optimizations::Cint
    enable_scalar_optimizations::Cint
    enable_loop_optimizations::Cint
    enable_vector_pipeline::Cint
    remove_ni::Cint
    cleanup::Cint
end

if VERSION >= v"1.11-alpha1"
    function build_newpm_pipeline!(
        pb::LLVM.PassBuilder,
        mpm::LLVM.NewPMModulePassManager,
        speedup=2,
        size=0,
        lower_intrinsics=true,
        dump_native=false,
        external_use=false,
        llvm_only=false,
        always_inline=true,
        enable_early_simplifications=true,
        enable_early_optimizations=true,
        enable_scalar_optimizations=true,
        enable_loop_optimizations=true,
        enable_vector_pipeline=true,
        remove_ni=true,
        cleanup=false # note: modified vs. base
    )
        cfg = PipelineConfig(
            speedup,
            size,
            lower_intrinsics,
            dump_native,
            external_use,
            llvm_only,
            always_inline,
            enable_early_simplifications,
            enable_early_optimizations,
            enable_scalar_optimizations,
            enable_loop_optimizations,
            enable_vector_pipeline,
            remove_ni,
            cleanup,
        )
        ccall(:jl_build_newpm_pipeline, Cvoid,
            (LLVM.API.LLVMModulePassManagerRef, LLVM.API.LLVMPassBuilderRef, Ref{PipelineConfig}),
            mpm, pb, cfg
        )
    end
elseif VERSION >= v"1.10-beta3"
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
