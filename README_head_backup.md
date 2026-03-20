# GeoGebra.jl — README head backup (lines 1-71)

This file is an automated backup of the original README head (lines 1–71)
that were removed from `README.md` during a cleanup. It preserves the
previously patched content for reference or reinsertion.

----

# GeoGebra.jl — comm_bridge (preserved)

This folder contains the Julia-side client for communicating with the GeoGebra
frontend. Historically the package provides a lightweight TCP/JSON "comm_bridge"
client that connects to a Python-hosted bridge server. That implementation is
stable and should be preserved as the canonical bridge path for environments
where the frontend comm channel is unavailable or unreliable.

Goals of this README
- Explain what `comm_bridge` is and where to find the code
- Document how to run the bridge server for local testing
- Explain the coexistence with the newer simple `IJulia` comm usage

Key files
- `src/GeoGebra.jl` — Primary implementation; contains the TCP JSON bridge
  client (request/send_function/send_command helpers), `GGBObject` helpers,
  and higher-level APIs used by other tooling.
- `src/OOBClient.jl` — Optional out-of-band client helper (may be absent).
- `examples/` — (optional) example usage and small scripts.

Why preserve comm_bridge
- Some environments (headless kernels, remote frontends, or complex deployment
  topologies) cannot use the direct `IJulia` comm channel. The bridge provides
  a reliable fallback and debugging path.
- Existing users and integration tests rely on this code; avoid removing or
  rewriting it without maintaining a compatibility shim.

Running the Python bridge server (dev)
1. In a Python environment with the repository installed or the package
   available, run the bridge server (example):

```bash
# from the repo root
python -m ggblab.comm_bridge --host 127.0.0.1 --port 8765
```

2. From Julia you can call the bridge with the defaults:

```julia
using GeoGebra
resp = GeoGebra.request(Dict("type"=>"function", "payload"=>Dict("name"=>"getVersion", "args"=>[])))
println(resp)
```

Simple IJulia comm alternative
- Newer, simpler workflows can use `IJulia` comms directly (no bridge server):

```julia
using IJulia
comm = IJulia.Comm("jupyter.ggblab.control")
IJulia.send_comm(comm, Dict("type"=>"inject", "insertMode"=>"split-right"))
```

Both approaches may coexist in the repository: the `comm_bridge` path remains
as the supported fallback, while the direct `IJulia` comm helpers provide a
lighter-weight experience when the frontend kernel comm channel is available.

----