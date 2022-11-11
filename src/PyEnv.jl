module PyEnv
using Python_jll, HTTP, JSON, Random, Libdl, Scratch
using Gumbo, AbstractTrees
using Pkg, Pkg.Artifacts, SHA

# Re-export `python()` from `Python_jll` for easy access
export python

export env_dir, with_pyenv, with_artifacts_pyenv, direct_install, pip_install, build_artifact_env

include("utils.jl")
include("artifacts.jl")
include("direct.jl")
include("pip.jl")

function __init__()
    # We always make sure we have `pip` and `setuptools` available to us in the `_internal` env:
    direct_install("_internal", get_package_info("pip"))
    direct_install("_internal", get_package_info("setuptools"))
end

end # module
