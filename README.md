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
CondaPkg.add_pip("ggblab", version="@ file://.ggblab-1.7.2-py3-none-any.whl")
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

Standalone comm_bridge note & planned extraction
-----------------------------------------------

A practical note about current architecture and a potential refactor:

- The `comm_bridge` component can operate independently as a kernel↔frontend
  conduit even if the GeoGebra `AppletInjector` is not called. In other
  words, the bridge continues to function as a communication channel when
  the injector is not instantiated.

- During recent refactoring we extracted `ggblab_core`/`ggblab_core2` and
  `comm_bridge` into separate components. We are considering (but not
  implementing now) extracting the frontend-side `callRemoteSocketSend`
  helper out of the monolithic frontend and publishing it as a small,
  reusable frontend helper that pairs directly with `comm_bridge`.

- The intended outcome of that future work would be:
  1. A minimal frontend helper exposing a safe `callRemoteSocketSend`
     API and an optional small global export for WebIO/JS handlers.
  2. Pairing that helper with `comm_bridge` so frontends and kernels can
     communicate via the OOB socket without pulling in the entire ggblab
     frontend stack.
  3. Rebuilding ggblab on top of this pair to restore full functionality
     while keeping the bridge and helper reusable for other projects.

- This is a design note only; it is not implemented in the current
  release. If you would like to see this extraction implemented, please
  open an issue or submit a pull request describing the desired API and
  packaging constraints.

Why WebIO works but Interact.jl often does not
-----------------------------------------------

Short explanation of the practical difference and current limitations:

- `WebIO.jl` primarily provides a rendering layer that injects DOM nodes
  and JavaScript into the browser. It is able to run JS event handlers on
  the client side and can call back to kernel-side code when a working
  communication path exists. Because our current architecture exposes a
  socket-based OOB (out‑of‑band) bridge that the browser can reach via
  the console/kernel `requestExecute` pattern, simple WebIO-based UI
  elements and JS handlers can be made to work by calling that bridge
  (for example, via the `ggblab.listen` helper).

- `Interact.jl` builds higher-level, two-way widget abstractions on top of
  `WebIO` and the Jupyter Comm system: it expects a live, bidirectional
  comm channel between the kernel process and the frontend so that
  `Observable` values synchronize automatically. In many deployment
  scenarios (multi-process Julia setups, kernels started via the
  console, or environments behind reverse proxies/CORS policies like
  some JupyterHub setups) the native kernel↔frontend comm manager is not
  directly accessible to Julia processes or to widget subprocesses.

- Practically this means `Interact.jl`'s seamless two‑way bindings fail
  when the kernel process cannot register or receive comm messages in
  the usual way. WebIO can still deliver one‑way JS handlers and DOM
  insertion, but full Interact functionality that relies on the kernel's
  comm manager (automatic `Observable` sync, widget state restored via
  comms) is not available without a restored direct comm channel.

- The current recommended workaround is to route frontend events through
  the `comm_bridge` (via `requestExecute`-issued sends or the
  `callRemoteSocketSend` helper) and update server-side state explicitly
  (e.g. updating `shared_objects` and broadcasting diffs). This restores
  a usable UI→kernel loop at the cost of the tight, automatic two‑way
  binding Interact normally provides.

