# It's amazing how often I need this
pathsep = Sys.iswindows() ? ";" : ":";

function env_dir(name::String)
    dir = joinpath(dirname(@__DIR__), "envs", name)
    mkpath(dir)
    return dir
end
rm_env(env_name::String) = rm(env_dir(env_name); force=true, recursive=true)

function with_pyenv(f::Function, env_name::String)
    PYTHONPATH = env_dir(env_name)
    if haskey(ENV, "PYTHONPATH")
        PYTHONPATH *= pathsep * ENV["PYTHONPATH"]
    end

    PATH = joinpath(env_dir(env_name), "bin") * pathsep * ENV["PATH"]
    withenv("PYTHONPATH" => PYTHONPATH, "PATH" => PATH) do
        python() do py_exe
            f(py_exe)
        end
    end
end

function with_artifacts_pyenv(f::Function, artifacts_toml::String)
    # Read in generated toml file    
    toml = Pkg.Artifacts.load_artifacts_toml(artifacts_toml)

    # Add all normal packages to PYTHONPATH
    hashes = [artifact_meta(k, toml, artifacts_toml)["git-tree-sha1"] for k in keys(toml) if k != "bin"]
    PYTHONPATH = artifact_path.(Base.SHA1.(hashes))
    if haskey(ENV, "PYTHONPATH")
        push!(PYTHONPATH, ENV["PYTHONPATH"])
    end
    PYTHONPATH = join(PYTHONPATH, pathsep)

    # Add special `bin` packages to PATH
    PATH = ENV["PATH"]
    if haskey(toml, "bin")
        PATH = joinpath(artifact_path(Base.SHA1(toml["bin"]["git-tree-sha1"])), "bin") * pathsep * PATH
    end

    withenv("PYTHONPATH" => PYTHONPATH, "PATH" => PATH) do
        python() do py_exe
            f(py_exe)
        end
    end
end


verify(path::String, hash::Vector{UInt8}) = hash == open(SHA.sha256, path, "r")
function download_verify(url::String, hash::Vector{UInt8}, path::String)
    if isfile(path)
        if !verify(path, hash)
            rm(path; force=true)
        else
            return true
        end
    end

    try
        open(path, "w") do io
            HTTP.get(url, response_stream=io)
        end
    catch e
        rm(path; force=true)
        rethrow(e)
    end
    
    if !verify(path, hash)
        error("Bad download for $(url)")
    end
end