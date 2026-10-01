import LLVM, GPUCompiler
using GPUCompiler: NativeCompilerTarget

struct NativeParams <: GPUCompiler.AbstractCompilerParams end

DefaultCompilerTarget(; kwargs...) = NativeCompilerTarget(; jlruntime=true, kwargs...)
