module GeoGebra

# # Include package-local OOBClient implementation and expose it from this package
# try
#     include("comm_bridge/OOBClient.jl")
#     using .OOBClient
# catch
#     # Fail silently; OOBClient is optional in some contexts
# end
# # Export the optional OOBClient module when available
# export OOBClient

# # comm bridge and transport switching helpers are included after defaults

"""Simple TCP JSON bridge client for use from Julia (IJulia/PyCall testing).

Provides `request`, `poll_reply`, and `request_with_retry` functions equivalent
to the Python bridge client. Intended for verification when Julia cannot
communicate with the frontend comm and a separate Python process hosts the
`comm_bridge` server.

Quick snippet (Julia)
```julia
using IJuliaBridgeClient

# assume the Python bridge is running on localhost:8765
payload = Dict("type"=>"function", "payload"=>Dict("name"=>"getVersion", "args"=>[]))
resp = IJuliaBridgeClient.request_with_retry(payload; host="127.0.0.1", port=8765)
println(resp)
```

"""

using UUIDs
using JSON
using PythonCall
using SymPyPythonCall

# Defaults are mutable so users can change the bridge host/port at runtime
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765

# Include comm bridge and transport switching helpers now that defaults exist
include("comm_bridge/CommBridge.jl")
using .CommBridge
export CommBridge

# Include IPython Comm implementation and control comm helpers
# if Comm is available from IJulia; these are used for the preferred direct comm transport.
include("comm_direct.jl")
include("comm_ingest.jl")
include("comm_ingest_ws.jl")
include("comm_control.jl")
export inject_applet, get_kernel_id

# Transport helpers: allow switching CommBridge request handler to use the
# kernel-side direct comm registered by `comm_direct.jl`. By default
# `CommBridge` uses the TCP bridge; call `enable_direct_transport!()` to
# route requests via the first available registered comm connection.
function enable_direct_transport!()
    # Prefer paired request/reply semantics when using direct comm transport.
    # Use the module's `_auto_request_handler` which sends and waits for
    # matching replies (via send_and_wait_for_id) so `send_command` behaves
    # like the TCP bridge and returns replies synchronously.
    CommBridge.set_request_handler!(_auto_request_handler)
    return nothing
end

function disable_direct_transport!()
    CommBridge.set_request_handler!(p -> CommBridge.request_tcp(p))
    return nothing
end

# Install a default auto-switching request handler that prefers the kernel-side
# direct comm transport when a comm is registered, but falls back to the TCP
# bridge if no direct comm is available or if sending via comm fails.
function _auto_request_handler(payload)
    keys = list_registered_comm_keys()
    if isempty(keys)
        throw(ErrorException("comm_direct: no registered comm connections"))
    end
    k = keys[1]
    # Send via kernel-side comm, then dequeue the next inbound message for
    # this comm. Frontend enqueues stringified JSON messages, so we parse
    # the string into a Dict and normalize the reply payload to match
    # comm_bridge semantics. This performs a timed poll (up to
    # `COMM_REPLY_TIMEOUT`) on the comm queue.
    # Send and wait for the reply that contains the matching `req_id`.
    # `send_and_wait_for_id` ensures requests are paired with replies even
    # if multiple requests are in-flight concurrently.
    resp = send_and_wait_for_id(k, payload; timeout=COMM_REPLY_TIMEOUT)
    # println("[comm_direct] received reply for key:", k, " at ", time(), " response: ", resp)
    # If the queued message is a JSON string, parse it to Dict
    if isa(resp, AbstractString)
        try
            parsed = JSON.parse(resp)
            resp = parsed
        catch
            # leave resp as string if parse fails
        end
    end
    # Normalize response: unwrap {"reply":...} or {"type":"created","payload":...}
    if isa(resp, AbstractDict)
        if haskey(resp, "reply")
            return resp["reply"]
        elseif haskey(resp, "type") && string(resp["type"]) == "created" && haskey(resp, "payload")
            return resp["payload"]
        elseif haskey(resp, "payload")
            return resp["payload"]
        end
    end
    return resp
end

# Revert to TCP bridge transport by default. Direct comm transport can
# be enabled explicitly via `enable_direct_transport!()` when desired.

# Helper: interpret common truthy env var values for boolean flags
# Helper: interpret common truthy env var values for boolean flags
function _env_bool(var::AbstractString)
    v = get(ENV, var, nothing)
    if v === nothing
        return false
    end
    s = lowercase(strip(String(v)))
    return s in ("1", "true", "yes", "on")
end

# Default to direct comm transport initially. Environment-based selection
# is deferred to runtime so users can set `ENV` before using the package
# without being constrained by precompilation-time evaluation. By default
# prefer the kernel-side direct comm transport for lower-latency requests.
enable_direct_transport!()

# Runtime-init helpers: allow selecting transport at first use or explicitly.
const _transport_initialized = Ref(false)

function init_transport_from_env!()
    # If either env var is present, respect its truthiness. If absent,
    # default to enabled direct transport.
    if haskey(ENV, "GGB_DIRECT_TRANSPORT") || haskey(ENV, "GEOGEBRA_DIRECT_TRANSPORT")
        if _env_bool("GGB_DIRECT_TRANSPORT") || _env_bool("GEOGEBRA_DIRECT_TRANSPORT")
            @info "GeoGebra: enabling direct transport via environment variable"
            enable_direct_transport!()
        else
            @info "GeoGebra: disabling direct transport via environment variable"
            disable_direct_transport!()
        end
    else
        @info "GeoGebra: defaulting to direct transport"
        enable_direct_transport!()
    end
    _transport_initialized[] = true
    return nothing
end

function _init_transport_if_needed()
    if !_transport_initialized[]
        try
            init_transport_from_env!()
        catch err
            @warn "init_transport_from_env! failed" err=err
            # Ensure flag set to avoid repeated attempts
            _transport_initialized[] = true
        end
    end
    return nothing
end

# Install an asynchronous comm receive handler that updates the local
# construction protocol when the frontend notifies about created objects
# or returns payloads. This avoids blocking the kernel waiting for replies
# and matches the comm_bridge semantics where messages are delivered
# asynchronously via the comm target callbacks.
function _comm_direct_receive_handler(conn, data)
    try
        d = data
        # if string, try to parse
        if isa(d, AbstractString)
            try
                d = JSON.parse(d)
            catch
                # leave as string
            end
        end
        # If the incoming data is a Dict with a created event, push to protocol
        if isa(d, AbstractDict)
            ty = get(d, "type", nothing)
            if ty !== nothing && string(ty) == "created"
                payload = get(d, "payload", nothing)
                label = nothing
                if isa(payload, AbstractDict) && haskey(payload, "label")
                    label = string(payload["label"])
                else
                    # synthesize a label based on protocol length
                    label = "obj$(length(_CONSRUCTION_PROTOCOL[]) + 1)"
                end
                @debug "_comm_direct_receive_handler: received created event" label=label
                return nothing
            end
            # also accept direct reply wrappers
            if haskey(d, "reply") || haskey(d, "payload")
                pl = get(d, "reply", get(d, "payload", d))
                label = "obj$(length(_CONSRUCTION_PROTOCOL[]) + 1)"
                @debug "_comm_direct_receive_handler: received reply/payload" payload=pl
                return nothing
            end
        end
        # For messages without dicts or recognized fields, log and ignore
        @debug "_comm_direct_receive_handler: received unrecognized message" msg=d
    catch err
        @warn "_comm_direct_receive_handler failed" err=err
    end
    return nothing
end

try
    set_comm_receive_handler!(_comm_direct_receive_handler)
catch err
    @warn "Failed to set comm receive handler" err=err
end

# NOTE: Prefer explicit `pyimport("ggblab.comm_bridge").connect()` or
# direct `pyimport("ggblab.schema")` usage from Julia rather than a
# module-global lazy-import wrapper. The previous `LazyPyModule` pattern
# caused complexity and eager-import problems in some environments.



"""Internal helper: send a JSON line to the bridge and return the parsed reply.

Arguments:
- `msg::String`: JSON string to send (a newline is appended automatically).
- `host`, `port`, `timeout`: connection parameters.

Returns:
- Parsed JSON (Dict/Array/primitive). Network or parse errors raise exceptions.
"""
function _send_and_recv(msg::String; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT, timeout::Real=10.0)
    sockets_mod = try
        Base.require(@__MODULE__, :Sockets)
    catch
        try
            Base.require(Main, :Sockets)
        catch
            try
                eval(@__MODULE__, :(using Sockets))
                getfield(@__MODULE__, :Sockets)
            catch err
                throw(ErrorException("Failed to load Sockets stdlib: $(err)"))
            end
        end
    end
    sock = sockets_mod.connect(host, port)
    try
        write(sock, msg * "\n")
        flush(sock)
        line = readline(sock)
        return JSON.parse(String(line))
    finally
        close(sock)
    end
end

"""Normalize bridge replies.

If the bridge returns a `{ "reply": ... }` wrapper, return the inner value;
otherwise return the response unchanged.
"""
function _unwrap_reply(resp)
    if resp isa AbstractDict && haskey(resp, "reply")
        return resp["reply"]
    else
        return resp
    end
end

"""Send `payload` to the bridge and return the parsed reply.

`payload` may be a `Dict`/`Array`/`String`; non-string values are converted to JSON.

Example:
```julia
resp = GeoGebra.request(Dict("type"=>"function", "payload"=>Dict("name"=>"getVersion", "args"=>[])))
```
"""
function request(payload; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT, timeout::Real=10.0)
    _init_transport_if_needed()
    return _unwrap_reply(CommBridge.request(payload; host=host, port=port, timeout=timeout))
end

"""Send a textual GeoGebra command string directly to the bridge.

`cmd_text` should be a complete command such as `A = (0,0)`,
`Circle(A, 1)`, or `l1 = {Intersect(g,f)}`. The function sends the string
unchanged as the command payload.
"""
function send_command(cmd_text::AbstractString; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    _init_transport_if_needed()
    return CommBridge.send_command(cmd_text; host=host, port=port)
end

"""Send a function call payload to the bridge.

`name` is the function name (Symbol or String); `args` are converted to
strings and sent inside the `payload` object:
`{"type":"function","payload":{"name":...,"args":[...]}}`.
"""
function send_function(name, args...; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    # Call the bridge synchronously — keep implementation simple and
    # predictable. Convert returned Julia vectors to Python lists for
    # consumers when possible, but otherwise return the raw result.
    _init_transport_if_needed()
    res = CommBridge.send_function(name, args...; host=host, port=port)
    out = res
    try
        if isa(res, AbstractVector)
            builtins = PythonCall.pyimport("builtins")
            pylist_fn = getproperty(builtins, :list)
            out = pylist_fn(res)
        end
    catch err
        @warn "send_function: failed to convert Vector to Python list" err=err
        out = res
    end
    return out
end

"""Send a `listen` message to the bridge.

The message payload is of the form:
`{"type":"listen","payload":[label::String, enabled::Bool]}`.

`label` may be a `GGBObject`, `Symbol`, or `String`.
"""
function send_listen(label; enabled::Bool=true, host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    # normalize label to string
    lbl = isa(label, GGBObject) ? label.label : (isa(label, Symbol) ? string(label) : string(label))
    payload = Dict("type"=>"listen", "payload"=>[lbl, enabled])
    _init_transport_if_needed()
    return CommBridge.request(payload; host=host, port=port)
end

"""Helper called by the macro: evaluate an argument tuple and call `send_command`.
When arguments include a `GGBObject`, replace it with its `label` before sending."""
function send_command_eval(name, args_tuple)
    _init_transport_if_needed()
    return CommBridge.send_command_eval(name, args_tuple; host=DEFAULT_HOST, port=DEFAULT_PORT)
end

"""Helper called by the macro: evaluate an argument tuple and call `send_function`.
When arguments include a `GGBObject`, replace it with its `label` before sending."""
function send_function_eval(name, args_tuple)
    _init_transport_if_needed()
    return CommBridge.send_function_eval(name, args_tuple; host=DEFAULT_HOST, port=DEFAULT_PORT)
end



"""Poll the bridge for a previously stored reply by `reply_id`.

`reply_id` is typically an ID injected by `request_with_retry`.
"""
function poll_reply(reply_id::AbstractString; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT, timeout::Real=5.0)
    payload = Dict("op"=>"get_reply", "id"=>reply_id)
    return request(payload; host=host, port=port, timeout=timeout)
end

"""Send `payload` with retry/backoff and optional stored-reply polling.

Parameters:
- `retries`: max send attempts
- `backoff`: initial delay in seconds
- `allow_get_reply`: if true, poll the bridge for a stored reply by `id` when all attempts fail
- `poll_interval`, `poll_timeout`: polling interval and timeout

Returns the reply on success; raises on network errors or returns
`Dict("error"=>...)` if polling/timeout occurs.
"""
function request_with_retry(payload; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT,
                            timeout::Real=10.0, retries::Int=3, backoff::Real=0.5,
                            allow_get_reply::Bool=true, poll_interval::Real=0.5, poll_timeout::Real=5.0)
    msg_id = nothing
    pl = payload
    if isa(payload, AbstractDict) && haskey(payload, "id")
        msg_id = string(payload["id"])
    elseif isa(payload, AbstractDict)
        msg_id = string(round(Int, time()*1e6)) * "-" * string(rand(UInt64))
        pl = deepcopy(payload)
        pl["id"] = msg_id
    else
        msg_id = nothing
    end

    last_err = nothing
    for attempt in 1:max(1, retries)
        try
            return request(pl; host=host, port=port, timeout=timeout)
        catch e
            last_err = e
            if attempt < retries
                sleep(backoff * 2^(attempt-1))
                continue
            end
        end
    end

    if allow_get_reply && msg_id !== nothing
        deadline = time() + poll_timeout
        while time() < deadline
            try
                r = poll_reply(string(msg_id); host=host, port=port, timeout=poll_interval)
                if isa(r, AbstractDict) && haskey(r, "error")
                    nothing
                else
                    return r
                end
            catch
            end
            sleep(poll_interval)
        end
        if last_err !== nothing
            throw(last_err)
        end
    end

    return Dict("error"=>"request_with_retry failed")
end

"""Set the module default `host`. Returns the new value."""
function set_default_host(h::AbstractString)
    global DEFAULT_HOST = h
    return DEFAULT_HOST
end

"""Set the module default `port`. Returns the new value."""
function set_default_port(p::Integer)
    global DEFAULT_PORT = Int(p)
    return DEFAULT_PORT
end

# Export core public API: request/send/poll helpers and defaults
# export request, poll_reply, request_with_retry, 
export set_default_host, set_default_port, send_command, send_function, send_listen
# export send_command_eval, send_function_eval

include("ggb_construction.jl")
# Exports for symbols provided by ggb_construction.jl
export construction_protocol, new_construction!
# export evalXML_from_element, process_labels_response
export GGBObject, set_object!, set!, fetch_object, refresh, refresh!
export get_construction_object, get_construction_objects
include("ggb_sympy.jl")
# Exports for helper utilities
export sympy_to_ggb, expr_to_cmd_string
include("ggb_macros.jl")
# Exports for macros (defined in ggb_macros.jl) and their helpers
export @ggblab, @ggb, @ggblab_command, @ggblab_function, @await

end # module
