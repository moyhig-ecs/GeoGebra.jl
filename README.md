
# GeoGebra.jl — summary of current comm design and status

Backup: the previous README head (lines 1–71) has been moved to
`README_head_backup.md` for reference.

This document summarizes the current decisions and implementation status
for GeoGebra.jl comm transports. Follow-up items and the rationale are
kept concise below.

1) Frontend parsing & reply pairing
- Frontend (`src/comm/kernel_comm.ts`) was updated to accept both string
  and object payloads from the frontend and to include an incoming
  `req_id` in outgoing reply objects when present. This normalizes replies
  so the kernel-side pairing logic can match replies to requests.

2) Kernel-side direct comm pairing (opt-in)
- `julia/GeoGebra.jl/src/comm_direct.jl` implements per-request pending
  channels (`PENDING_REPLIES`) and a `send_and_wait_for_id` helper that
  attaches a `req_id` to outgoing messages and waits for a matching reply.
  The wait runs safely in a background task so comm callbacks are not
  blocked in the receive handler.

3) `@ggb` semantics and blocking considerations
- `GeoGebra._auto_request_handler` was switched to use `send_and_wait_for_id`
  so macros like `@ggb` can receive created values from the frontend without
  exposing `@async` to callers. However, we observed that kernel-side
  comm receive handlers are not always invoked during cell execution; they
  may run only after the cell completes. Because of that timing constraint
  synchronous in-band expectations can still time out in some environments.

4) Transport policy — `comm_bridge` default, direct comm pending
- To preserve compatibility with the Python `extra` module and to avoid
  user-facing timing failures, the repository currently uses the TCP
  `comm_bridge` as the default transport. The improved direct-comm path
  (with `req_id` pairing) remains implemented and available as an opt-in
  via `enable_direct_transport!()` for advanced users and experiments.

Next steps (short)
- Remove or gate diagnostic prints introduced during debugging.
- Add regression tests validating `req_id` pairing for both transports.
- Publish changes: pull/rebase to synchronize with remote, then push or
  create a feature branch if preferred to avoid rebasing `main`.

If you want, I can (pick one):
- remove debug prints now and create a small test that exercises
  `send_and_wait_for_id`, or
- create a feature branch containing these changes and push it to
  the remote so you can open a PR without rebasing `main`.

----

Original documentation (preserved)
---------------------------------

The original latter portion of the README is preserved verbatim in
`README_tail_backup.md`. It is included below for convenience.

<!-- BEGIN PRESERVED TAIL -->

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

IJulia `Comm` — capabilities and practical limits
------------------------------------------------

Summary: `IJulia`'s `Comm` talks directly with the kernel's ZMQ/ipykernel
comm layer and works well in standard kernel-hosted, single-process
sessions (injection, low-latency two-way messages, applet control). Two
practical limitations to be aware of follow.

1) Subprocess / multi-process environments
- If your Julia code runs in a subprocess or a separate process that does
  not share the kernel's comm manager, that process cannot register comms
  with the kernel and direct `ipykernel.comm` connections will not reach
  the frontend. In such deployment cases the `comm_bridge` TCP/JSON bridge
  remains the reliable fallback (it forwards JSON into the kernel's
  comm manager over a local socket).

2) Receive-timing and in-band synchronous expectations
- Even in kernel-hosted sessions we've observed that comm receive
  callbacks may not be processed while a long-running cell is executing;
  they are often delivered only after the cell completes. This means
  code that waits synchronously for an immediate in-band reply during
  cell execution can block or time out. To mitigate this we implemented
  per-request `req_id` pairing and a non-blocking `send_and_wait_for_id`
  helper, but the kernel lifecycle constraint remains a root cause.

Implementation notes
- When sending messages via `IJulia.send_comm`, prefer `Dict` payloads
  (not raw JSON strings) to avoid method-dispatch errors; the frontend
  now normalizes replies and includes `req_id` when present so kernel
  pairing can match replies reliably.

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

WebIO Comm status and Interact.jl compatibility
-----------------------------------------------

Update: the WebIO compatibility issue we observed earlier has been
addressed in our environment via a compatibility patch. As a result,
`WebIO.jl`-based handlers and simple JS callbacks now function when the
patched package or the upstream fix is present; see the patched fork
link below for details.

Key points:
- `WebIO.jl`: The patched WebIO fork restores the ability for client-side
  JS handlers to deliver events into the kernel in our setups. If you
  install the patched fork (or the upstream PR once merged) WebIO
  widgets and one‑way JS callbacks will work without requiring the
  `comm_bridge` fallback.
- `Interact.jl`: Interact still depends on a live, bidirectional comm
  manager and on certain widget lifecycle behaviors. Those higher-level
  two‑way bindings can fail in multi-process, subprocess, or reverse
  proxy environments where the kernel's comm manager is not fully
  accessible. The underlying limitation (comm registration / lifecycle)
  remains distinct from the WebIO compatibility bug that was fixed.

Workarounds and recommendations:
- Preferred: If you can, install the patched WebIO fork (or wait for the
  upstream PR) to regain WebIO handler functionality. The fork is:

  https://github.com/moyhig-ecs/WebIO.jl

- If full `Interact.jl` two-way synchronization is required but your
  environment prevents native comm registration, continue using the
  `comm_bridge` OOB socket as a reliable fallback and explicitly route
  frontend events into server-side handlers (for example via
  `callRemoteSocketSend` or `requestExecute`).

- For interactive code that expects immediate in-band replies during
  long-running cell execution, prefer the `comm_bridge` transport by
  default; the direct-comm path remains available as an opt-in when the
  environment supports it.

Why an OOB (out‑of‑band) channel is still needed
-----------------------------------------------

Even when `IJulia` comms are available and suitable for injection and
low-latency interactions, the kernel's execution lifecycle can delay the
processing of comm receive callbacks until after a running cell completes.
That behavior makes in-band, synchronous reply semantics unreliable for
long-running cells. The `comm_bridge` OOB socket forwards messages into the
kernel's comm manager independently of cell execution and therefore restores
reliable cross-process and real-time reply delivery where needed.

Policy reminder:
- Use `comm_bridge` as the default transport for broad compatibility and
  for code that expects immediate replies during execution.
- Use the improved direct-comm path (with `req_id` pairing) as an opt-in in
  environments where direct comms are known to behave reliably (see
  `enable_direct_transport!()`).

<!-- END PRESERVED TAIL -->


