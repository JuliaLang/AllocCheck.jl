module AllocCheck

import LLVM, GPUCompiler
using GPUCompiler: JuliaContext, safe_name
using LLVM: BasicBlock, ConstantExpr, ConstantInt, InlineAsm, IRBuilder, UndefValue,
            blocks, br!, called_operand, dispose, dominates, instructions, metadata,
            name, opcode, operands, position!, ret!, successors, switch!, uses, user

include("static_backtrace.jl")
include("abi_call.jl")
include("classify.jl")
include("compiler.jl")
include("macro.jl")
include("types.jl")
include("utils.jl")

module Runtime end

function rename_calls_and_throws!(f::LLVM.Function, mod::LLVM.Module)

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
                rename_call!(inst, mod)
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
                    @assert convert(Int, operands(icmp_)[2]) == 0
                    for br_ in uses(icmp_)
                        br_ = user(br_)
                        @assert br_ isa LLVM.BrInst

                        # Rewrite the jump to this `catch` block as an indirect jump
                        # from a common `any_catch` block
                        _, catch_target = successors(br_)
                        successors(br_)[2] = any_catch
                        branch_index = ConstantInt(length(successors(catch_switch)))
                        LLVM.API.LLVMAddCase(catch_switch, branch_index, catch_target)
                    end
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
Find all static allocation sites in the provided LLVM IR.

This function modifies the LLVM module in-place, effectively trashing it.
"""
function find_allocs!(mod::LLVM.Module, meta; ignore_throw=true, invoke_entry=false)
    (; entry, compiled) = meta

    errors = []
    worklist = LLVM.Function[ entry ]
    seen = LLVM.Function[ entry ]
    if invoke_entry
        @assert startswith(name(entry), "jfptr")
        f = pop!(worklist)
        for block in blocks(f)
            for inst in instructions(block)
                if isa(inst, LLVM.CallInst)
                    decl = called_operand(inst)
                    if decl isa LLVM.Function && length(blocks(decl)) > 0 && !in(decl, seen)
                        push!(worklist, decl)
                        push!(seen, decl)
                    end
                end
            end
        end
    end
    while !isempty(worklist)
        f = pop!(worklist)

        throw_, catch_ = rename_calls_and_throws!(f, mod)
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

                    class, may_allocate = classify_runtime_fn(name(decl); ignore_throw)

                    if class === :alloc
                        allocs = resolve_allocations(inst)
                        if allocs === nothing # TODO: failed to resolve
                            bt = backtrace_(inst; compiled)
                            push!(errors, AllocationSite(Any, bt))
                        else
                            for (inst_, typ) in allocs

                                throw_only = dominates(postdomtree, throw_, inst_)
                                ignore_throw && throw_only && continue

                                catch_only = dominates(domtree, catch_, inst_)
                                ignore_throw && catch_only && continue

                                bt = backtrace_(inst_; compiled)
                                push!(errors, AllocationSite(typ, bt))
                            end
                        end
                        @assert may_allocate
                    elseif class === :dispatch
                        fname = resolve_dispatch_target(inst)
                        bt = backtrace_(inst; compiled)
                        push!(errors, DynamicDispatch(bt, fname))
                        @assert may_allocate
                    elseif class === :runtime && may_allocate
                        bt = backtrace_(inst; compiled)
                        fname = replace(name(decl), r"^ijl_"=>"jl_")
                        push!(errors, AllocatingRuntimeCall(fname, bt))
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

    # TODO: dispose(mod)
    # dispose(mod)

    unique!(errors)
    return errors
end

"""
    check_allocs(func, types; ignore_throw=true)

Compiles the given function and types to LLVM IR and checks for allocations.

Returns a vector of `AllocationSite`, `DynamicDispatch`, and `AllocatingRuntimeCall`

!!! warning
    The Julia language/compiler does not guarantee that this result is stable across
    Julia invocations.

    If you rely on allocation-free code for safety/correctness, it is not sufficient
    to verify `check_allocs` in test code and expect that the corresponding call in
    production will not allocate at runtime.

    For this case, you must use `@check_allocs` instead.

# Example
```jldoctest
julia> function foo(x::Int, y::Int)
           z = x + y
           return z
       end
foo (generic function with 1 method)

julia> allocs = check_allocs(foo, (Int, Int))
AllocCheck.AllocationSite[]
```

"""
function check_allocs(@nospecialize(func), @nospecialize(types); ignore_throw=true)
    if !hasmethod(func, types)
        throw(MethodError(func, types))
    end
    source = GPUCompiler.methodinstance(Base._stable_typeof(func), Base.to_tuple_type(types))
    target = DefaultCompilerTarget()
    job = CompilerJob(source, alloc_config(:specfunc))
    allocs = JuliaContext() do ctx
        mod, meta = GPUCompiler.compile(:llvm, job, validate=false, optimize=false, cleanup=false)
        optimize!(mod)

        allocs = find_allocs!(mod, meta; ignore_throw, invoke_entry=false)
        # display(mod)
        # dispose(mod)
        allocs
    end
    return allocs
end


export check_allocs, alloc_type, @check_allocs, AllocCheckFailure

end
