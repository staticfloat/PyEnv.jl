# This should probably be in Pkg.BinaryPlatforms.  :/
struct AnyPlatform <: Platform; end
Pkg.BinaryPlatforms.platform_name(p::AnyPlatform) = "any"
Base.show(io::IO, p::AnyPlatform) = write(io, "any")

struct WheelABI
    versions::Vector{String}
    abi_flags::Vector{Symbol}
    platform::Platform
end

# This is locked to Python_jll
default_python_abi() = WheelABI(["3.8"], Symbol[], platform_key_abi())

function parse_wheel_tag(platform_tag::AbstractString)
    if startswith(platform_tag, "macosx_")
        return MacOS()
    elseif startswith(platform_tag, "manylinux")
        if occursin("i686", platform_tag)
            return Linux(:i686)
        elseif occursin("x86_64", platform_tag)
            return Linux(:x86_64)
        end
    elseif startswith(platform_tag, "win")
        if platform_tag == "win32"
            return Windows(:i686)
        elseif platform_tag == "win_amd64"
            return Windows(:x86_64)
        end
    elseif platform_tag == "any"
        return AnyPlatform()
    end
    return UnknownPlatform()
end

function parse_wheel_filename(filename::String)
    m = match(r"([^-]+)-([\d\.]+)-([^-]+)-([^-]+)-(.*)\.whl", filename)
    if m !== nothing
        name = m.captures[1]
        version = m.captures[2]
        python_tags = m.captures[3]
        abi_tag = m.captures[4]
        platform_tag = m.captures[5]

        # Take a look at the python tag to determine the relevant python version
        python_versions = String[]
        for python_tag in split(python_tags, ".")
            python_version = match(r"c?py?([\d]*)", python_tag)
            if python_version === nothing
                return nothing
            end
            push!(python_versions, join(split(python_version.captures[1], ""), "."))
        end

        # Extract important ABI flags like debug, pymalloc, and wide unicode
        abi_flags = Symbol[]
        abi_m = match(r"cp\d+(d)?(m)?(u)?", abi_tag)
        if abi_m !== nothing
            abi_m.captures[1] !== nothing && push!(abi_flags, :debug)
            abi_m.captures[2] !== nothing && push!(abi_flags, :malloc)
            abi_m.captures[3] !== nothing && push!(abi_flags, :wide_unicode)
        end

        # Parse out platform tag to get the Platform object
        platform = parse_wheel_tag(platform_tag)

        return WheelABI(python_versions, abi_flags, platform)
    end
end

function is_matching_wheel(wheel_abi::WheelABI, python_abi::WheelABI)
    # First, check python versions match (up to the smallest common length)
    pv = python_abi.versions[1]
    lpv = length(pv)
    if !any(v[1:min(length(v), lpv)] == pv[1:min(length(v), lpv)] for v in wheel_abi.versions)
        return false
    end

    # Next, check that ABI flags match
    if any(wheel_abi.abi_flags .!== python_abi.abi_flags)
        return false
    end

    # Finally, ensure that the platforms match
    return isa(wheel_abi.platform, AnyPlatform) ||
           platforms_match(wheel_abi.platform, python_abi.platform)
end

function find_matching_wheel(wheels::Vector, python_abi::WheelABI)
    for wheel in wheels
        wheel_abi = parse_wheel_filename(wheel["filename"])
        if is_matching_wheel(wheel_abi, python_abi)
            return wheel
        end
    end
    return nothing
end

function artifactify_env(env_name::String, artifacts_toml::String)
    for (d, pkg_src, pkg_version, platform) in freeze(env_name)
        art_hash = create_artifact() do dir
            # Copy the metadata directory
            cp(joinpath(env_dir(env_name), d), joinpath(dir, d))

            # Copy the package source
            cp(joinpath(env_dir(env_name), pkg_src), joinpath(dir, pkg_src))
        end
        art_name = "$(pkg_src)-$(pkg_version)"
        art_platform = isa(platform, AnyPlatform) ? nothing : platform
        bind_artifact!(
            artifacts_toml,
            art_name,
            art_hash;
            platform = art_platform,
            force = true,
        )
    end

    # Special-case `bin`:
    bindir = joinpath(env_dir(env_name), "bin")
    if isdir(bindir)
        art_hash = create_artifact() do dir
            mkpath(joinpath(dir, "bin"))
            for f in readdir(bindir)
                src = joinpath(bindir, f)
                dst = joinpath(dir, "bin", f)
                cp(src, dst)
                chmod(dst, stat(src).mode)
            end
        end
        bind_artifact!(
            artifacts_toml,
            "bin",
            art_hash;
            force = true,
        )
    end
    return
end

function build_artifact_env(f::Function, artifacts_toml::String)
    env_name = randstring(8)
    f(env_name)
    artifactify_env(env_name, artifacts_toml)
    rm_env(env_name)
    return
end