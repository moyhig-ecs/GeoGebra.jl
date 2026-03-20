# GeoGebra.jl — README tail backup (lines 72-end)

This file preserves the original latter portion of `README.md` that was
present prior to a summary-first rewrite. It can be used to restore or
reference the full original documentation.

----

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

IJulia's `Comm` implementation talks directly with the kernel's
ZMQ/ipykernel comm layer and is compatible with modern JupyterLab (including
JupyterLab 4). In typical single-process setups where the Julia session is
the kernel process, `IJulia` comms work as expected and provide a low-latency
bidirectional channel to the frontend.

The limitation arises when Julia code is executed in a separate subprocess or
from a process that does not share the kernel process and its comm manager.
In those multi-process or out-of-process scenarios the subprocess cannot
register comms on the kernel's comm manager, so direct `ipykernel.comm`
connections from the subprocess will not reach the frontend.

For these deployment cases (subprocess workers, external tools, or isolated
environments) the `comm_bridge` TCP/JSON bridge remains the reliable fallback:
it accepts JSON messages over a local socket and forwards them into the
kernel's comm manager so external processes can interoperate with the
JupyterLab applet even when they cannot attach a native `ipykernel.comm`.

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

Pending: WebIO / comm send-side implementation
-----------------------------------------------

- Note (pending): while `IJulia` comms work in standard kernel-hosted
  sessions, some deployment scenarios (multi-process Julia setups,
  subprocess workers, reverse-proxy or restricted environments) can prevent
  direct comm connectivity. In those cases routing events through the
  `comm_bridge` or using explicit socket-based helpers remains the most
  portable approach.

  A potential enhancement is to provide a small frontend helper that can
  route outgoing messages into the OOB bridge (for example via a
  lightweight `callRemoteSocketSend` helper). The current `OOBClient`
  implementation focuses on receive-side delivery; adding a robust
  send-side integration requires coordinated frontend and kernel changes
  and remains a planned improvement rather than a shipped feature.

Why an OOB (out‑of‑band) channel is still needed
-----------------------------------------------

Although `IJulia` comms allow the Julia kernel to inject the GeoGebra
applet and send synchronous requests in a typical kernel-hosted session,
we observed that comm receive handlers in both the Python and Julia
implementations are not invoked until the originating cell's execution
completes. This means code that expects immediate, in-band replies during
long-running cell execution can block or miss timely callbacks. For this
reason the `comm_bridge` OOB channel remains necessary: it forwards
messages into the kernel's comm manager via a separate socket and allows
the frontend and external processes to exchange messages without relying
on the kernel's single-threaded cell execution lifecycle. In short —
`IJulia` comms work for injection and low-latency interactions, but the
OOB bridge is required for robust cross-process and real-time reply
delivery in the kinds of workflows ggblab supports.

WebIO.jl patch and availability
-------------------------------

During investigation we found that `WebIO.jl`'s use of `IJulia` IPython
Comm was not the root cause in our environment. A separate interoperability
issue prevented the shipped `WebIO.jl` behavior from working as expected,
so a private compatibility patch was developed and published to a fork for
users needing the fix immediately. The patched package can be obtained from:

https://github.com/moyhig-ecs/WebIO.jl

Note: a PR has been submitted upstream but was not merged in time for our
release, so the fork is provided as a stopgap until upstream incorporates
the changes.

Interact.jl status
------------------

`Interact.jl` fails in this repository for a different set of reasons (mainly
around widget lifecycle and environment-specific comm registration) and has
not yet been addressed. Work on `Interact.jl` compatibility is planned but
outstanding.

----
