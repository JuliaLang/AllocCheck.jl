using Documenter, AllocCheck

makedocs(
      sitename = "AllocCheck Documentation",
      doctest = false,
      modules = [AllocCheck],
      warnonly = [:missing_docs],
      pages = [
            "Home" => "index.md",
            "Tutorials" => [
                  "Optional debugging and logging" => "tutorials/optional_debugging_and_logging.md",
                  "Hot loops" => "tutorials/hot_loop.md",
                  "Minimum latency error recovery" => "tutorials/error_recovery.md",
            ],
            "API" => "api.md",
      ],
      format = Documenter.HTML(prettyurls = haskey(ENV, "CI")),
)

deploydocs(
      repo = "github.com/JuliaComputing/AllocCheck.jl.git",
      push_preview = true,
)
