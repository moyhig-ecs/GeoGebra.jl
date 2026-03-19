"""Simple IJulia comm helpers (minimal).

This file provides a small, straightforward API that assumes an IJulia
environment. It intentionally avoids complex fallbacks.

Functions:
- `open_comm(target)` — open an IJulia Comm to `target`.
- `open_control_comm()` — open `jupyter.ggblab.control` comm.
- `send_comm(comm,msg)` — send a message via `IJulia.send_comm`.
- `register_handler(comm, fn)` — set `comm.on_msg = fn` (best-effort).
- `inject_applet()` — convenience to send an inject payload on control channel.
- `get_kernel_id()` — extract kernel id from IJulia kernel connection file.
"""


# # using Sockets

# abstract type AbstractConnection end
# struct IJuliaConnection <: AbstractConnection
#     comm::IJulia.CommManager.Comm
# end

# function Sockets.send(c::IJuliaConnection, data)
#     IJulia.send_comm(c.comm, data)
# end

# function IJulia.CommManager.register_comm(comm::IJulia.CommManager.Comm{:webio_comm}, _)
#     conn = IJuliaConnection(comm)
#     comm.on_msg = function (msg)
#         data = msg.content["data"]
#         println(data)
#         # WebIO.dispatch(conn, data)
#     end
# end   


export open_comm, open_control_comm, send_comm, register_handler, inject_applet, get_kernel_id

function open_comm(target::AbstractString; retries::Integer=1, delay::Real=0.1)
    if !isdefined(Main, :IJulia)
        try
            Base.require(Main, :IJulia)
        catch
            return nothing
        end
    end
    IJ = getfield(Main, :IJulia)
    # Try a simple constructor call
    try
        return IJ.Comm(target)
    catch
        try
            return getfield(IJ, :Comm)(target)
        catch
            return nothing
        end
    end
end

open_control_comm() = open_comm("jupyter.ggblab.control")

function send_comm(comm, msg)
    if !isdefined(Main, :IJulia)
        Base.require(Main, :IJulia)
    end
    IJ = getfield(Main, :IJulia)
    sendfn = getfield(IJ, :send_comm)
    sendfn(comm, msg)
    return nothing
end

function register_handler(comm, fn::Function)
    try
        setproperty!(comm, :on_msg, fn)
        return true
    catch
        return false
    end
end

function inject_applet(; insertMode::String="split-right", appName::String="suite")
    comm = open_control_comm()
    if comm === nothing
        throw(ErrorException("Could not open control comm"))
    end
    k = get_kernel_id()
    payload = Dict("type"=>"inject", "kernelId"=>k, "insertMode"=>insertMode, "appName"=>appName)
    send_comm(comm, payload)
    return payload
end

function get_kernel_id()
    if !isdefined(Main, :IJulia)
        try
            Base.require(Main, :IJulia)
        catch
            return nothing
        end
    end
    IJ = getfield(Main, :IJulia)
    k = try
        IJ.get_kernel_or_error()
    catch
        try
            IJ.Kernel()
        catch
            return nothing
        end
    end
    if hasproperty(k, :connection_file)
        cf = getproperty(k, :connection_file)
        if isa(cf, String)
            m = match(r"kernel-(.*)\.json", cf)
            if m !== nothing
                return m.captures[1]
            end
        end
    end
    return nothing
end
