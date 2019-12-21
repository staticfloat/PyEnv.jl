# PyEnv

An experiment in using Artifacts to provide Julia-compatible, archivable Python environments.

## Usage

Easiest usage is to set up an environment, adjust it to your needs, then save it out to an `Artifacts.toml` file.  Example:

```julia
using PyEnv
ds_artifacts_toml = "./data_science.artifacts.toml"
if !isfile(ds_artifacts_toml)
    # If the toml doesn't exist, create it
    build_artifact_env(ds_artifacts_toml) do env
        pip_install(env, "numpy")
        pip_install(env, "matplotlib")
        pip_install(env, "ipython")
    end
end

# Use the artifacts to setup PYTHONPATH and run matplotlib/numpy things
with_artifacts_pyenv(ds_artifacts_toml) do py_exe
    cmd = """
    import matplotlib.pyplot as plt
    import numpy as np

    plt.plot(np.random.randn(1024))
    plt.savefig("test.png")
    """
    run(`$py_exe -c $cmd`)
end
```

You can do anything you like within the `with_artifacts_pyenv()` wrapper function, including calling scripts that the python packages installed:
```julia
# Alternatively, just run `ipython` since we installed it, after all
with_artifacts_pyenv(ds_artifacts_toml) do py_exe
    run(`ipython`)
end
```

## Caveats

There's a lot wrong with this package, and I don't recommend it for anything other than curiosity.  Here are the things that need to be improved:

* It's currently not possible to know what dependencies a python package has.  PyPI gives us a tantalizing glimpse at a possible future where this exists through its `metadata["info"]["dist_requires"]` keys, however those aren't tied to any particular version (I believe they are a "best guess" at the current version) and so are semi-useless if you happen to need to install an older version.  This makes resolution rather difficult, which is why we provide only two ways to install things in this package: `direct_install()` (which does not install dependencies) and `pip_install()` (where we use a previously-`direct_install()`'ed `pip` to do installation for us).

* When building an `Artifacts.toml`, we really should build mappings for _all_ platforms.  However, to do this, we'd need to either solve our dependency problems above (so that we can statically determine which pacakges need to be installed without running arbitrary python code) or, equivalently, we'd need to use `pip`'s `--only-binary` option so that we could install everything using wheel binaries (which don't require running python code on the user's machine).  Since both of these are impossible (due to the same underlying cause; non-modern python packages that do not use wheels to distribute statically-decidable package graphs) we can only build mappings for a single platform at a time, which severely hampers the utility of baking things into `Artifact.toml` files at all.

* The artifacts that are created are not uploaded anywhere.  We'd need to do that to make this useful.

* Ideally we'd statically look at the dependency graph, identify the necessary wheels, and record those directly as zipped artifact download sources.  To do this, we need to (a) be able to only use wheels (still somewhat impractical) and (b) download `.zip` files as artifacts.