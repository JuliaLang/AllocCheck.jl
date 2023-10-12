module AllocCheck

using GPUCompiler
using GPUCompiler: safe_name
using LLVM
# Write your package code here.

include("allocfunc.jl")
include("utils.jl")

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

function Base.show(io::IO, alloc::AllocInstance)
    typ = guess_julia_type(alloc.inst)

    if length(alloc.backtrace) == 0
        Base.println(io, "Allocation of ", typ, " in ")
        Base.println(io, alloc.inst)
    else
        Base.println(io, "Allocation of ", typ, " in ", alloc.backtrace[1].file, ":", alloc.backtrace[1].line)

        # Print code excerpt of allocation site
        try
            source = open(fixup_source_path(alloc.backtrace[1].file))
            Base.print(io, "  | ")
            Base.println(io, strip(readlines(source)[alloc.backtrace[1].line]))
            close(source)
        catch
            Base.print(io, "  | (source not available)")
        end

        # Print backtrace
        Base.show_backtrace(io, alloc.backtrace)
        Base.println(io)
    end
end

function rename_calls_and_throws!(f::LLVM.Function, job)

    # In order to detect whether an instruction executes only when
    # throwing an error, we re-write all throw/catches to pass through
    # the same basic block and then we check whether the instruction
    # is (post-)dominated by this "any_throw" / "any_catch" basic block.
    #
    # The goal is to check whether an inst always flows into some _some_
    # throw (or from some catch), rather than looking for a specific
    # throw/catch that the instruction always flows into.
    any_throw = BasicBlock(f, "any_throw")
    any_catch = BasicBlock(f, "any_catch")

    builder = IRBuilder()

    position!(builder, any_throw)
    throw_ret = ret!(builder)                                # Dummy inst for post-dominance test

    position!(builder, any_catch)
    undef_i32 = UndefValue(LLVM.Int32Type())
    catch_switch = switch!(builder, undef_i32, any_catch, 0) # Dummy inst for dominance test

    for block in blocks(f)
        for inst in instructions(block)
            if isa(inst, LLVM.CallInst)
                rename_ir!(job, inst)
                decl = called_operand(inst)

                # `throw`: Add pseudo-edge to any_throw
                if name(decl) == "ijl_throw" || name(decl) == "llvm.trap"
                    position!(builder, block)
                    brinst = br!(builder, any_throw)
                end

                # `catch`: Add pseudo-edge from any_catch
                if name(decl) == "__sigsetjmp" || name(decl) == "sigsetjmp"
                    icmp_ = user(only(uses(inst))) # Asserts one usage
                    @assert icmp_ isa LLVM.ICmpInst
                    br_ = user(only(uses(icmp_)))  # Asserts one usage
                    @assert br_ isa LLVM.BrInst

                    # Rewrite the jump to this `catch` block as an indirect jump
                    # from a common `any_catch` block
                    _, catch_target = successors(br_)
                    successors(br_)[2] = any_catch
                    branch_index = ConstantInt(length(successors(catch_switch)))
                    LLVM.API.LLVMAddCase(catch_switch, branch_index, catch_target)
                end
            elseif isa(inst, LLVM.UnreachableInst)

                # By assuming forward-progress, we know that any code post-dominated
                # by an `unreachable` must either be dead or contain a statically-known
                # throw().
                #
                # This can be useful in, e.g., cases where Julia codegen knows that a
                # dynamic dispatch is must-throw but the LLVM IR does not otherwise
                # reflect this information.
                position!(builder, block)
                brinst = br!(builder, any_throw)
            end
        end
    end
    dispose(builder)

    # Return the "any_throw" and "any_catch" instructions so that they
    # can be used for (post-)dominance tests.
    return throw_ret, catch_switch
end

"""
check_allocs(func, types; entry_abi=:specfunc, ret_mod=false)

Compiles the given function and types to LLVM IR and checks for allocations.
Returns a vector of `AllocInstance` structs, each containing a `CallInst` and a backtrace.

# Example
```jldoctest
julia> function foo(x::Int, y::Int)
           z = x + y
           return z
       end
foo (generic function with 1 method)

julia> allocs = check_allocs(foo, (Int, Int))
AllocCheck.AllocInstance[]
```

"""
function check_allocs(@nospecialize(func), @nospecialize(types); entry_abi=:specfunc, ret_mod=false, ignore_throw=false)
    job = create_job(func, types; entry_abi)
    allocs = AllocInstance[]
    mod = JuliaContext() do ctx
        ir = GPUCompiler.compile(:llvm, job, validate=false)
        mod = ir[1]
        optimize!(job, mod)
        # display(mod)
        (; entry, compiled) = ir[2]

        worklist = LLVM.Function[ entry ]
        seen = LLVM.Function[ entry ]
        while !isempty(worklist)
            f = pop!(worklist)

            throw_, catch_ = rename_calls_and_throws!(f, job)
            domtree = LLVM.DomTree(f)
            postdomtree = LLVM.PostDomTree(f)
            for block in blocks(f)
                for inst in instructions(block)
                    if isa(inst, LLVM.CallInst)
                        decl = called_operand(inst)

                        throw_only = dominates(postdomtree, throw_, inst)
                        ignore_throw && throw_only && continue

                        catch_only = dominates(domtree, catch_, inst)
                        ignore_throw && catch_only && continue

                        if is_alloc_function(name(decl), ignore_throw)
                            bt = backtrace_(inst; compiled)
                            alloc = AllocInstance(inst, bt)
                            push!(allocs, alloc)
                        end

                        if decl isa LLVM.Function && length(blocks(decl)) > 0 && !in(decl, seen)
                            push!(worklist, decl)
                            push!(seen, decl)
                        end
                    end
                end
            end
            dispose(postdomtree)
            dispose(domtree)
        end
        mod
    end

    ret_mod && return mod
    return allocs
end


export check_allocs

end
