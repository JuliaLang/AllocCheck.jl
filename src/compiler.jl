import LLVM, GPUCompiler
using LLVM: TargetMachine, @dispose
using GPUCompiler: CompilerConfig, CompilerJob, MemoryBuffer, NativeCompilerTarget, JuliaContext, run!

include("compiler_utils.jl")

function __init__()
    opt_level = Base.JLOptions().opt_level
    target = DefaultCompilerTarget()

    # Match the target recorded in the compiler cache key. Julia's CPU feature string may
    # include unavailable features implied by the CPU name, while LLVM filters with CPUID.
    tm[] = LLVM.JITTargetMachine(LLVM.triple(), target.cpu, target.features;
                                 optlevel = llvm_codegen_level(opt_level))
    LLVM.asm_verbosity!(tm[], true)
    lljit = LLVM.JuliaOJIT()

    jd_main = LLVM.JITDylib(lljit)

    prefix = LLVM.get_prefix(lljit)
    dg = LLVM.CreateDynamicLibrarySearchGeneratorForProcess(prefix)
    LLVM.add!(jd_main, dg)

    # TODO: Do we need this trick from Enzyme?
    # if Sys.iswindows() && Int === Int64
        # # TODO can we check isGNU?
        # define_absolute_symbol(jd_main, mangle(lljit, "___chkstk_ms"))
    # end

    es = LLVM.ExecutionSession(lljit)
    try
        lctm = LLVM.LocalLazyCallThroughManager(GPUCompiler.triple(lljit), es)
        ism = LLVM.LocalIndirectStubsManager(GPUCompiler.triple(lljit))
        jit[] = CompilerInstance(lljit, lctm, ism)
    catch err
        @warn "OrcV2 initialization failed with" err
        jit[] = CompilerInstance(lljit, nothing, nothing)
    end
end

struct CompilerInstance
    jit::LLVM.JuliaOJIT
    lctm::Union{LLVM.LazyCallThroughManager, Nothing}
    ism::Union{LLVM.IndirectStubsManager, Nothing}
end
struct CompileResult{Success, F, TT, RT}
    f_ptr::Ptr{Cvoid}
    arg_types::Type{TT}
    return_type::Type{RT}
    func::F
    analysis # TODO: add type
    roots::Any  # keeps relocation targets alive for as long as `f_ptr` is callable
end

# lock + JIT objects
const codegen_lock = ReentrantLock()
const jit = Ref{CompilerInstance}()
const tm = Ref{TargetMachine}() # for opt pipeline

# cache of kernel instances
const _kernel_instances = Dict{Any, Any}()
alloc_config(func_abi::Symbol; ignore_throw::Bool=true, kwargs...) =
    CompilerConfig(DefaultCompilerTarget(), NativeParams(ignore_throw);
                   kernel=false, entry_abi = func_abi, always_inline=false, kwargs...)

# compilation results attached to each cached CodeInstance through
# `GPUCompiler.cached_results`; on Julia 1.11+ these also persist through package
# precompilation.
mutable struct AllocCheckResults
    # session-portable artifacts: a relocatable object file, the manifest of relocations left
    # for the loader to write into it, and the allocation analysis
    object::Union{Nothing,Vector{UInt8}}
    entry::Union{Nothing,String}
    relocations::GPUCompiler.Relocations
    analysis::Union{Nothing,Vector{Any}}

    # session-local JIT handle; never persisted (see `compile_callable`)
    ptr::Ptr{Cvoid}

    AllocCheckResults() = new(nothing, nothing, GPUCompiler.Relocations(), nothing, C_NULL)
end

const NativeCompilerJob = CompilerJob{NativeCompilerTarget,NativeParams}
GPUCompiler.can_safepoint(@nospecialize(job::NativeCompilerJob)) = true
GPUCompiler.runtime_module(::NativeCompilerJob) = Runtime
# Emit each host reference as a named, null-initialized global for us to write after loading
# the object, rather than baking this session's addresses into the code. That keeps the
# cached *object* session-portable, so a later session (or a package image) starts it up with
# no compiler involved at all: add the object, write one word per record (see `link_result`).
#
# Every object we load lands in one shared JITDylib (before Julia 1.14, at least), so two
# results referencing the same value must not define the same symbol. GPUCompiler namespaces
# record names per compiler job, which makes that so by construction.
GPUCompiler.relocation_lowering(@nospecialize(job::NativeCompilerJob)) = :patch

# Emit machine code through the JIT target machine, whose relocation and code model suit
# loading the result into the session's ORC JIT.
GPUCompiler.mcgen(@nospecialize(job::NativeCompilerJob), mod::LLVM.Module,
                  format=LLVM.API.LLVMAssemblyFile) = String(LLVM.emit(tm[], mod, format))

function optimize!(mod::LLVM.Module)
    pipeline = LLVM.Interop.JuliaPipeline(opt_level=Base.JLOptions().opt_level)
    run!(pipeline, mod)
end

"""
    compile_callable(f, tt=Tuple{}; kwargs...)

Low-level interface to compile a function invocation for the provided function and tuple of
argument types using the naive JuliaOJIT() pipeline.

The output of this function is automatically cached, so that new code will be generated
automatically and checked for allocations whenever the function changes or when different
types or keyword arguments are provided.
"""
function compile_callable(f::F, tt::TT=Tuple{}; ignore_throw=true) where {F, TT}
    Base.@lock codegen_lock begin
        source = GPUCompiler.methodinstance(F, tt)
        rt = Core.Compiler.return_type(f, tt)
        method = source.def::Method
        namespace = join(Base.fullname(method.module), '_')
        entry = "alloccheck_$(namespace)_$(GPUCompiler.mangle_sig(source.specTypes))"
        config = alloc_config(:func; ignore_throw, validate=false, name=entry)
        job = CompilerJob(source, config)

        # Explicitly enroll the foreign CodeInstance in a package image. Codegen creates
        # one on a miss, but Julia only serializes it reliably when it is precompiled.
        if ccall(:jl_generating_output, Cint, ()) == 1
            precompile(job)
        end

        # look up (or generate) the compilation artifacts and analysis
        res = GPUCompiler.cached_results(AllocCheckResults, job)
        if res === nothing || res.object === nothing
            artifacts = JuliaContext() do ctx
                mod, meta = GPUCompiler.compile(:llvm, job)
                entry = name(meta.entry)
                optimize!(mod)
                relocations = meta.relocations

                # Julia's JIT expects some symbols to be present that it would otherwise
                # inject itself, when handed IR rather than an object (Win64 unwind data).
                LLVM.decorate_module(mod)

                # Snapshot the module while its sites are still symbolic: the object needs
                # them that way, while the analysis needs them *resolved* to read concrete
                # values (e.g. type tags) out of the IR.
                bitcode = let io = IOBuffer()
                    write(io, mod)
                    take!(io)
                end

                # `emit_asm` lowers the sites in place and prunes the ones optimization
                # killed, leaving exactly the manifest the object still needs written
                asm, _ = GPUCompiler.emit_asm(job, mod, relocations,
                                              LLVM.API.LLVMObjectFile)
                object = Vector{UInt8}(codeunits(asm))

                analysis = let analysis_mod = parse(LLVM.Module, MemoryBuffer(bitcode))
                    GPUCompiler.apply_relocations!(analysis_mod, relocations)
                    find_allocs!(analysis_mod, meta, entry; ignore_throw, invoke_entry=true)
                end

                (; object, entry, relocations, analysis)
            end
            # Compiling may have created the CodeInstance we attach results to. GPUCompiler
            # selects persistent or session-local storage from the relocation strategy.
            res = @something(res, GPUCompiler.cached_results(AllocCheckResults, job),
                             AllocCheckResults())
            res.object = artifacts.object
            res.entry = artifacts.entry
            res.relocations = artifacts.relocations
            res.analysis = artifacts.analysis
        end

        # (re)link the code into the session's JIT, resolving relocations
        if res.ptr == C_NULL
            f_ptr = link_result(job, res)
            # don't persist JIT handles into package images
            if ccall(:jl_generating_output, Cint, ()) != 1
                res.ptr = f_ptr
            end
        else
            f_ptr = res.ptr
        end

        analysis = res.analysis::Vector{Any}
        fun = if length(analysis) == 0
            CompileResult{true, typeof(f), tt, rt}(f_ptr, tt, rt, f, analysis, res)
        else
            CompileResult{false, typeof(f), tt, rt}(f_ptr, tt, rt, f, analysis, res)
        end

        # create a callable object that captures the function instance. we don't need to think
        # about world age here, as GPUCompiler already does and will return a different object
        key = (objectid(source), hash(fun), f)
        return get(_kernel_instances, key, fun)::CompileResult
    end
end

# Results linked while precompiling cannot retain their pointer. Remember them by identity so
# another lookup in the same session does not add the object a second time. Entry names are
# not suitable keys: different cached objects can contain the same Julia codegen name.
const _linked = IdDict{AllocCheckResults,Ptr{Cvoid}}()

# Load cached relocatable code into this session's JIT and write this session's host
# addresses into it. No compiler runs here — the object is already machine code — which is
# what makes a cached (or precompiled) result a genuine warm start.
function link_result(@nospecialize(job::CompilerJob), res::AllocCheckResults)
    entry = res.entry::String
    haskey(_linked, res) && return _linked[res]

    lljit = jit[].jit
    jd = LLVM.JITDylib(lljit, entry)
    LLVM.add!(lljit, jd, MemoryBuffer(res.object::Vector{UInt8}))

    # `resolved_relocations` permanently roots the referenced values, so the words it hands
    # back cannot dangle for as long as the code stays loaded
    for (rec, word) in GPUCompiler.resolved_relocations(res.relocations)
        addr = pointer(LLVM.lookup(lljit, jd, rec.name))
        addr == C_NULL && throw(GPUCompiler.InternalCompilerError(job,
              "Relocation '$(rec.name)' is absent from the loaded object"))
        unsafe_store!(Ptr{UInt}(addr + rec.offset), word)
    end

    f_ptr = pointer(LLVM.lookup(lljit, jd, entry))
    if f_ptr == C_NULL
        throw(GPUCompiler.InternalCompilerError(job,
              "Failed to compile @check_allocs function"))
    end
    return _linked[res] = f_ptr
end

function (f::CompileResult{Success, F, TT, RT})(args...) where {Success, F, TT, RT}
    if Success
        argsv = Any[args...]
        GC.@preserve argsv begin
            return ccall(f.f_ptr, Any, (Any, Ptr{Any}, UInt32), f.func, pointer(argsv), length(args))
        end
    else
        error("@check_allocs function contains ", length(f.analysis), " allocations.")
    end
end
