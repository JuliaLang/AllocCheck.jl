import GPUCompiler, LLVM
using LLVM: LLVMType

# https://github.com/JuliaGPU/GPUCompiler.jl/blob/21ca075c1e91fe0c15f1330ab487b4831013ec1f/examples/jit.jl#L145-L222
@generated function abi_call(f::Ptr{Cvoid}, rt::Type{RT}, tt::Type{T}, func::F, args::Vararg{Any, N}) where {T, RT, F, N}
    argtt    = tt.parameters[1]
    rettype  = rt.parameters[1]
    argtypes = DataType[argtt.parameters...]

    argexprs = Union{Expr, Symbol}[]
    ccall_types = DataType[]

    before = :()
    after = :(ret)

    # Note this follows: emit_call_specfun_other
    JuliaContext() do ctx
        if !GPUCompiler.isghosttype(F) && !Core.Compiler.isconstType(F)
            isboxed = GPUCompiler.deserves_argbox(F)
            argexpr = :(func)
            if isboxed
                push!(ccall_types, Any)
            else
                et = convert(LLVMType, func)
                if isa(et, LLVM.SequentialType) # et->isAggregateType
                    push!(ccall_types, Ptr{F})
                    argexpr = Expr(:call, GlobalRef(Base, :Ref), argexpr)
                else
                    push!(ccall_types, F)
                end
            end
            push!(argexprs, argexpr)
        end

        T_jlvalue = LLVM.StructType(LLVMType[])
        T_prjlvalue = LLVM.PointerType(T_jlvalue, #= AddressSpace::Tracked =# 10)

        for (source_i, source_typ) in enumerate(argtypes)
            if GPUCompiler.isghosttype(source_typ) || Core.Compiler.isconstType(source_typ)
                continue
            end

            argexpr = :(args[$source_i])

            isboxed = GPUCompiler.deserves_argbox(source_typ)
            et = isboxed ? T_prjlvalue : convert(LLVMType, source_typ)

            if isboxed
                push!(ccall_types, Any)
            elseif isa(et, LLVM.SequentialType) # et->isAggregateType
                push!(ccall_types, Ptr{source_typ})
                argexpr = Expr(:call, GlobalRef(Base, :Ref), argexpr)
            else
                push!(ccall_types, source_typ)
            end
            push!(argexprs, argexpr)
        end

        if GPUCompiler.isghosttype(rettype) || Core.Compiler.isconstType(rettype)
            # Do nothing...
            # In theory we could set `rettype` to `T_void`, but ccall will do that for us
        # elseif jl_is_uniontype?
        elseif !GPUCompiler.deserves_retbox(rettype)
            rt = convert(LLVMType, rettype)
            if !isa(rt, LLVM.VoidType) && GPUCompiler.deserves_sret(rettype, rt)
                before = :(sret = Ref{$rettype}())
                pushfirst!(argexprs, :(sret))
                pushfirst!(ccall_types, Ptr{rettype})
                rettype = Nothing
                after = :(sret[])
            end
        elseif isa(rettype, Union)
            union_info = union_layout_info(rettype)
            if union_info.sz_bytes > 0
                # "Small" union

                # This is supposed to alloca the appropriate amount of bytes and then expect a
                # struct { jl_value_t*, uint8_t (selector) }
            elseif union_info.all_unbox
                # Ghost - all_unbox + 0-size

                # This just receives a RT of uint8_t (selector)
            else
                rettype_is_ctype = ccall(:jl_type_mappable_to_c, Cint, (Any,), rettype) != 0
                !rettype_is_ctype && (rettype = Any;)
            end
        else
            # rt = T_prjlvalue
        end
    end

    quote
        $before
        ret = ccall(f, $rettype, ($(ccall_types...),), $(argexprs...))
        $after
    end
end

# Based on `for_each_uniontype_small` in src/cgutils.cpp
function foreach_union_type_small(f::Function, @nospecialize(T)::Type, counter::Ref{Int})
    if counter[] > 127
        return false
    end
    if T isa Union
        all_unbox = foreach_union_type_small(f, T.a, counter)
        return all_unbox && foreach_union_type_small(f, T.b, counter)
    end
    if GPUCompiler.is_pointerfree(T)
        counter[] += 1
        f(counter[], T)
        return true
    end
    return false
end

is_layout_opaque(layout) = layout.nfields == 0 && (layout.npointers > 0)
function datatype_layout(@nospecialize(T)::Type)
    if is_layout_opaque(T.layout)
        T = Base.unwrap_unionall(T.name.wrapper)
    end
    return T.layout
end

struct LayoutInfo
    sz_bytes::UInt32
    align::UInt16
    min_align::UInt16
    all_unbox::Bool
end

# Based on `union_alloc_type` in src/cgutils.cpp
function union_layout_info(@nospecialize(T)::Type{<:Union})
    nbytes = 0
    align = 0
    min_align = typemax(Int)
    counter = Ref{Int}(0)
    all_unbox = foreach_union_type_small(
        (idx::Int, @nospecialize(T)::Type)->begin
            if !Base.issingletontype(T)
                layout = datatype_layout(T)
                if layout.size > nbytes
                    nbytes = layout.size
                end
                if layout.align > align
                    align = layout.align
                end
                if layout.align < min_align
                    min_align = layout.align
                end
            end
        end, T, counter)
    return LayoutInfo(nbytes, align, min_align, all_unbox)
end
