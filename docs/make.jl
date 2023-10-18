using Documenter, AllocCheck

makedocs(
      sitename = "AllocCheck Documentation",
      doctest = false,
      modules = [AllocCheck],
      warnonly = [:missing_docs],
      pages = [
            "Home" => "index.md",
            "API" => "api.md",
      ],
      format = Documenter.HTML(prettyurls = haskey(ENV, "CI")),
)

deploydocs(
      repo = "github.com/JuliaComputing/AllocCheck.jl.git",
)
