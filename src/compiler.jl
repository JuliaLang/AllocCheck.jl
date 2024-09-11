import LLVM, GPUCompiler
using LLVM: TargetMachine, @dispose
using GPUCompiler: CompilerConfig, CompilerJob, MemoryBuffer, NativeCompilerTarget, JuliaContext, ThreadSafeContext, run!

include("compiler_utils.jl")

function __init__()
    opt_level = Base.JLOptions().opt_level

    tm[] = LLVM.JITTargetMachine(LLVM.triple(), cpu_name(), cpu_features();
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
end

# lock + JIT objects
const codegen_lock = ReentrantLock()
const jit = Ref{CompilerInstance}()
const tm = Ref{TargetMachine}() # for opt pipeline

# cache of kernel instances
const _kernel_instances = Dict{Any, Any}()
const compiler_cache = Dict{Any, CompileResult}()
alloc_config(func_abi::Symbol) = CompilerConfig(DefaultCompilerTarget(), NativeParams();
                              kernel=false, entry_abi = func_abi, always_inline=false)

const NativeCompilerJob = CompilerJob{NativeCompilerTarget,NativeParams}
GPUCompiler.can_safepoint(@nospecialize(job::NativeCompilerJob)) = true
GPUCompiler.runtime_module(::NativeCompilerJob) = Runtime

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
    # cuda = active_state()

    Base.@lock codegen_lock begin
        # compile the function
        cache = compiler_cache
        source = GPUCompiler.methodinstance(F, tt)
        rt = Core.Compiler.return_type(f, tt)

        function compile(@nospecialize(job::CompilerJob))
            return JuliaContext() do ctx
                mod, meta = GPUCompiler.compile(:llvm, job, validate=false)
                optimize!(mod)

                clone = copy(mod)
                analysis = find_allocs!(mod, meta; ignore_throw, invoke_entry=true)
                # TODO: This is the wrong meta
                return clone, meta, analysis
            end
        end
        function link(@nospecialize(job::CompilerJob), (mod, meta, analysis))
            return JuliaContext() do ctx
                lljit = jit[].jit
                jd = LLVM.JITDylib(lljit)
                buf = convert(MemoryBuffer, mod)
                tsm = ThreadSafeContext() do ctx
                    mod = parse(LLVM.Module, buf)
                    GPUCompiler.ThreadSafeModule(mod)
                end
                LLVM.add!(lljit, jd, tsm)
                f_ptr = pointer(LLVM.lookup(lljit, LLVM.name(meta.entry)))
                if f_ptr == C_NULL
                    throw(GPUCompiler.InternalCompilerError(job,
                          "Failed to compile @check_allocs function"))
                end
                if length(analysis) == 0
                    CompileResult{true, typeof(f), tt, rt}(f_ptr, tt, rt, f, analysis)
                else
                    CompileResult{false, typeof(f), tt, rt}(f_ptr, tt, rt, f, analysis)
                end
            end
        end
        fun = GPUCompiler.cached_compilation(cache, source, alloc_config(:func), compile, link)

        # create a callable object that captures the function instance. we don't need to think
        # about world age here, as GPUCompiler already does and will return a different object
        key = (objectid(source), hash(fun), f)
        return get(_kernel_instances, key, fun)::CompileResult
    end
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
