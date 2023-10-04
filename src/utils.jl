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
    return Base.fixup_stdlib_path(file)
end
