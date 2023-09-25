module AllocCheck

using GPUCompiler
using GPUCompiler: safe_name
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

# generate a pseudo-backtrace from LLVM IR instruction debug information
#
# this works by looking up the debug information of the instruction, and inspecting the call
# sites of the containing function. if there's only one, repeat the process from that call.
# finally, the debug information is converted to a Julia stack trace.
function backtrace(inst::LLVM.Instruction, bt = StackTraces.StackFrame[]; compiled::Union{Nothing,Dict{Any,Any}} = nothing)
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
                    name = replace(LLVM.name(scope), r";$"=>"")
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

function check_ir(@nospecialize(func), @nospecialize(types); strict=false, entry_abi=:specfunc)
    job = create_job(func, types; entry_abi)
    ir = JuliaContext() do ctx
        GPUCompiler.compile(:llvm, job, validate=false)
        # Implement checks ;)
    end
    mod = ir[1]
    # display(mod)
    (; compiled) = ir[2]
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

                        # Print backtrace
                        bt = backtrace(inst; compiled)
                        # @assert length(bt) != 0
                        Base.show_backtrace(stdout, bt)
                        println()

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
