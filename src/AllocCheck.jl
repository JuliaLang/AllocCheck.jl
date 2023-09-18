module AllocCheck

using GPUCompiler
using LLVM
# Write your package code here.

module Runtime end

struct NativeParams <: GPUCompiler.AbstractCompilerParams end

DefaultCompilerTarget(; kwargs...) = GPUCompiler.NativeCompilerTarget(; jlruntime=true, kwargs...)

const NativeCompilerJob = CompilerJob{NativeCompilerTarget,NativeParams}
GPUCompiler.can_safepoint(@nospecialize(job::NativeCompilerJob)) = true
GPUCompiler.runtime_module(::NativeCompilerJob) = Runtime
runtime_slug(job::NativeCompilerJob) = "native_$(job.config.target.cpu)-$(hash(job.config.target.features))$(job.config.target.jlruntime ? "-jlrt" : "")"
uses_julia_runtime(job::NativeCompilerJob) = job.config.target.jlruntime

function create_job(@nospecialize(func), @nospecialize(types); entry_abi=:specfunc)
    source = methodinstance(Base._stable_typeof(func), Base.to_tuple_type(types))
    target = DefaultCompilerTarget()
    config = CompilerConfig(target, NativeParams(); kernel=false, entry_abi, always_inline=false)
    CompilerJob(source, config)
end

const alloc_funcs = ["ijl_gc_pool_alloc", "ijl_gc_big_alloc"]

function is_alloc_function(name)
    name in alloc_funcs && return true
    rx = r"ijl_box_(.)"
    occursin(rx, name) && return true
    rx2 = r"ijl_apply_generic" # Dynamic Dispatch
    occursin(rx2, name) && return true
    return false
end

function is_runtime_function(name)
    rx = r"ijl(.)"
    occursin(rx, name) && return true
    return false
end

function check_ir(@nospecialize(func), @nospecialize(types); strict=false, entry_abi=:specfunc)
    job = create_job(func, types; entry_abi)
    ir = JuliaContext() do ctx
        GPUCompiler.compile(:llvm, job, validate=false)
        # Implement checks ;)
    end
    mod = ir[1]
    for f in functions(mod)
        for block in blocks(f)
            for inst in instructions(block)
                if isa(inst, LLVM.CallInst)
                    decl = called_operand(inst)
                    if is_alloc_function(name(decl)) || strict && is_runtime_function(name(decl))
                        diloc = metadata(inst)[LLVM.MD_dbg]::LLVM.DILocation
                        discope = LLVM.scope(diloc)
                        difile = LLVM.file(discope) #TODO: Print nice debug
                        println("Found Allocation EXTERMINATE!")
                        println(inst)
                        return inst, mod
                    end
                end
            end
        end
    end
    return nothing
end


export check_ir

end
