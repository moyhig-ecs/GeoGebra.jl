"""Direct IJulia comm target for frontend <-> kernel messaging.

This module implements a small adapter that registers a comm target on the
IJulia side so the frontend can open a comm to the kernel using the target
name "jupyter.ggblab". It provides a lightweight `AbstractConnection` wrapper
over the IJulia comm and dispatches incoming messages to a replaceable
handler so the messaging protocol can be swapped or routed to the
`GeoGebra` high-level send/recv helpers.

Features implemented:
- `AbstractConnection` / `IJuliaConnection` wrapper used by send/recv code
- `Sockets.send(::IJuliaConnection, data)` to allow existing Sockets-based
  send paths to work via `IJulia.send_comm`
- A `set_comm_receive_handler!` API to install a custom message handler
- A `register_comm` specialization that installs an `on_msg` callback for
  comms opened to the frontend target `"jupyter.ggblab"`.

Notes:
- This file intentionally avoids WebIO internals and replaces
  `WebIO.dispatch` with a simple, replaceable handler.
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

using IJulia
using Sockets
using JSON

export AbstractConnection, IJuliaConnection, set_comm_receive_handler!, send_via_connection,
       list_registered_comm_keys, get_registered_connection, send_via_key, unregister_comm!

abstract type AbstractConnection end

struct IJuliaConnection <: AbstractConnection
    comm::IJulia.CommManager.Comm
end

"""Default receive handler.
Receives `(conn::IJuliaConnection, data)` where `data` is the raw payload
from the frontend (string or parsed JSON). Users should call
`set_comm_receive_handler!` to install their own handler that integrates with
`GeoGebra`'s send/recv protocol.
"""
const COMM_RECEIVE_HANDLER = Ref{Function}((conn, data) -> begin
    try
        println("[comm_direct] received message:", isa(data, AbstractString) ? data : JSON.json(data))
    catch err
        @warn "comm_direct: error printing incoming message" err=err
    end
end)

function set_comm_receive_handler!(fn::Function)
    COMM_RECEIVE_HANDLER[] = fn
    return nothing
end

"""Send helper that uses IJulia to send a JSON/string payload via the
provided `AbstractConnection`.
`send_via_connection(conn, payload)` will dispatch using `IJulia.send_comm`.
"""
function send_via_connection(c::IJuliaConnection, payload)
    IJulia.send_comm(c.comm, payload)
    return nothing
end

# Registry of active connections keyed by the comm object's pointer string.
const COMM_REGISTRY = Dict{String,IJuliaConnection}()

function _conn_key(comm)
    return string(pointer_from_objref(comm))
end

function list_registered_comm_keys()
    return collect(keys(COMM_REGISTRY))
end

function get_registered_connection(key::String)
    return get(COMM_REGISTRY, key, nothing)
end

function send_via_key(key::String, payload)
    c = get_registered_connection(key)
    if c === nothing
        throw(ErrorException("No registered comm for key: $key"))
    end
    return send_via_connection(c, payload)
end

function unregister_comm!(key::String)
    delete!(COMM_REGISTRY, key)
    return nothing
end

# Provide a Sockets-compatible send method so other codepaths that expect
# a Sockets-like API can reuse this connection type.
function Sockets.send(c::IJuliaConnection, data)
    # IJulia.send_comm accepts Dict or parsed JSON; pass through unchanged
    IJulia.send_comm(c.comm, data)
    return nothing
end

"""Register a comm handler for comms whose type parameter is the
symbol `:jupyter.ggblab` (i.e. the target name used by frontends).

We implement the generic `Comm{T}` registration hook and check the type
parameter so this code remains resilient to IJulia's internal Comm shape.
When a matching comm is registered we wrap it and install `on_msg` to call
the replaceable `COMM_RECEIVE_HANDLER`.
"""
function IJulia.CommManager.register_comm(comm::IJulia.CommManager.Comm{Symbol("jupyter.ggblab")}, _)
    # Specialized dispatch for front-end comms targeted at "jupyter.ggblab".
    conn = IJuliaConnection(comm)
    # store connection so other code can send via this comm
    try
        COMM_REGISTRY[_conn_key(comm)] = conn
    catch err
        @warn "comm_direct: failed to register conn in registry" err=err
    end
    comm.on_msg = function(msg)
        data = haskey(msg.content, "data") ? msg.content["data"] : msg
        try
            COMM_RECEIVE_HANDLER[](conn, data)
        catch err
            @warn "comm_direct: handler raised" err=err
        end
    end
    return nothing
end
