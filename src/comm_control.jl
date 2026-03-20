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



function inject_applet(; insertMode::String="split-right", appName::String="suite")
    comm = open_control_comm()
    if comm === nothing
        throw(ErrorException("Could not open control comm"))
    end
    k = get_kernel_id()
    if k === nothing
        throw(ErrorException("inject_applet: no kernel id available. Ensure code is running inside a Jupyter kernel with IJulia."))
    end
    payload = Dict("type"=>"inject", "kernelId"=>k, "insertMode"=>insertMode, "appName"=>appName)
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
