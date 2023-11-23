module TestAlloc

using AllocCheck
using Test

function AllocCheck._test_noalloc(__module__, __source__, expr, kws...)
    # Collect the broken/skip/ignore_throw keywords and remove them from the rest of keywords
    broken = [kw.args[2] for kw in kws if kw.args[1] === :broken]
    skip = [kw.args[2] for kw in kws if kw.args[1] === :skip]
    ignore_throw = [kw.args[2] for kw in kws if kw.args[1] === :ignore_throw]
    kws = filter(kw -> kw.args[1] ∉ (:skip, :broken, :ignore_throw), kws)
    # Validation of broken/skip keywords
    for (kw, name) in ((broken, :broken), (skip, :skip), (ignore_throw, :ignore_throw))
        if length(kw) > 1
            error("invalid test_noalloc macro call: cannot set $(name) keyword multiple times")
        end
    end
    if length(skip) > 0 && length(broken) > 0
        error("invalid test_noalloc macro call: cannot set both skip and broken keywords")
    end
    if !Meta.isexpr(expr, :call) || isempty(expr.args)
        error("invalid test_noalloc macro call: must be applied to a function call")
    end
    ex = Expr(:inert, Expr(:macrocall, Symbol("@test_noalloc"), nothing, expr))
    quote
        if $(length(skip) > 0 && esc(skip[1]))
            $(Test.record)($(Test.get_testset)(), $(Test.Broken)(:skipped, $ex))
        else
            result = try
                x = $(AllocCheck._check_allocs_call(
                    expr, __module__, __source__; ignore_throw = length(ignore_throw) == 0 || ignore_throw[1]))
                Base.donotdelete(x)
                $(Test.Returned)(true, nothing, $(QuoteNode(__source__)))
            catch err
                if err isa InterruptException
                    rethrow()
                elseif err isa AllocCheck.AllocCheckFailure
                    $(Test.Returned)(false, nothing, $(QuoteNode(__source__)))
                else
                    $(Test.Threw)(err, Base.current_exceptions(), $(QuoteNode(__source__)))
                end
            end
            test_do = $(length(broken) > 0 && esc(broken[1])) ? $(Test.do_broken_test) : $(Test.do_test)
            test_do(result, $ex)
        end
    end
end

end
