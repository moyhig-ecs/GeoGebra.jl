GeoGebra.jl
===============

This directory contains the Julia client `GeoGebra` used by the ggblab
project. It is a lightweight TCP/JSON bridge client that communicates
with a GeoGebra frontend.

Installation (from GitHub)
--------------------------

Replace `<owner>` with the GitHub user or org that hosts the package.

```julia
using Pkg
Pkg.add(url="https://github.com/<owner>/GeoGebra.jl.git")
```

Developer workflow (local)
--------------------------

To work locally without publishing, use:

```julia
using Pkg
Pkg.develop(path="/path/to/ggblab/julia/GeoGebra.jl")
```

Notes
-----
- Ensure `Project.toml` and `src/GeoGebra.jl` are present (they are in
  this directory). After creating a GitHub repository for `GeoGebra.jl`,
  push this directory as the repository root so `Pkg.add(url=...)` works.
