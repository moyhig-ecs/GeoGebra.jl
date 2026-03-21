"""Simple IJulia comm helpers (minimal).

This file provides a small, straightforward API that assumes an IJulia
environment. It intentionally avoids complex fallbacks.

Functions:
- `open_comm(target)` — open an IJulia Comm to `target`.
- `open_control_comm()` — open `jupyter.ggblab.control` comm.
- `send_comm(comm,msg)` — send a message via `IJulia.send_comm`.
- `inject_applet()` — convenience to send an inject payload on control channel.
- `get_kernel_id()` — extract kernel id from IJulia kernel connection file.
"""


# Prefer a static dependency so precompilation/type-check works
using IJulia

export open_comm, open_control_comm, send_comm, inject_applet, get_kernel_id

function open_comm(target::AbstractString; retries::Integer=1, delay::Real=0.1)
    # Use IJulia's Comm constructor directly; let errors propagate to caller
    return IJulia.Comm(target)
end

open_control_comm() = open_comm("jupyter.ggblab.control")

function send_comm(comm, msg)
    # Call IJulia API directly
    IJulia.send_comm(comm, msg)
    return nothing
end



function inject_applet(; insertMode::String="split-right", appName::String="suite", socketPath::Union{Nothing,String}=nothing, useWs::Bool=false)
    comm = open_control_comm()
    if comm === nothing
        throw(ErrorException("Could not open control comm"))
    end
    k = get_kernel_id()
    if k === nothing
        throw(ErrorException("inject_applet: no kernel id available. Ensure code is running inside a Jupyter kernel with IJulia."))
    end
    # Reserve an ingest transport and notify frontend.
    ingest_path = nothing
    ingest_task = nothing
    ingest_port = nothing
    ingest_task_ws = nothing
    try
        if socketPath === nothing
            if useWs
                # Start a TCP WebSocket ingest server and return (port, task)
                p, t = start_ingest_ws_server()
                ingest_port = p
                ingest_task_ws = t
            else
                # Start UNIX-domain ingest server (existing behavior)
                p, t = start_ingest_server(websocket=false)
                ingest_path = p
                ingest_task = t
            end
        else
            # Use the provided socket path; do not start a server here.
            ingest_path = socketPath
        end
    catch err
        @warn "inject_applet: failed to start ingest server, continuing without ingest socket" err=err
        ingest_path = socketPath === nothing ? nothing : socketPath
    end

    payload = Dict("type"=>"inject", "kernelId"=>k, "insertMode"=>insertMode, "appName"=>appName)
    if ingest_port !== nothing
        payload["wsPort"] = ingest_port
    elseif ingest_path !== nothing
        payload["socketPath"] = ingest_path
    end
    send_comm(comm, payload)
    return payload
end

function get_kernel_id()
    # Use IJulia API directly and access known fields to allow type inference
    k = try
        IJulia.get_kernel_or_error()
    catch
        return nothing
    end
    if hasproperty(k, :connection_file)
        cf = k.connection_file
        if isa(cf, String)
            m = match(r"kernel-(.*)\.json", cf)
            if m !== nothing
                return m.captures[1]
            end
        end
    end
    return nothing
end
