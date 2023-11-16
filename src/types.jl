
struct AllocatingRuntimeCall
    name::String
    backtrace::Vector{Base.StackTraces.StackFrame}
end

function Base.hash(self::AllocatingRuntimeCall, h::UInt)
    return Base.hash(self.name, nice_hash(self.backtrace, h))
end

function Base.:(==)(self::AllocatingRuntimeCall, other::AllocatingRuntimeCall)
    return (self.name == other.name) && (nice_isequal(self.backtrace,other.backtrace))
end

function Base.show(io::IO, call::AllocatingRuntimeCall)
    if length(call.backtrace) == 0
        Base.printstyled(io, "Allocating runtime call", color=:red, bold=true)
        # TODO: Even when backtrace fails, we should report at least 1 stack frame
        Base.println(io, " to \"", call.name, "\" in unknown location")
    else
        Base.printstyled(io, "Allocating runtime call", color=:red, bold=true)
        Base.println(io, " to \"", call.name, "\" in ", call.backtrace[1].file, ":", call.backtrace[1].line)
        show_backtrace_and_excerpt(io, call.backtrace)
    end
end

struct DynamicDispatch
    backtrace::Vector{Base.StackTraces.StackFrame}
end

function Base.hash(self::DynamicDispatch, h::UInt)
    return nice_hash(self.backtrace, h)
end

function Base.:(==)(self::DynamicDispatch, other::DynamicDispatch)
    return nice_isequal(self.backtrace,other.backtrace)
end

function Base.show(io::IO, dispatch::DynamicDispatch)
    if length(dispatch.backtrace) == 0
        Base.printstyled(io, "Dynamic dispatch", color=:red, bold=true)
        # TODO: Even when backtrace fails, we should report at least 1 stack frame
        Base.println(io, " in unknown location")
    else
        Base.printstyled(io, "Dynamic dispatch", color=:red, bold=true)
        Base.println(io, " in ", dispatch.backtrace[1].file, ":", dispatch.backtrace[1].line)
        show_backtrace_and_excerpt(io, dispatch.backtrace)
    end
end

struct AllocationSite
    type::Any
    backtrace::Vector{Base.StackTraces.StackFrame}
end

function nice_hash(backtrace::Vector{Base.StackTraces.StackFrame}, h::UInt)
    # `func_id` - Uniquely identifies this function (a method instance in julia, and
    # a function in C/C++).
    # Note that this should be unique even for several different functions all
    # inlined into the same frame.
    for frame in backtrace
        h = if frame.linfo !== nothing
            hash(frame.linfo, h)
        else
            hash((frame.func, frame.file, frame.line, frame.inlined), h)
        end
    end
    return h
end


function nice_isequal(self::Vector{Base.StackTraces.StackFrame}, other::Vector{Base.StackTraces.StackFrame})
    if length(self) != length(other)
        return false
    end
    for (a, b) in zip(self, other)
        if a.linfo !== b.linfo
            return false
        end
        if a.func !== b.func
            return false
        end
        if a.file !== b.file
            return false
        end
        if a.line !== b.line
            return false
        end
        if a.inlined !== b.inlined
            return false
        end
    end
    return true
end

function Base.hash(alloc::AllocationSite, h::UInt)
    return Base.hash(alloc.type, nice_hash(alloc.backtrace, h))
end

function Base.:(==)(self::AllocationSite, other::AllocationSite)
    return (self.type == other.type) && (nice_isequal(self.backtrace,other.backtrace))
end

function Base.show(io::IO, alloc::AllocationSite)
    if length(alloc.backtrace) == 0
        Base.printstyled(io, "Allocation", color=:red, bold=true)
        # TODO: Even when backtrace fails, we should report at least 1 stack frame
        Base.println(io, " of ", alloc.type, " in unknown location")
    else
        Base.printstyled(io, "Allocation", color=:red, bold=true)
        Base.println(io, " of ", alloc.type, " in ", alloc.backtrace[1].file, ":", alloc.backtrace[1].line)

        show_backtrace_and_excerpt(io, alloc.backtrace)
    end
end

struct AllocCheckFailure
    allocs::Vector
end

function Base.show(io::IO, failure::AllocCheckFailure)
    Base.println(io, "@check_alloc function contains ", length(failure.allocs), " allocations.")
end

function show_backtrace_and_excerpt(io::IO, backtrace::Vector{Base.StackTraces.StackFrame})
    # Print code excerpt of callation site
    try
        source = open(fixup_source_path(backtrace[1].file))
        Base.print(io, "  | ")
        Base.println(io, strip(readlines(source)[backtrace[1].line]))
        close(source)
    catch
        Base.print(io, "  | (source not available)")
    end

    # Print backtrace
    Base.show_backtrace(io, backtrace)
    Base.println(io)
end
