"""
    classify_runtime_fn(name)

A :dispatch function is responsible for a "dynamic dispatch" to an unknown Julia
function.

An :alloc functions is used by codegen to lower allocations for mutable structs,
arrays, and other Julia objects.

A :runtime function is any function used by the runtime which does not explicitly
perform allocation, but which might allocate to get its job done (e.g. jl_subtype).
"""
function classify_runtime_fn(name::AbstractString; ignore_throw::Bool)
    match_ = match(r"^(ijl_|jl_)(.*)$", name)

    isnothing(match_) && return (:unknown, false)
    name = match_[2]

    may_alloc = fn_may_allocate(name; ignore_throw)
    if name in ("alloc_genericmemory", "genericmemory_copy", "array_copy", "alloc_string",
                "alloc_array_1d", "alloc_array_2d", "alloc_array_3d", "gc_alloc_typed",
                "gc_pool_alloc", "gc_pool_alloc_instrumented", "gc_big_alloc_instrumented") || occursin(r"^box_.*", name)
        return (:alloc, may_alloc)
    elseif name in ("f__apply_latest", "f__apply_iterate", "f__apply_pure", "f__call_latest",
                    "f__call_in_world", "f__call_in_world_total", "f_intrinsic_call", "f_invoke",
                    "f_opaque_closure_call", "apply", "apply_generic", "gf_invoke",
                    "gf_invoke_by_method", "gf_invoke_lookup_worlds", "invoke", "invoke_api",
                    "jl_call", "jl_call0", "jl_call1", "jl_call2", "jl_call3")
        return (:dispatch, may_alloc)
    else
        return (:runtime, may_alloc)
    end

end

const generic_method_offsets = Dict{String,Int}(("jl_f__apply_latest" => 2, "ijl_f__apply_latest" => 2,
    "jl_f__call_latest" => 2, "ijl_f__call_latest" => 2, "jl_f_invoke" => 2, "jl_invoke" => 1,
    "jl_apply_generic" => 1 "ijl_f_invoke" => 2, "ijl_invoke" => 1, "ijl_apply_generic" => 1))

function resolve_dispatch_target(inst::LLVM.Instruction)
    @assert isa(inst, LLVM.CallInst)
    fun = LLVM.called_operand(inst)
    if isa(fun, LLVM.Function) && in(LLVM.name(fun), keys(generic_method_offsets))
        offset = generic_method_offsets[LLVM.name(fun)]
        flib = operands(inst)[offset]
        flib = unwrap_ptr_casts(flib)
        flib = look_through_loads(flib)
        while isa(flib, LLVM.ConstantExpr)
            flib = LLVM.Value(LLVM.LLVM.API.LLVMGetOperand(flib, 0))
        end
        if isa(flib, ConstantInt)
            rep = reinterpret(Ptr{Cvoid}, convert(Csize_t, flib))
            flib = Base.unsafe_pointer_to_objref(rep)
            return nameof(flib)
        end
    end
    return nothing
end

function fn_may_allocate(name::AbstractString; ignore_throw::Bool)
    if name in ("egal__unboxed", "lock_value", "unlock_value", "get_nth_field_noalloc",
                "load_and_lookup", "lazy_load_and_lookup", "box_bool", "box_int8",
                "box_uint8", "excstack_state", "restore_excstack", "enter_handler",
                "pop_handler", "f_typeof", "clock_now", "throw", "gc_queue_root", "gc_enable",
                "gc_disable_finalizers_internal", "gc_is_in_finalizer", "enable_gc_logging",
                "gc_safepoint", "gc_collect") || occursin(r"^unbox_.*", name)
        return false # these functions never allocate
    elseif name in ("f_ifelse", "f_typeassert", "f_is", "f_throw", "f__svec_ref")
        return ignore_throw == false # these functions only allocate if they throw
    else
        return true
    end
end

function unwrap_ptr_casts(val::LLVM.Value)
    while true
        is_simple_cast = false
        is_simple_cast |= isa(val, LLVM.BitCastInst)
        is_simple_cast |= isa(val, LLVM.AddrSpaceCastInst) || isa(val, LLVM.PtrToIntInst)
        is_simple_cast |= isa(val, LLVM.ConstantExpr) && opcode(val) == LLVM.API.LLVMAddrSpaceCast
        is_simple_cast |= isa(val, LLVM.ConstantExpr) && opcode(val) == LLVM.API.LLVMIntToPtr
        is_simple_cast |= isa(val, LLVM.ConstantExpr) && opcode(val) == LLVM.API.LLVMBitCast

        if !is_simple_cast
            return val
        else
            val = operands(val)[1]
        end
    end
end

function look_through_loads(val::LLVM.Value)
    if isa(val, LLVM.LoadInst)
        val = operands(val)[1]
        val = unwrap_ptr_casts(val)
        if isa(val, LLVM.GlobalVariable)
            val = LLVM.initializer(val)
            val = unwrap_ptr_casts(val)
        end
    end
    return val
end

"""
Returns `nothing` if the value could not be resolved statically.
"""
function resolve_static_jl_value_t(val::LLVM.Value)
    val = unwrap_ptr_casts(val)
    val = look_through_loads(val)
    !isa(val, ConstantInt) && return nothing
    ptr = reinterpret(Ptr{Cvoid}, convert(UInt, val))
    return Base.unsafe_pointer_to_objref(ptr)
end

function transitive_uses(inst::LLVM.Instruction; unwrap = (use)->false)
    uses_ = LLVM.Use[]
    for use in uses(inst)
        if unwrap(use)
            append!(uses_, transitive_uses(user(use); unwrap))
        else
            push!(uses_, use)
        end
    end
    return uses_
end

"""
Returns `nothing` if the type could not be resolved statically.
"""
function resolve_allocations(call::LLVM.Value)
    @assert isa(call, LLVM.CallInst)

    fn = LLVM.called_operand(call)
    !isa(fn, LLVM.Function) && return nothing
    name = LLVM.name(fn)

    # Strip off the "jl_" or "ijl_" prefix
    match_ = match(r"^(ijl_|jl_)(.*)$", name)
    isnothing(match_) && return nothing
    name = match_[2]

    if name in ("gc_pool_alloc_instrumented", "gc_big_alloc_instrumented", "gc_alloc_typed")
        type = resolve_static_jl_value_t(operands(call)[end-1])
        return type !== nothing ? [(call, type)] : nothing
    elseif name in ("alloc_array_1d", "alloc_array_2d", "alloc_array_3d")
        type = resolve_static_jl_value_t(operands(call)[1])
        return type!== nothing ? [(call, type)] : nothing
    elseif name == "alloc_string"
        return [(call, String)]
    elseif name == "array_copy"
        return [(call, Array)]
    elseif name == "genericmemory_copy"
        @assert VERSION > v"1.11.0-DEV.753"
        return [(call, Memory)]
    elseif name == "alloc_genericmemory"
        type = resolve_static_jl_value_t(operands(call)[1])
        return [(call, type !== nothing ? type : Memory)]
    elseif occursin(r"^box_(.*)", name)
        typestr = match(r"^box_(.*)", name).captures[end]
        typestr == "bool" && return [(call, Bool)]
        typestr == "char" && return [(call, Char)]
        typestr == "float32" && return [(call, Float32)]
        typestr == "float64" && return [(call, Float64)]
        typestr == "int16" && return [(call, Int16)]
        typestr == "int32" && return [(call, Int32)]
        typestr == "int64" && return [(call, Int64)]
        typestr == "int8" && return [(call, Int8)]
        typestr == "slotnumber" && return [(call, Core.SlotNumber)]
        typestr == "ssavalue" && return [(call, Core.SSAValue)]
        typestr == "uint16" && return [(call, UInt16)]
        typestr == "uint32" && return [(call, UInt32)]
        typestr == "uint64" && return [(call, UInt64)]
        typestr == "uint8" && return [(call, UInt8)]
        typestr == "uint8pointer" && return [(call, Ptr{UInt8})]
        typestr == "voidpointer" && return [(call, Ptr{Cvoid})]
        @assert false # above is exhaustive
    elseif name == "gc_pool_alloc"
        seen = Set()
        allocs = Tuple{LLVM.Instruction, Any}[]
        for calluse in transitive_uses(call; unwrap = (use)->user(use) isa LLVM.BitCastInst)
            gep = user(calluse)
            !isa(gep, LLVM.GetElementPtrInst) && continue

            # Check that this points into the type tag (at a -1 offset)
            offset = operands(gep)[2]
            !isa(offset, LLVM.ConstantInt) && continue
            (convert(Int, offset) != -1) && continue

            # Now, look for the store into the type tag and count that as our allocation(s)
            for gepuse in uses(gep)
                store = user(gepuse)
                !isa(store, LLVM.StoreInst) && continue

                # It is possible for the optimizer to merge multiple distinct `gc_pool_alloc`
                # allocations which actually have distinct types, so here we count each type
                # tag store as a separate allocation.
                type_tag = operands(store)[1]
                type = resolve_static_jl_value_t(type_tag)
                if type === nothing
                    type = Any
                end

                type in seen && continue
                push!(seen, type)
                push!(allocs, (store, type))
            end
        end
        return allocs
    end
    return nothing
end

"""
Resolve the callee of a call embedded in Julia-constructed LLVM IR
and replace it with a new locally-declared function that has the
resolved name as its identifier.
"""
function rename_call!(call::LLVM.CallInst, mod::LLVM.Module)
    callee = called_operand(call)
    if isa(callee, LLVM.LoadInst)

        fn_got = unwrap_ptr_casts(operands(callee)[1])
        fname = name(fn_got)
        match_ = match(r"^jlplt_(.*)_\d+_got$", fname)
        match_ === nothing && return

        fname = match_[1]
    elseif isa(callee, ConstantExpr)

        # extract the literal pointer
        ptr_arg = unwrap_ptr_casts(callee)
        @assert isa(ptr_arg, LLVM.ConstantInt)
        ptr = Ptr{Cvoid}(convert(Int, ptr_arg))

        # look it up in the Julia JIT cache
        frames = ccall(:jl_lookup_code_address, Any, (Ptr{Cvoid}, Cint,), ptr, 0)
        length(frames) == 0 && return
        fn, file, line, linfo, fromC, inlined = last(frames)

        fname = string(fn)
    else
        return
    end

    # Re-write function call to use a locally-created version with a nice name
    lfn = LLVM.API.LLVMGetNamedFunction(mod, fname)
    if lfn == C_NULL
        lfn = LLVM.API.LLVMAddFunction(mod, Symbol(fname), LLVM.API.LLVMGetCalledFunctionType(call))
    end
    LLVM.API.LLVMSetOperand(call, LLVM.API.LLVMGetNumOperands(call) - 1, lfn)

    return nothing
end
