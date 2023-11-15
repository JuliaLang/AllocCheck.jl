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
