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
using UUIDs

export AbstractConnection, IJuliaConnection, set_comm_receive_handler!, send_via_connection,
       list_registered_comm_keys, get_registered_connection, send_via_key, unregister_comm!

export send_and_wait_for_next, send_and_wait_for_id

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

# Per-comm incoming message queues keyed by registry key
const COMM_QUEUES = Dict{String, Channel{String}}()
# Pending per-request reply channels keyed by request id
const PENDING_REPLIES = Dict{String, Channel{Any}}()
# Default timeout (seconds) to wait for a reply from the frontend via comm
const COMM_REPLY_TIMEOUT = 10.0
# (No stored/pending reply state — inbound messages are delivered
# asynchronously via `COMM_QUEUES` and `COMM_RECEIVE_HANDLER`.)
function _enqueue_comm_message(key::String, data::String)
    println("[comm_direct] enqueue attempt for key:", key, " at ", time())
    println("[comm_direct] data to enqueue: ", data)
    try
        if !haskey(COMM_QUEUES, key)
            COMM_QUEUES[key] = Channel{String}(64)
        end
        ch = COMM_QUEUES[key]
        try
            println("[comm_direct] enqueued message for key:", key, " at ", time())
            println("[comm_direct] COMM_QUEUES[\"$key\"]: ", (COMM_QUEUES[key]))
            put!(ch, data)
        catch err
            println("[comm_direct] failed to enqueue message for key:", key, " at ", time())
            # ignore if channel put fails
        end
    catch err
        @warn "comm_direct: _enqueue_comm_message failed" err=err key=key
    end
    return nothing
end


function _dequeue_comm_message(key::String; timeout::Real=COMM_REPLY_TIMEOUT)
    if !haskey(COMM_QUEUES, key)
        COMM_QUEUES[key] = Channel{String}(64)
    end
    ch = COMM_QUEUES[key]
    t0 = time()
    println("[comm_direct] dequeue wait start for key:", key, " at ", t0, " timeout=", timeout)
    while true
        if isready(ch)
            println("[comm_direct] dequeue success for key:", key, " at ", time(), " waited ", time() - t0, "s")
            return take!(ch)
        elseif time() - t0 > timeout
            println("[comm_direct] dequeue timeout for key:", key, " after ", time() - t0, "s")
            throw(ErrorException("comm_direct: timeout waiting for reply on comm $key"))
        else
            sleep(0.01)
        end
    end
end

function _wait_on_pending(id::String; timeout::Real=COMM_REPLY_TIMEOUT)
    if !haskey(PENDING_REPLIES, id)
        PENDING_REPLIES[id] = Channel{Any}(1)
    end
    ch = PENDING_REPLIES[id]
    t0 = time()
        @info "comm_direct: awaiting reply" req_id=id keys_pending=collect(keys(PENDING_REPLIES))
        while true
        if isready(ch)
            val = take!(ch)
            delete!(PENDING_REPLIES, id)
            return val
        elseif time() - t0 > timeout
            delete!(PENDING_REPLIES, id)
            throw(ErrorException("comm_direct: timeout waiting for reply for req_id $id"))
        else
            sleep(0.01)
        end
    end
end

"""Wait for a reply with given id. Returns payload or throws on timeout."""
# No synchronous reply waiting utilities — inbound messages are handled
# asynchronously via the comm queues and receive handler.

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
    try
        # Prefer a stable comm identifier if available (comm_id or id).
        if hasproperty(comm, :comm_id)
            return string(getproperty(comm, :comm_id))
        elseif hasproperty(comm, :id)
            return string(getproperty(comm, :id))
        elseif hasproperty(comm, :commId)
            return string(getproperty(comm, :commId))
        else
            # Fallback to pointer string when no id property exists.
            return string(pointer_from_objref(comm))
        end
    catch err
        @warn "comm_direct: _conn_key fallback to pointer" err=err
        return string(pointer_from_objref(comm))
    end
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
    # Simple bridge-style behavior: send the payload via the comm and wait
    # for the next incoming message on that comm's queue. Do not attempt
    # id/type/label matching — this mirrors comm_bridge's simpler behavior.
    try
        # IJulia.send_comm expects a Dict; ensure we pass a Dict
        send_dict = nothing
        if isa(payload, Dict)
            send_dict = payload
        elseif isa(payload, AbstractString) || isa(payload, Vector{UInt8})
            # try to parse JSON string into Dict
            try
                s = isa(payload, Vector{UInt8}) ? String(payload) : String(payload)
                parsed = JSON.parse(s)
                if isa(parsed, Dict)
                    send_dict = parsed
                else
                    send_dict = Dict("payload" => parsed)
                end
            catch
                send_dict = Dict("payload" => payload)
            end
        else
            # try to serialize then parse back into Dict
            try
                s = JSON.json(payload)
                parsed = JSON.parse(s)
                if isa(parsed, Dict)
                    send_dict = parsed
                else
                    send_dict = Dict("payload" => parsed)
                end
            catch
                send_dict = Dict("payload" => string(payload))
            end
        end
        IJulia.send_comm(c.comm, send_dict)
    catch err
        rethrow(err)
    end
    # Non-blocking behaviour: do not wait for a reply here. The incoming
    # messages are enqueued and observers can read them asynchronously via
    # the per-comm queues. This mirrors a non-blocking transport similar to
    # the comm_bridge approach where replies are received independently.
    println("[comm_direct] send_via_key sent (non-blocking) for key:", key)
    return nothing
end


"""Send payload via comm `key` with a generated `req_id`, wait for the
corresponding reply keyed by that `req_id` and return it.
This pairs requests and replies so parallel callers receive correct responses.
"""
function send_and_wait_for_id(key::String, payload; timeout::Real=COMM_REPLY_TIMEOUT)
    c = get_registered_connection(key)
    if c === nothing
        throw(ErrorException("No registered comm for key: $key"))
    end
    # generate stable request id
    rid = string(UUIDs.uuid4())
    # prepare sendable dict, ensuring req_id present
    send_dict = nothing
    if isa(payload, Dict)
        send_dict = deepcopy(payload)
        send_dict["req_id"] = rid
    elseif isa(payload, AbstractString) || isa(payload, Vector{UInt8})
        try
            s = isa(payload, Vector{UInt8}) ? String(payload) : String(payload)
            parsed = JSON.parse(s)
            if isa(parsed, Dict)
                send_dict = parsed
                send_dict["req_id"] = rid
            else
                send_dict = Dict("payload" => parsed, "req_id" => rid)
            end
        catch
            send_dict = Dict("payload" => payload, "req_id" => rid)
        end
    else
        try
            s = JSON.json(payload)
            parsed = JSON.parse(s)
            if isa(parsed, Dict)
                send_dict = parsed
                send_dict["req_id"] = rid
            else
                send_dict = Dict("payload" => parsed, "req_id" => rid)
            end
        catch
            send_dict = Dict("payload" => string(payload), "req_id" => rid)
        end
    end

    # ensure pending channel exists
    PENDING_REPLIES[rid] = Channel{Any}(1)

    # send
    try
        IJulia.send_comm(c.comm, send_dict)
    catch err
        delete!(PENDING_REPLIES, rid)
        rethrow(err)
    end

    # wait for matching reply in a background task so comm callbacks can run
    t = @async begin
        return _wait_on_pending(rid; timeout=timeout)
    end
    wait(t)
    return fetch(t)
end

"""Send payload via comm `key` and asynchronously wait for the next
message in that comm's queue. Uses `@async` so the waiting task does not
block the kernel's comm callbacks. Returns the dequeued value or throws
on timeout.
"""
function send_and_wait_for_next(key::String, payload; timeout::Real=COMM_REPLY_TIMEOUT)
    # send first
    println("[comm_direct] send_and_wait_for_next sending for key:", key, " at ", time())
    send_via_key(key, payload)
    println("[comm_direct] send_and_wait_for_next sent for key:", key, " at ", time(), " now waiting for reply...")
    # start background task to dequeue (this task will block on channel but
    # not the caller's task scheduler)
    t = @async begin
        return _dequeue_comm_message(key; timeout=timeout)
    end
    # wait for task to complete and return its value; `fetch` will rethrow
    # any exception raised inside the task.
    wait(t)
    return fetch(t)
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
    # Compute the registry key up-front so closures can capture it even if
    # registry insertion fails.
    k = _conn_key(comm)
    try
        COMM_REGISTRY[k] = conn
        # ensure a queue exists for this comm
        if !haskey(COMM_QUEUES, k)
            COMM_QUEUES[k] = Channel{String}(64)
        end
    catch err
        @warn "comm_direct: failed to register conn in registry" err=err
    end
    comm.on_msg = function(msg::IJulia.Msg)
        # extract raw data from ipykernel message
        # raw = haskey(msg.content, "data") ? msg.content["data"] : msg
        # IJulia comm messages are delivered as Dict; use raw payload directly
        # data = raw

        # treat all inbound messages as asynchronous deliveries: enqueue and notify observers
        try
            if haskey(msg.content, "data")
                raw = msg.content["data"]
                parsed = raw
                # if string, try parse JSON
                if isa(raw, AbstractString)
                    try
                        parsed = JSON.parse(raw)
                    catch
                        parsed = raw
                    end
                end
                # If message has req_id and there is a pending waiter, deliver directly
                try
                    if isa(parsed, AbstractDict) && (haskey(parsed, "req_id") || haskey(parsed, "id") || haskey(parsed, "request_id"))
                        rid = string(get(parsed, "req_id", get(parsed, "id", get(parsed, "request_id", nothing))))
                            @info "comm_direct: incoming message with req_id" rid=rid keys_pending=collect(keys(PENDING_REPLIES))
                        if rid !== nothing && haskey(PENDING_REPLIES, rid)
                            ch = PENDING_REPLIES[rid]
                            try
                                put!(ch, parsed)
                            catch err_inner
                                @warn "comm_direct: failed to put reply to pending channel" err=err_inner rid=rid
                            end
                            # still call receive handler for side-effects
                            COMM_RECEIVE_HANDLER[](conn, parsed)
                            return
                        end
                    end
                catch err_inner
                    @warn "comm_direct: error checking pending replies" err=err_inner
                end
                # Otherwise enqueue the raw string representation for generic consumers
                try
                    s = isa(raw, AbstractString) ? raw : JSON.json(raw)
                    _enqueue_comm_message(k, s)
                catch
                    _enqueue_comm_message(k, string(raw))
                end
            end
        catch err
            @warn "comm_direct: enqueue failed" err=err
        end
        try
            # pass parsed/raw data to receive handler too (compute in steps to avoid parse issues)
            recv = nothing
            if isa(msg.content, Dict) && haskey(msg.content, "data")
                raw2 = msg.content["data"]
                if isa(raw2, AbstractString)
                    try
                        recv = JSON.parse(raw2)
                    catch
                        recv = raw2
                    end
                else
                    recv = raw2
                end
            else
                recv = msg
            end
            COMM_RECEIVE_HANDLER[](conn, recv)
        catch err
            @warn "comm_direct: handler raised" err=err
        end
    end
    return nothing
end
