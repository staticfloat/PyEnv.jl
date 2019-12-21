# Scrape the PyPI index for the list of python package names
function scrape_pypi_index()
    r = HTTP.get("https://pypi.org/simple/")
    if r.status != 200
        error("Got response code $(r.status)")
    end
    html = Gumbo.parsehtml(String(r.body))
    package_names = String[]
    for elem in AbstractTrees.PostOrderDFS(html.root)
        if isa(elem, HTMLElement) && tag(elem) == :a && haskey(elem.attributes, "href")
            m = match(r"/simple/([^/]+)/", elem.attributes["href"])
            if m !== nothing
                name = m.captures[1]
                # We immediately drop anything that is not a valid Julia package name,
                # since we will have a hard time slapping them into the registry.
                if Base.isidentifier(name)
                    push!(package_names, name)
                end
            end
        end
    end
    return package_names
end

blacklist = Set{String}()
function get_package_info(name::String; force::Bool = false)
    # avoid getting 404's over and over again
    if name in blacklist
        return nothing
    end

    try
        r = HTTP.get("https://pypi.python.org/pypi/$name/json")
        return JSON.parse(String(r.body))
    catch e
        if isa(e, HTTP.ExceptionRequest.StatusError) && e.status == 404
            push!(blacklist, name)
            @error("Unable to get info on $name")
            return nothing
        end
        rethrow(e)
    end
end

get_wheel_releases(name::String; kwargs...) = get_wheel_releases(get_package_info(name); kwargs...)
function get_wheel_releases(pkg::Dict; pkg_version = nothing)
    # Grab the releases belonging to the version requested
    pkg_version = String(something(pkg_version, pkg["info"]["version"]))
    releases = pkg["releases"][pkg_version]

    # Only look at `bdist_wheel` packages
    filter!(r -> r["packagetype"] == "bdist_wheel", releases)

    # If there are any, return it!
    if !isempty(releases)
        return releases
    end

    # Otherwise return nothing
    return Dict[]
end

function dist_info_path(env_name::String, pkg_name::String, pkg_version::String)
    return joinpath(env_dir(env_name), "$(pkg_name)-$(pkg_version).dist-info")
end

# Directly install a package; don't do any version resolution or even install any dependencies
function direct_install(env_name::String, pkg::Dict; pkg_version = nothing, python_abi::WheelABI = default_python_abi())
    pkg_name = pkg["info"]["name"]
    pkg_version = String(something(pkg_version, pkg["info"]["version"]))
    if isdir(dist_info_path(env_name, pkg_name, pkg_version))
        return true
    end

    wheels = get_wheel_releases(pkg; pkg_version=pkg_version)
    if isempty(wheels)
        @error("Unable to find any wheel releases at all for \"$(pkg_name)\"")
        return false
    end

    wheel = find_matching_wheel(wheels, python_abi)
    if wheel === nothing
        @error("Unable to find matching wheel for $(python_abi)")
        return false
    end

    # Download/extract it
    url = wheel["url"]
    hash = hex2bytes(wheel["digests"]["sha256"])
    mktempdir() do dir
        zipfile = joinpath(dir, basename(url))
        download_verify(url, hash, zipfile)

        cd(env_dir(env_name)) do
            run(pipeline(`7z -y x $(zipfile)`, stdout=devnull))
        end
    end
    return true
end


function freeze(env_name::String)
    pkgs = Tuple[]
    # Find all the ".dist-info" and ".egg-info" directories
    env_files = readdir(env_dir(env_name))
    dist_infos = filter(d -> endswith(d, ".dist-info") || endswith(d, ".egg-info"), env_files)
    for d in dist_infos
        dabs = joinpath(env_dir(env_name), d)

        # Try to parse out `top_level.txt`
        top_level_path = joinpath(dabs, "top_level.txt")
        if !isfile(top_level_path)
            # See if we can guess the name from the dist-info/egg-info
            m = match(r"^([^-]+)-", d)
            if m === nothing || !isdir(joinpath(env_dir(env_name), m.captures[1]))
                @warn("Skipping $(d) as it doesn't have a top_level.txt and we can't guess the package name")
                continue
            end
            pkg_names = [m.captures[1]]
        else
            pkg_names = chomp.(String.(readlines(top_level_path)))
        end

        # Let's see if we can determine the platform-specificity of this package
        platform = AnyPlatform()
        wheel_file_path = joinpath(dabs, "WHEEL")
        if isfile(wheel_file_path)
            tag_lines = filter(l -> startswith(l, "Tag: "), readlines(wheel_file_path))
            if !isempty(tag_lines)
                m = match(r"([^-]+)$", first(tag_lines))
                if m !== nothing
                    platform = parse_wheel_tag(m.captures[1])
                end
            end
        end

        # Extract overall version of source package
        m = match(r"^.*-([\d\.]+(?:(?:a|b|rc)\d+)?)(?:-|\.).*-info", d)
        if m === nothing
            @warn("Couldn't extract version number from $(d)")
            continue
        end
        version = m.captures[1]

        # Vacuum up each top-level package that matches the given `pkg_names`
        for pkg_name in pkg_names
            # These can be named many things. We look for:
            # - directories name `pkg_name`
            # - files named `$(pkg_name).py`
            # - files named `$(pkg_name)*.$(dlext)`
            if isdir(joinpath(env_dir(env_name), pkg_name))
                push!(pkgs, (d, pkg_name, version, platform))
            elseif isfile(joinpath(env_dir(env_name), pkg_name * ".py"))
                push!(pkgs, (d, pkg_name * ".py", version, platform))
            else
                poss_dylibs = filter(f -> startswith(f, pkg_name) && f != d && endswith(f, Libdl.dlext), env_files)
                if length(poss_dylibs) == 1
                    push!(pkgs, (d, first(poss_dylibs), version, platform))
                else
                    @warn("Couldn't find $(pkg_name) while freezing $(env_name)")
                end
            end
        end
    end
    return sort(pkgs, by = p -> p[1])
end

#=
function collect_wheel_deps(env_name::String, pkg_name::String, pkg_version::String)
    metadata_file = joinpath(dist_info_path(env_name, pkg_name, pkg_version), "METADATA")
    deps = [d[15:end] for d in readlines(metadata_file) if startswith(d, "Requires-Dist: ")]
    return deps
end

function parse_dep(dep::String)
    m = match(r"([\w\d\-\.]+)\s*(?:\((.*)\))?\s*(;.*)?", dep)
    if m === nothing
        error("Unable to parse $(dep)")
    end
    dep_name = String(m.captures[1])
    dep_version = String(something(m.captures[2], "*"))

    # There can be multiple 
    m = match(r"^(.*[\d\.]+)((?:a|b|rc)\d+)$", v)

    # Unfortunately our semver_spec is much stricture than python's.  We play it fast and loose here
    # to try and get a reasonable version bound
    function fixup_version_bounds(v)
        v = replace(replace(v, ">=" => ">"), "<" => "<=")
        
        # We also need to convert things like `1.0rc1` or `2.3a` to semver-compatible:
        
        if m !== nothing
            return string(m.captures[1], "-", m.captures[2])
        end
    end
    dep_version = fixup_version_bounds(dep_version)
    
end

collect_depslist(name::String; kwargs...) = collect_depslist(get_package_info(name); kwargs...)
function collect_depslist(pkg::Dict; extra_target = nothing, python_abi = default_python_abi())
    collected_deps = [(pkg["info"]["name"], pkg["info"]["version"])]
    for dep in something(pkg["info"]["requires_dist"], String[])
        # Collect all the deps
        m = match(r"([\w\d\-\.]+)\s*(\(.*\))?\s*(;.*)?", dep)
        if m !== nothing
            dep_name = String(m.captures[1])
            dep_version = String(something(m.captures[2], ""))

            dep_extra_target = nothing
            dep_python_version_bound = nothing
            extras = m.captures[3]
            if extras !== nothing
                # Parse out the extra stuff
                extra_m = match(r"extra == '(.*)'", extras)
                if extra_m !== nothing
                    dep_extra_target = extra_m.captures[1]
                end
                extra_m = match(r"python_version (<|>|<=|>=) \"(.*)\"", extras)
                if extra_m !=- nothing
                    dep_python_version_bound = extra_m.captures[1]
                end
            end
            dep_extra_target = m.captures[4]
            if dep_extra_target === nothing || dep_extra_target == extra_target
                # First, push this dep and version string (maybe) onto our list
                push!(collected_deps, (dep_name, dep_version))
            end
        end
    end
    return collected_deps
end
=#
