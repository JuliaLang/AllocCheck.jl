using Base64

file_exists_at(x) = try isfile(x); catch; false end
const BUILDBOT_STDLIB_PATH = dirname(abspath(String(pathof(Base64)), "..", "..", ".."))
replace_buildbot_stdlibpath(str::String) = replace(str, BUILDBOT_STDLIB_PATH => Sys.STDLIB)

"""
    path = fixup_stdlib_source_path(path::String)

Return `path` corrected for julia issue [#26314](https://github.com/JuliaLang/julia/issues/26314) if applicable.
Otherwise, return the input `path` unchanged.

Due to the issue mentioned above, location info for methods defined one of Julia's standard libraries
are, for non source Julia builds, given as absolute paths on the worker that built the `julia` executable.
This function corrects such a path to instead refer to the local path on the users drive.
"""
function fixup_stdlib_source_path(path)
    if !file_exists_at(path)
        maybe_stdlib_path = replace_buildbot_stdlibpath(path)
        file_exists_at(maybe_stdlib_path) && return maybe_stdlib_path
    end
    return path
end


"""
    path = fixup_source_path(path)

Return a normalized, absolute path for a source file `path`.
"""
function fixup_source_path(file)
    file = string(file)
    if !isabspath(file)
        # This may be a Base or Core method
        newfile = Base.find_source_file(file)
        if isa(newfile, AbstractString)
            file = normpath(newfile)
        end
    end
    return fixup_stdlib_source_path(file)
end
