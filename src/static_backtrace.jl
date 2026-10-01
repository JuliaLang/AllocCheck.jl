import LLVM

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
        f = inst.parent.parent

        # look up the debug information from the current instruction
        loc = inst.debug_location
        while loc !== nothing
            scope = loc.scope
            if scope !== nothing
                emitted_name = f.name
                name = replace(scope.name, r";$" => "")
                file = scope.file
                path = joinpath(file.directory, file.filename)
                line = loc.line
                linfo = nothing
                from_c = false
                inlined = loc.inlined_at !== nothing
                !inlined && for (mi, (; ci, func, specfunc)) in compiled
                    if safe_name(func) == emitted_name || safe_name(specfunc) == emitted_name
                        linfo = mi
                        break
                    end
                end
                push!(bt, StackTraces.StackFrame(Symbol(name), Symbol(path), line,
                    linfo, from_c, inlined, 0))
            end
            loc = loc.inlined_at
        end

        # move up the call chain
        ## functions can be used as a *value* in eg. constant expressions, so filter those out
        callers = filter(user -> isa(user, LLVM.CallInst), collect(f.users))
        ## get rid of calls without debug info
        filter!(call -> call.debug_location !== nothing, callers)
        if !isempty(callers)
            # figure out the call sites of this instruction
            call_sites = unique(callers) do call
                # there could be multiple calls, originating from the same source location
                call.debug_location
            end

            if length(call_sites) > 1
                frame = StackTraces.StackFrame("multiple call sites", "unknown", 0)
                push!(bt, frame)
            elseif length(call_sites) == 1
                inst = first(call_sites)
                continue
            end
        end
        break
    end

    return bt
end
