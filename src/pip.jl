# We can't always do everything directly; sub out to `pip` for some things.
function pip(cmd)
    with_pyenv("_internal") do py_exe
        run(`$py_exe -m pip $(cmd)`)
    end
end

# Install something with `pip`
function pip_install(env_name::String, pkg_name::String)
    pip([
        "install",
        #"--only-binary=:all:",
        "--prefer-binary",
        "--upgrade",
        "--target=$(env_dir(env_name))",
        pkg_name,
    ])
end