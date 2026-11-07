# This file is a part of Julia. License is MIT: https://julialang.org/license

# Set up the environment that the test suite runs in, for this process and every process it
# starts, whether it was started by `make` or by `Base.runtests`. This must run before any
# package is loaded.
#
# The tests get a fresh depot, followed by the default depots so that the bundled stdlib
# caches can still be loaded, so that they don't write to (or read stale state from) the
# user's or the bundled depot. When given `--buildroot`, the depot is kept in the build tree
# rather than $TMPDIR, which may be a small tmpfs. Set `JULIA_TEST_KEEP_DEPOT_PATH` to keep
# the depot path the tests were started with (`make relocatedepot` relocates the caches its
# first run writes to the bundled depot).
let pathsep = Sys.iswindows() ? ";" : ":"
    if !haskey(ENV, "JULIA_TEST_KEEP_DEPOT_PATH")
        i = findlast(startswith("--buildroot="), ARGS)
        depot = if i === nothing
            mktempdir()
        else
            parent = joinpath(ARGS[i][(length("--buildroot=") + 1):end], "tmp")
            mkpath(parent)
            mktempdir(parent)
        end
        ENV["JULIA_DEPOT_PATH"] = string(depot, pathsep)
        Base.init_depot_path()
    end
    ENV["JULIA_LOAD_PATH"] = string("@", pathsep, "@stdlib")
    Base.init_load_path()
    delete!(ENV, "JULIA_PROJECT")
    Base.init_active_project() # keeps `--project`, if given
    ENV["JULIA_TESTS"] = "true"
end
