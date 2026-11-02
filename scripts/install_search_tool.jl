import Pkg

manifest=joinpath(@__DIR__,"..","Artifacts.toml")
Pkg.Artifacts.ensure_artifact_installed("fd",manifest)
