GeoGebra.jl
===========

This directory contains the Julia package `GeoGebra` used by the `ggblab`
project. It provides a lightweight TCP/JSON bridge client to communicate
with a GeoGebra applet via the `comm_bridge` Python bridge.

Repository
----------

The canonical repository is hosted at:

https://github.com/moyhig-ecs/GeoGebra.jl

Installation (from GitHub)
--------------------------

Install directly from GitHub using the repository URL (no trailing `.git` needed):

```julia
using Pkg
Pkg.add(url="https://github.com/moyhig-ecs/GeoGebra.jl")
```

Dependency note
---------------

`GeoGebra.jl` expects the Python `ggblab` package to be available in the
same JupyterLab Python 3 kernel that will host the GeoGebra applet. In practice
this means installing `ggblab` into the kernel environment that your Jupyter
server uses.

1) In the Python 3 kernel that runs JupyterLab, install `ggblab` (for example):

```bash
pip install ggblab
# or, if developing locally:
pip install -e /path/to/ggblab
```

2) Start the bridge server from Python to enable the Julia client to reach
the applet. Example using the ggblab core helper:

```python
from ggblab_core import AppletInjector
info = AppletInjector.start_proxy_mode()
```

Once the bridge is running and the GeoGebra applet has been injected into the
`ggblab`-managed JupyterLab kernel, you can use the Julia client as follows.

Julia usage examples
--------------------

```julia
using GeoGebra

# call an API function
@ggb api getVersion()

# send commands and assign returned objects
@ggb :O = (0,0)
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
  this directory). After creating the GitHub repository for `GeoGebra.jl`,
  push this directory as the repository root so `Pkg.add(url=...)` works.
