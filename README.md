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

Alternatively, when running JupyterLab with this extension installed you can
start the bridge from the JupyterLab Launcher: open Launcher → Other and
click the "GeoGebra (comm_bridge)" tile. The launcher action starts the
bridge server and injects the GeoGebra applet into the current kernel so it
is immediately available to Julia clients via the bridge.

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

Using ggblab from Julia via PythonCall + CondaPkg
------------------------------------------------

You can install the Python `ggblab` package into a Conda-managed
environment from within Julia using `CondaPkg`, then access it via
`PythonCall`. This allows most ggblab Python functionality to be used
directly from Julia:

```julia
using CondaPkg
# install from a local wheel (example); adjust path/version as needed
CondaPkg.add_pip("ggblab", version="@ file://.ggblab-1.7.1-py3-none-any.whl")
```

```julia
using PythonCall
ggb = pyimport("ggblab")
ggb.connect_to_bridge()

@await ggb.function("getVersion")
```

You can also use `ggblab_extra` utilities from Julia:

```julia
ggbex = pyimport("ggblab_extra")
ConstructionIO = ggbex.ConstructionIO
df = @await ConstructionIO.initialize_dataframe(ggb, use_applet=true)
```

Note: make sure the Python environment into which you install `ggblab`
is the same kernel environment that runs JupyterLab (or the one your
bridge connects to) so the bridge and injected applet are available.

IJulia `Comm` and subprocess limitations
---------------------------------------

IJulia's `Comm` implementation uses `PythonCall` as a bridge to reach
Python-level `ipykernel.comm` objects when Julia and the kernel are
running in the same process. However, when Julia or helper code runs in
subprocesses, those subprocesses do not share the same JupyterLab
services and comm manager as the kernel process. This means direct
subprocess-originated Comm connections cannot reliably reach the
JupyterLab frontend.

To work around this, `GeoGebra.jl` uses the separate `comm_bridge`
TCP/JSON bridge (the `comm_bridge.server` implementation). The bridge
accepts JSON messages over a local socket and forwards them to the
kernel's comm manager, allowing external processes (including Julia
subprocesses or other languages) to interoperate with the JupyterLab
applet even when they cannot attach a native `ipykernel.comm`.

Security and JupyterHub
-----------------------

For security, the bridge binds only to localhost on a dynamically chosen
local port (not a well-known or publicly routable port). The bridge is
intended for use by local clients on the same host; it does not expose
services to the network by default. This minimizes exposure even when
used on multi-user JupyterHub deployments. When running under
JupyterHub, `GeoGebra.jl` (and other local Julia processes) can still
communicate with the injected GeoGebra applet through the bridge because
the bridge forwards messages into the kernel's comm manager. Ensure your
JupyterHub configuration restricts access to the notebook server's host
and ports according to your site security policy.
