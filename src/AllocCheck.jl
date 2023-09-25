module AllocCheck

using GPUCompiler
using GPUCompiler: safe_name
using LLVM
# Write your package code here.

include("allocfunc.jl")

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


function is_runtime_function(name)
    rx = r"ijl(.)"
    occursin(rx, name) && return true
    return false
end

# generate a pseudo-backtrace from LLVM IR instruction debug information
#
# this works by looking up the debug information of the instruction, and inspecting the call
# sites of the containing function. if there's only one, repeat the process from that call.
# finally, the debug information is converted to a Julia stack trace.
function backtrace_(inst::LLVM.Instruction, bt=StackTraces.StackFrame[]; compiled::Union{Nothing,Dict{Any,Any}}=nothing)
    done = Set{LLVM.Instruction}()
    while true
        if in(inst, done)
            break
        end
        push!(done, inst)
        f = LLVM.parent(LLVM.parent(inst))

        # look up the debug information from the current instruction
        if haskey(metadata(inst), LLVM.MD_dbg)
            loc = metadata(inst)[LLVM.MD_dbg]
            while loc !== nothing
                scope = LLVM.scope(loc)
                if scope !== nothing
                    emitted_name = LLVM.name(f)
                    name = replace(LLVM.name(scope), r";$" => "")
                    file = LLVM.file(scope)
                    path = joinpath(LLVM.directory(file), LLVM.filename(file))
                    line = LLVM.line(loc)
                    linfo = nothing
                    from_c = false
                    inlined = LLVM.inlined_at(loc) !== nothing
                    !inlined && for (mi, (; ci, func, specfunc)) in compiled
                        if safe_name(func) == emitted_name || safe_name(specfunc) == emitted_name
                            linfo = mi
                            break
                        end
                    end
                    push!(bt, StackTraces.StackFrame(Symbol(name), Symbol(path), line,
                        linfo, from_c, inlined, 0))
                end
                loc = LLVM.inlined_at(loc)
            end
        end

        # move up the call chain
        ## functions can be used as a *value* in eg. constant expressions, so filter those out
        callers = filter(val -> isa(user(val), LLVM.CallInst), collect(uses(f)))
        ## get rid of calls without debug info
        filter!(callers) do call
            md = metadata(user(call))
            haskey(md, LLVM.MD_dbg)
        end
        if !isempty(callers)
            # figure out the call sites of this instruction
            call_sites = unique(callers) do call
                # there could be multiple calls, originating from the same source location
                md = metadata(user(call))
                md[LLVM.MD_dbg]
            end

            if length(call_sites) > 1
                frame = StackTraces.StackFrame("multiple call sites", "unknown", 0)
                push!(bt, frame)
            elseif length(call_sites) == 1
                inst = user(first(call_sites))
                continue
            end
        end
        break
    end

    return bt
end

function build_newpm_pipeline!(pb::PassBuilder, mpm::NewPMModulePassManager, speedup=2, size=0, lower_intrinsic=true,
    dump_native=false, external_use=false, llvm_only=false,)
    ccall(:jl_build_newpm_pipeline, Cvoid, (LLVM.API.LLVMModulePassManagerRef, LLVM.API.LLVMPassBuilderRef, Cint, Cint, Cint, Cint, Cint, Cint),
        mpm, pb, speedup, size, lower_intrinsic, dump_native, external_use, llvm_only)
end

function optimize!(@nospecialize(job::CompilerJob), mod::LLVM.Module)
    triple = GPUCompiler.llvm_triple(job.config.target)
    tm = GPUCompiler.llvm_machine(job.config.target)
    @dispose pb = LLVM.PassBuilder(tm) begin
        @dispose mpm = LLVM.NewPMModulePassManager(pb) begin
            build_newpm_pipeline!(pb, mpm)
            run!(mpm, mod, tm)
        end
    end
end

struct AllocInstance
    inst::LLVM.CallInst
    backtrace::Vector{Base.StackTraces.StackFrame}
end

"""
check_ir(func, types; entry_abi=:specfunc, ret_mod=false)

Compiles the given function and types to LLVM IR and checks for allocations.
Returns a vector of `AllocInstance` structs, each containing a `CallInst` and a backtrace.

# Example
```jldoctest
julia> function foo(x::Int, y::Int)
           z = x + y
           return z
       end
foo (generic function with 1 method)

julia> types = (Int, Int)
(Int64, Int64)

julia> allocs = check_ir(foo, types)
AllocCheck.AllocInstance[]
```

"""
function check_ir(@nospecialize(func), @nospecialize(types); entry_abi=:specfunc, ret_mod=false)
    job = create_job(func, types; entry_abi)
    allocs = AllocInstance[]
    mod = JuliaContext() do ctx
        ir = GPUCompiler.compile(:llvm, job, validate=false)
        mod = ir[1]
        optimize!(job, mod)
        # display(mod)
        (; compiled) = ir[2]
        for f in functions(mod)
            for block in blocks(f)
                for inst in instructions(block)
                    if isa(inst, LLVM.CallInst)
                        rename_ir!(job, inst)
                        decl = called_operand(inst)
                        if is_alloc_function(name(decl))
                            typ = guess_julia_type(inst)
                            println("Allocation of Type: ", typ, " in ")
                            println(inst)
                            # Print backtrace
                            bt = backtrace_(inst; compiled)
                            # @assert length(bt) != 0
                            Base.show_backtrace(stdout, bt)
                            println()
                            push!(allocs, AllocInstance(inst, bt))
                        end
                    end
                end
            end
        end
        mod
    end

    ret_mod && return mod
    return allocs
end


export check_ir

end
