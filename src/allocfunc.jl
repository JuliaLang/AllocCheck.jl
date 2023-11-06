# List of methods to location of arg which is the mi/function, then start of args
const generic_method_offsets = Dict{String,Tuple{Int,Int}}(("jl_f__apply_latest" => (2, 3), "ijl_f__apply_latest" => (2, 3), "jl_f__call_latest" => (2, 3), "ijl_f__call_latest" => (2, 3), "jl_f_invoke" => (2, 3), "jl_invoke" => (1, 3), "jl_apply_generic" => (1, 2), "ijl_f_invoke" => (2, 3), "ijl_invoke" => (1, 3), "ijl_apply_generic" => (1, 2)))


const known_nonalloc_funcs = (
    "jl_egal__unboxed", "ijl_egal__unboxed",
    "jl_lock_value", "ijl_lock_value",
    "jl_unlock_value", "ijl_unlock_value",
    "jl_get_nth_field_noalloc", "ijl_get_nth_field_noalloc",
    "jl_load_and_lookup", "ijl_load_and_lookup",
    "jl_lazy_load_and_lookup", "ijl_lazy_load_and_lookup",
    "jl_box_bool", "ijl_box_bool",
    "jl_box_int8", "ijl_box_int8",
    "jl_box_uint8", "ijl_box_uint8",
    r"(ijl|jl)_unbox.*",
    "jl_excstack_state", "ijl_excstack_state",
    "jl_restore_excstack", "ijl_restore_excstack",
    "jl_enter_handler", "ijl_enter_handler",
    "jl_pop_handler", "ijl_pop_handler",
    "jl_f_typeof", "ijl_f_typeof",
    "jl_clock_now", "ijl_clock_now",
    "jl_throw", "ijl_throw", #= the allocation of the error is separate =#
    "jl_gc_queue_root", "ijl_gc_queue_root",
    "jl_gc_enable", "ijl_gc_enable",
    "jl_gc_disable_finalizers_internal", "ijl_gc_disable_finalizers_internal",
    "jl_gc_is_in_finalizer", "ijl_gc_is_in_finalizer",
    "jl_enable_gc_logging", "ijl_enable_gc_logging",
    "jl_gc_safepoint", "ijl_gc_safepoint",
    "jl_gc_collect", "ijl_gc_collect", #= GC collection is not _technically_ an allocation =#
)

const known_alloc_with_throw_funcs = (
    "jl_f_ifelse", "ijl_f_ifelse",
    "jl_f_typeassert", "ijl_f_typeassert",
    "jl_f_is", "ijl_f_is",
    "jl_f_throw", "ijl_f_throw",
    "jl_f__svec_ref", "ijl_f__svec_ref",
    "jl_gc_enable_finalizers_internal", "ijl_gc_enable_finalizers_internal",
)

function is_alloc_function(name, ignore_throw)
    maybe_alloc = occursin(r"(ijl_|jl_).*", name)
    if maybe_alloc
        is_throw_func = any(x -> contains(name, x), known_alloc_with_throw_funcs)
        if is_throw_func
            if ignore_throw
                return false
            else
                return true
            end
        end
        any(x -> contains(name, x), known_nonalloc_funcs) || return true
        return false
    end
    return false
end

function typeof_typetag_gep(inst::LLVM.GetElementPtrInst)
    for gepuse in uses(inst)
        isstore = user(gepuse)
        if isa(isstore, LLVM.StoreInst)
            type_tag = operands(isstore)[1]
            @assert type_tag isa LLVM.ConstantInt
            return guess_julia_type(type_tag, false)
        end
    end
    return nothing # Continue looking
end

function guess_julia_type(val::LLVM.Value, typeof=true)
    while true
        if isa(val, LLVM.ConstantExpr)
            if opcode(val) == LLVM.API.LLVMAddrSpaceCast
                val = operands(val)[1]
                continue
            end
            if opcode(val) == LLVM.API.LLVMIntToPtr
                val = operands(val)[1]
                continue
            end
        end
        if isa(val, LLVM.BitCastInst) || isa(val, LLVM.AddrSpaceCastInst) || isa(val, LLVM.PtrToIntInst)
            val = operands(val)[1]
            continue
        end
        if isa(val, ConstantInt)
            rep = reinterpret(Ptr{Cvoid}, convert(UInt, val))
            val = Base.unsafe_pointer_to_objref(rep)
            if typeof
                return Core.Typeof(val)
            else
                return val
            end
        end
        if isa(val, LLVM.CallInst) && typeof
            fn = LLVM.called_operand(val)
            if isa(fn, LLVM.Function) && (LLVM.name(fn) in ("ijl_gc_pool_alloc_instrumented", "ijl_gc_big_alloc_instrumented", "ijl_gc_alloc_typed", "jl_gc_pool_alloc_instrumented", "jl_gc_big_alloc_instrumented", "jl_gc_alloc_typed"))
                res = guess_julia_type(operands(val)[end-1], false)
                if res !== nothing
                    return res
                end
            end

            if isa(fn, LLVM.Function) && in(LLVM.name(fn), ("ijl_alloc_array_1d", "jl_alloc_array_1d", "ijl_alloc_array_2d", "jl_alloc_array_2d", "ijl_alloc_array_3d", "jl_alloc_array_3d"))
                res = guess_julia_type(operands(val)[1], false)
                if res !== nothing
                    return res
                end
            end

            if isa(fn, LLVM.Function) && in(LLVM.name(fn), ("ijl_alloc_string", "jl_alloc_string"))
                return String
            end

            if isa(fn, LLVM.Function) && in(LLVM.name(fn), ("ijl_array_copy", "jl_array_copy"))
                return Array
            end
            if isa(fn, LLVM.Function) && occursin(r"(ijl_|jl_)box_(.*)", name(fn))
                typestr = match(r"(ijl_|jl_)box_(.*)", name(fn)).captures[end]
                typestr == "bool" && return Bool
                typestr == "char" && return Char
                typestr == "float32" && return Float32
                typestr == "float64" && return Float64
                typestr == "int16" && return Int16
                typestr == "int32" && return Int32
                typestr == "int64" && return Int64
                typestr == "int8" && return Int8
                typestr == "slotnumber" && return Core.SlotNumber
                typestr == "ssavalue" && return Core.SSAValue
                typestr == "uint16" && return UInt16
                typestr == "uint32" && return UInt32
                typestr == "uint64" && return UInt64
                typestr == "uint8" && return UInt8
                typestr == "uint8pointer" && return Ptr{UInt8}
                typestr == "voidpointer" && return Ptr{Cvoid}
                return Any
            end

            if isa(fn, LLVM.Function) && in(LLVM.name(fn), ("ijl_gc_pool_alloc", "jl_gc_pool_alloc"))
                for use in uses(val)
                    istag = user(use)
                    if isa(istag, LLVM.BitCastInst)
                        for bituse in uses(istag)
                            isgep = user(bituse)
                            if isa(isgep, LLVM.GetElementPtrInst)
                                istag = isgep
                                offset = operands(istag::LLVM.GetElementPtrInst)[2]
                                if isa(offset, LLVM.ConstantInt) && convert(Int,offset) == -1
                                    typ = typeof_typetag_gep(istag)
                                    !isnothing(typ) && return typ
                                end
                            end
                        end
                    elseif isa(istag, LLVM.GetElementPtrInst)
                        offset = operands(istag::LLVM.GetElementPtrInst)[2]
                        if isa(offset, LLVM.ConstantInt) && convert(Int,offset) == -1
                            typ = typeof_typetag_gep(istag)
                            !isnothing(typ) && return typ
                        end
                    else
                        continue
                    end
                end
            end
            break
        end
        break
    end
    if typeof
        return Any
    else
        return nothing
    end
end

import GPUCompiler: DYNAMIC_CALL, DELAYED_BINDING, RUNTIME_FUNCTION, UNKNOWN_FUNCTION, POINTER_FUNCTION
import GPUCompiler: backtrace, isintrinsic
function rename_ir!(job, inst::LLVM.CallInst)
    world = job.world
    interp = GPUCompiler.get_interpreter(job)
    method_table = Core.Compiler.method_table(interp)
    dest = called_operand(inst)

    if isa(dest, LLVM.LoadInst)
        fptr = LLVM.Value(LLVM.LLVM.API.LLVMGetOperand(dest, 0))
        if fptr isa LLVM.ConstantExpr && opcode(fptr) == LLVM.API.LLVMBitCast
            fn_got = LLVM.Value(LLVM.LLVM.API.LLVMGetOperand(fptr, 0))
            fname = name(fn_got)
            match_ = match(r"^jlplt_(.*)_\d+_got$", fname)
            if match_ !== nothing
                fname = match_[1]
                mod = LLVM.parent(LLVM.parent(LLVM.parent(inst)))
                lfn = LLVM.API.LLVMGetNamedFunction(mod, fname)
                if lfn == C_NULL
                    lfn = LLVM.API.LLVMAddFunction(mod, Symbol(fname), LLVM.API.LLVMGetCalledFunctionType(inst))
                end
                LLVM.API.LLVMSetOperand(inst, LLVM.API.LLVMGetNumOperands(inst) - 1, lfn)
            end
        end
    end

    if isa(dest, ConstantExpr)
        # Enzyme should be able to handle these
        # detect calls to literal pointers and replace with function name, if possible
        if occursin("inttoptr", string(dest))
            # extract the literal pointer
            ptr_arg = first(operands(dest))
            GPUCompiler.@compiler_assert isa(ptr_arg, ConstantInt) job
            ptr_val = convert(Int, ptr_arg)
            ptr = Ptr{Cvoid}(ptr_val)

            # look it up in the Julia JIT cache
            frames = ccall(:jl_lookup_code_address, Any, (Ptr{Cvoid}, Cint,), ptr, 0)

            if length(frames) >= 1
                fn, file, line, linfo, fromC, inlined = last(frames)
                fn_str = string(fn)

                if length(fn_str) > 1 && fromC
                    mod = LLVM.parent(LLVM.parent(LLVM.parent(inst)))
                    lfn = LLVM.API.LLVMGetNamedFunction(mod, fn_str)
                    if lfn == C_NULL
                        lfn = LLVM.API.LLVMAddFunction(mod, fn, LLVM.API.LLVMGetCalledFunctionType(inst))
                    end
                    LLVM.API.LLVMSetOperand(inst, LLVM.API.LLVMGetNumOperands(inst) - 1, lfn)
                end
            end
        end
        dest = LLVM.Value(LLVM.LLVM.API.LLVMGetOperand(dest, 0))
        if isa(dest, LLVM.Function) && in(LLVM.name(dest), keys(generic_method_offsets))
            offset, start = generic_method_offsets[LLVM.name(dest)]

            flib = operands(inst)[offset]
            while isa(flib, LLVM.ConstantExpr)
                flib = LLVM.Value(LLVM.LLVM.API.LLVMGetOperand(flib, 0))
            end
            if isa(flib, ConstantInt)
                rep = reinterpret(Ptr{Cvoid}, convert(Csize_t, flib))
                flib = Base.unsafe_pointer_to_objref(rep)
                tys = Type[typeof(flib)]
                for op in collect(operands(inst))[start:end-1]
                    push!(tys, guess_julia_type(op))
                end
                if isa(flib, Core.MethodInstance)
                    if !Base.isvarargtype(flib.specTypes.parameters[end])
                        if length(tys) != length(flib.specTypes.parameters)
                            @show tys, flib, inst, offset, start
                        end
                        @assert length(tys) == length(flib.specTypes.parameters)
                    end
                    tys = flib.specTypes.parameters
                end
            end
        end
    end

end
