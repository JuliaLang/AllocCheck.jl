# AllocCheck.jl

<!-- [![Build Status](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/gbaraldi/AllocCheck.jl/actions/workflows/CI.yml?query=branch%3Amain) -->

AllocCheck.jl is a Julia package that statically checks if a function call may allocate, analyzing the generated LLVM IR of it and it's callees using LLVM.jl and GPUCompiler.jl
