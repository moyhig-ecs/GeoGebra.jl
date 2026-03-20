module GeoGebra

# Include package-local OOBClient implementation and expose it from this package
try
    include("OOBClient.jl")
    using .OOBClient
catch
    # Fail silently; OOBClient is optional in some contexts
end

# comm bridge and transport switching helpers are included after defaults


"""Simple TCP JSON bridge client for use from Julia (IJulia/PyCall testing).

Provides `request`, `poll_reply`, and `request_with_retry` functions equivalent
to the Python bridge client. Intended for verification when Julia cannot
communicate with the frontend comm and a separate Python process hosts the
`comm_bridge` server.

Quick snippet (Julia)
---------------------
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

# Defaults are mutable so users can change the bridge host/port at runtime
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765

# Include comm bridge and transport switching helpers now that defaults exist
include("comm_bridge.jl")
using .CommBridge
include("comm_control.jl")
include("comm_direct.jl")

export CommBridge

# Transport helpers: allow switching CommBridge request handler to use the
# kernel-side direct comm registered by `comm_direct.jl`. By default
# `CommBridge` uses the TCP bridge; call `enable_direct_transport!()` to
# route requests via the first available registered comm connection.
function enable_direct_transport!()
    # handler uses first registered comm in comm_direct registry
    function _direct_handler(payload)
        keys = list_registered_comm_keys()
        if isempty(keys)
            throw(ErrorException("comm_direct: no registered comm connections"))
        end
        # use first registered connection
        k = keys[1]
        return send_via_key(k, payload)
    end
    CommBridge.set_request_handler!(_direct_handler)
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
    println("[comm_direct] received reply for key:", k, " at ", time(), " response: ", resp)
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
disable_direct_transport!()

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
                push!(_CONSRUCTION_PROTOCOL[], GGBObject(label, payload))
                return nothing
            end
            # also accept direct reply wrappers
            if haskey(d, "reply") || haskey(d, "payload")
                pl = get(d, "reply", get(d, "payload", d))
                label = "obj$(length(_CONSRUCTION_PROTOCOL[]) + 1)"
                push!(_CONSRUCTION_PROTOCOL[], GGBObject(label, pl))
                return nothing
            end
        end
        # For messages without dicts or recognized fields, append raw data
        push!(_CONSRUCTION_PROTOCOL[], GGBObject("obj$(length(_CONSRUCTION_PROTOCOL[]) + 1)", d))
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
    return _unwrap_reply(CommBridge.request(payload; host=host, port=port, timeout=timeout))
end

"""Send a textual GeoGebra command string directly to the bridge.

`cmd_text` should be a complete command such as `A = (0,0)`,
`Circle(A, 1)`, or `l1 = {Intersect(g,f)}`. The function sends the string
unchanged as the command payload.
"""
function send_command(cmd_text::AbstractString; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    return CommBridge.send_command(cmd_text; host=host, port=port)
end

"""Send a function call payload to the bridge.

`name` is the function name (Symbol or String); `args` are converted to
strings and sent inside the `payload` object:
`{"type":"function","payload":{"name":...,"args":[...]}}`.
"""
function send_function(name, args...; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    return CommBridge.send_function(name, args...; host=host, port=port)
end

"""Helper called by the macro: evaluate an argument tuple and call `send_command`.
When arguments include a `GGBObject`, replace it with its `label` before sending."""
function send_command_eval(name, args_tuple)
    return CommBridge.send_command_eval(name, args_tuple; host=DEFAULT_HOST, port=DEFAULT_PORT)
end

"""Helper called by the macro: evaluate an argument tuple and call `send_function`.
When arguments include a `GGBObject`, replace it with its `label` before sending."""
function send_function_eval(name, args_tuple)
    return CommBridge.send_function_eval(name, args_tuple; host=DEFAULT_HOST, port=DEFAULT_PORT)
end


# Lightweight wrapper for objects created in the GeoGebra applet.
mutable struct GGBObject
    label::String
    data::Any
end

# Display only the label for brevity in REPL and printing
Base.show(io::IO, ::MIME"text/plain", g::GGBObject) = print(io, g.label)
Base.show(io::IO, g::GGBObject) = print(io, g.data)

# Implicit construction protocol (default construction protocol storage).
# Use a `Ref` to allow rebinding the contained vector without changing the
# exported binding; users should use provided APIs rather than touching this.
const _CONSRUCTION_PROTOCOL = Ref{Vector{GGBObject}}(GGBObject[])

"""Return the current construction protocol vector (live reference)."""
function construction_protocol()
    return _CONSRUCTION_PROTOCOL[]
end

"""Start a new construction by clearing the construction history in-place
and return the cleared vector. Named `new_construction!` to mirror the
GeoGebra API `newConstruction()`.
"""
function new_construction!()
    # Call the GeoGebra bridge to create a new construction, clear local
    # protocol, and return the bridge response.
    resp = send_function("newConstruction")
    empty!(_CONSRUCTION_PROTOCOL[])
    return _CONSRUCTION_PROTOCOL[]
end

"""Dump the construction history to `path` as a simple textual report.
Each entry contains the object's label and a `show` rendering of its data.
"""
 

"""Internal helper to append result(s) into the construction history.
Accepts a single `GGBObject` or a vector of them."""
function _push_construction_result!(res)
    if isa(res, GGBObject)
        push!(_CONSRUCTION_PROTOCOL[], res)
    elseif isa(res, AbstractVector{GGBObject})
        append!(_CONSRUCTION_PROTOCOL[], res)
    end
    return _CONSRUCTION_PROTOCOL[]
end


"""Encode a single `element`-shaped dict using the Python-side schema
and send it to the applet via the `evalXML` API.

`elem_data` should be the dictionary representing a single element as
produced in `GGBObject.data["element"][i]`.
"""
function evalXML_from_element(elem_data; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    try
        xmlschema = PythonCall.pyimport("xmlschema")
        # Use the Python-side ggblab.schema wrapper for encode/decode.
        ggb_schema = PythonCall.pyimport("ggblab.schema").ggb_schema()
        schema = ggb_schema.schema
        # Encode the element into an ElementTree (or compatible object)
        encoded = schema.encode(elem_data, "element")
        # Serialize to bytes/string using xmlschema helper
        xml_str = xmlschema.etree_tostring(encoded)
        return send_function("evalXML", xml_str; host=host, port=port)
    catch e
        throw(ErrorException("Failed to evalXML from element: $(e)"))
    end
end


"""Convenience mutating helper: take a `GGBObject` whose `data` has an
`"element"` array, reserialize the specified element index back to XML
and send it to the applet via `evalXML`.

Usage:
```
# modify p1.data["element"][1] as needed
set_object!(p1)                 # sends element at index 1 (1-based)
set_object!(p1, element_index=1) # explicit
```
"""
function set_object!(g::GGBObject; element_index::Int=1, host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    # Attempt to obtain the "element" collection in a way that works for
    # both native Julia dicts/vectors and Python-callable PyObject mappings.
    elems = nothing
    # Try Julia-style Dict access first
    try
        elems = g.data["element"]
    catch
    end
    # Fallback: try attribute access on PyObject
    if elems === nothing
        try
            elems = getproperty(g.data, "element")
        catch
        end
    end

    if elems === nothing
        throw(ErrorException("GGBObject.data does not contain an \"element\" array"))
    end

    # Attempt to index the collection. PythonCall indexes usually behave like
    # 1-based Julia indexing, but wrap in try/catch to provide helpful errors.
    elem = nothing
    try
        elem = elems[element_index]
    catch
        try
            # If the Python sequence is 0-based, try element_index-1
            elem = elems[element_index - 1]
        catch
            throw(BoundsError(elems, element_index))
        end
    end

    return evalXML_from_element(elem; host=host, port=port)
end


"""A lightweight Julia wrapper for objects created in the GeoGebra applet.
Holds the assigned `label` and the decoded `data` (a Python dict as PyObject).
"""

"""Refresh `g.data` by re-fetching the object's XML and decoding it.
Returns the updated `GGBObject` (modified in-place).
"""
function refresh(g::GGBObject)
    new = fetch_object(g.label)
    g.data = new.data
    return g
end

"""Mutating alias following Julia convention: `refresh!(g)` updates `g.data` in-place."""
function refresh!(g::GGBObject)
    return refresh(g)
end

"""Fetch an object's XML from the applet and decode it using the Python
`ggblab.schema.decode` function. Returns a `GGBObject`.
"""
function fetch_object(label::AbstractString)
    xml_str = ""
    try
        xml_str = send_function("getXML", string(label); host=DEFAULT_HOST, port=DEFAULT_PORT)
    catch e
        throw(ErrorException("Failed to get XML for label $(label): $(e)"))
    end
    try
        # Use the ggblab.schema entrypoint for decode to ensure we call
        # the correct wrapper object: ggb_schema().schema
        ggb_schema = PythonCall.pyimport("ggblab.schema").ggb_schema()
        schema = ggb_schema.schema
        s = strip(xml_str)
        if startswith(s, "<construction")
            xml_to_decode = s
        else
            # wrap in a single root to handle multi-root responses
            xml_to_decode = "<construction>" * s * "</construction>"
        end
        pydict = schema.decode(xml_to_decode)
        return GGBObject(string(label), pydict)
    catch e
        throw(ErrorException("Failed to decode XML for label $(label): $(e)"))
    end
end

"""Process a comma-separated labels response like "A,b,c" and fetch each
object via `fetch_object`. Returns a single `GGBObject` when one label,
otherwise a Vector{GGBObject}.
"""
function process_labels_response(resp)
    if !(resp isa AbstractString)
        return resp
    end
    labels = [strip(s) for s in split(resp, ',') if strip(s) != ""]
    # println("Processing labels response: ", labels)
    objs = [fetch_object(lbl) for lbl in labels]
    return length(objs) == 1 ? objs[1] : objs
end

"""Return a Vector of `GGBObject` for all objects currently in the applet.
This calls the applet function `getAllObjectNames` and then fetches each
object's XML and decodes it.
"""
# `list_objects` removed — it did not behave as expected. Use
# `refresh_all_objects!` which queries the applet and fetches objects.

"""Refresh all `GGBObject`s in `objs` in-place. Returns `objs`."""
function refresh!(objs::AbstractVector{GGBObject})
    for g in objs
        try
            refresh!(g)
        catch
            # ignore individual failures
        end
    end
    return objs
end


"""Send each `GGBObject` in `objs` back to the applet by reserializing
the specified element and calling `evalXML` for each. Mirrors `refresh!`'s
vector form and returns `objs`.
"""
function set_object!(objs::AbstractVector{GGBObject}; element_index::Int=1, host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    for g in objs
        try
            set_object!(g; element_index=element_index, host=host, port=port)
        catch
            # ignore individual failures to match refresh! semantics
        end
    end
    return objs
end


"""Preferred short name matching `refresh!` symmetry: `set!` is an alias
to `set_object!` for both scalar and vector forms.
"""
function set!(g::GGBObject; element_index::Int=1, host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    return set_object!(g; element_index=element_index, host=host, port=port)
end

function set!(objs::AbstractVector{GGBObject}; element_index::Int=1, host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    return set_object!(objs; element_index=element_index, host=host, port=port)
end

# `refresh_all_objects!` removed — it did not behave as expected. Use
# `fetch_object` / `refresh!` individually as needed.

# `send_command_wrap` was removed; macro now delegates to `@ggblab_command`.

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

"""Handle `@ggblab api fn(args...)` macro branch.

This internal macro is extracted to handle the API-style invocation:
`@ggblab api fn(args...)`. It constructs a runtime call that evaluates
arguments in the caller's scope and dispatches to `GeoGebra.send_function_eval`.
"""
# Macro implementing the `@ggblab` command-style behavior.
"""Send a GeoGebra command expression at runtime.

`@ggblab_command` is a helper macro used by `@ggblab` to transform an
expression such as `Circle(A, 1)` into a string command and send it
to the bridge at runtime. Symbol arguments that evaluate to `GGBObject`
instances are replaced with their `label` before sending. The macro
ensures evaluation happens in the caller's scope and returns the
processed response (calling `process_labels_response` as needed).
"""
macro ggblab_function(inner)
    if inner isa Expr && inner.head == :call
        name = inner.args[1]
        arg_nodes = inner.args[2:end]
        # Build a tuple of escaped argument expressions so they evaluate in
        # the caller's scope. `send_function_eval` will normalize the tuple
        # into an array when constructing the JSON payload.
        esc_args = Expr[]
        for a in arg_nodes
            push!(esc_args, esc(a))
        end
        args_tuple = Expr(:tuple, esc_args...)
        call_expr = Expr(:call, Expr(:call, :getfield, :(GeoGebra), QuoteNode(:send_function_eval)), QuoteNode(name), args_tuple)
        return esc(call_expr)
    else
        error("@ggblab api usage must be like `@ggblab api fn(args...)`")
    end
end

"""Primary user-facing macro to send commands or API calls.

Usage:
- `@ggblab Circle(0, 0, 1)` sends a command string to the bridge.
- `@ggblab api getVersion()` sends a function-style payload to the bridge.

The macro handles leading expansion tokens (LineNumberNode/Module), routes
API invocations to `@ggblab_function`, and routes command-style expressions
to `@ggblab_command`. The generated runtime calls evaluate arguments in
the caller scope so `x = @ggblab Circle(A, 1)` will assign the returned
value.
"""

macro isdefined_in_module(mod, sym)
    return :(isdefined($(esc(mod)), $(QuoteNode(sym))))
end

macro ggblab_command(expr)
    # Two modes:
    # - call-expr (e.g., Circle(A,1)): evaluate args at runtime so tokens
    #   `_`, `__`, `_n` are expanded and GGBObject args are converted to labels.
    # - other-expr (e.g., assignment `O = (0,0)`): fall back to string
    #   construction at macro-expansion time (original behavior).
    if expr isa Expr && expr.head == :call
        name = expr.args[1]
        arg_nodes = expr.args[2:end]

        mapped_args = Any[]
        for a in arg_nodes
            if a isa Symbol
                s = string(a)
                if s == "_"
                    push!(mapped_args, :(GeoGebra.construction_protocol()[end]))
                    continue
                elseif s == "__"
                    push!(mapped_args, :(GeoGebra.construction_protocol()[end-1]))
                    continue
                elseif startswith(s, "_") && length(s) > 1
                    numstr = s[2:end]
                    if all(isdigit, collect(numstr))
                        idx = parse(Int, numstr)
                        push!(mapped_args, Expr(:ref, :(GeoGebra.construction_protocol()), idx))
                        continue
                    end
                end
            end
            push!(mapped_args, a)
        end

        esc_args = Any[]
        for a in mapped_args
            push!(esc_args, esc(a))
        end
        args_tuple = Expr(:tuple, esc_args...)

        call_expr = Expr(:call, Expr(:call, :getfield, :(GeoGebra), QuoteNode(:send_command_eval)), QuoteNode(name), args_tuple)

        return esc(:(let _res = $(call_expr)
                        _proc = GeoGebra.process_labels_response(_res)
                        try
                            GeoGebra._push_construction_result!(_proc)
                        catch
                        end
                        _proc
                     end))
    else
        # Fallback: reproduce original static walk -> command string behavior
        # BUT: if the expression is an index/array-literal/quoted-index that
        # is intended as a construction lookup (e.g. `@ggb[1]`, `@ggb["O"]`),
        # handle those forms here to avoid sending them as commands.
        if expr isa Expr && (expr.head == :ref || expr.head == :vect)
            # Delegate to the macro-level handling by constructing an Expr
            # that queries the protocol at runtime.
            if expr.head == :vect && length(expr.args) == 1
                lbl = expr.args[1]
                lblstr = isa(lbl, QuoteNode) && isa(lbl.value, String) ? lbl.value : (isa(lbl, Symbol) ? string(lbl) : nothing)
                if lblstr !== nothing
                    return esc(:(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lblstr))]
                        isempty(lbls) ? lbls : lbls[end]
                    end))
                end
            elseif expr.head == :ref
                args_ref = expr.args
                if length(args_ref) == 0
                    return esc(:(GeoGebra.construction_protocol()))
                elseif length(args_ref) == 1
                    idx_node = args_ref[1]
                    lbl = isa(idx_node, QuoteNode) && isa(idx_node.value, String) ? idx_node.value : (isa(idx_node, Symbol) ? string(idx_node) : nothing)
                    if lbl !== nothing
                        return esc(:(begin
                            ch = GeoGebra.construction_protocol()
                                lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                                isempty(lbls) ? lbls : lbls[end]
                        end))
                    else
                        # non-label single-ref form: fall through to command fallback
                    end
                elseif length(args_ref) == 2
                    # form like construction[idx]
                    idx_node = args_ref[2]
                    lbl = isa(idx_node, QuoteNode) && isa(idx_node.value, String) ? idx_node.value : (isa(idx_node, Symbol) ? string(idx_node) : nothing)
                    if lbl !== nothing
                        return esc(:(begin
                            ch = GeoGebra.construction_protocol()
                            lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                            isempty(lbls) ? lbls : lbls[end]
                        end))
                    else
                        # non-label two-arg ref: fall through to command fallback
                    end
                end
            end
        end
        # Also handle QuoteNode forms like QuoteNode("[1]") which can appear
        # in macroexpand output; treat strings of the form "[n]" or "[\"O\"]".
        if expr isa QuoteNode && isa(expr.value, String)
            s = expr.value
            mnum = match(r"^\[(\-?\d+)\]$", s)
            if mnum !== nothing
                idx = parse(Int, mnum.captures[1])
                return esc(:(let ch = GeoGebra.construction_protocol()
                                if idx == 0
                                    throw(BoundsError("index 0 invalid"))
                                elseif idx > 0
                                    ch[$(idx)]
                                else
                                    ch[end + $(idx) + 1]
                                end
                             end))
            end
            mstr = match(r"^\[\"(.+)\"\]$", s)
            if mstr !== nothing
                lbl = mstr.captures[1]
                    return esc(:(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end))
            end
        end
        function walk(ex, depth=0)
            block = nothing
            indent = repeat(" ", depth)
            if ex isa Expr
                block = Expr(ex.head)
                for arg in ex.args
                    push!(block.args, walk(arg, depth + 1))
                end
                return block
            elseif ex isa Symbol
                if isdefined(__module__, Symbol(ex))
                    v = getfield(__module__, Symbol(ex))
                    return isa(v, GGBObject) ? Symbol(v.label) : ex
                else
                    return ex
                end
            elseif ex isa QuoteNode
                return ex.value
            else
                return ex
            end
        end
        cmd_str = string(walk(expr))
        return esc(:(let _cmd = $(QuoteNode(cmd_str))
                        _res = GeoGebra.process_labels_response(GeoGebra.send_command(_cmd))
                        try
                            GeoGebra._push_construction_result!(_res)
                        catch
                        end
                        _res
                     end))
    end
end

macro ggblab(args...)
    toks = args
    # Helper: normalize a token to String when possible (Symbol, QuoteNode(:sym), or String)
    function _tok_to_str(tok)
        if isa(tok, QuoteNode) && isa(tok.value, Symbol)
            return string(tok.value)
        elseif isa(tok, Symbol)
            return string(tok)
        elseif isa(tok, String)
            return tok
        else
            return nothing
        end
    end
    # If the macro was expanded with a leading LineNumberNode, the layout is
    # typically: (LineNumberNode, Module, expr...). Drop the first two in that case.
    if length(toks) >= 2 && toks[1] isa LineNumberNode
        toks = toks[3:end]
    elseif length(toks) >= 1 && toks[1] isa Module
        # Some callsites include just the Module as the first token; drop it.
        toks = toks[2:end]
    end

    # Special-case: handle call-form label lookup like `@ggblab :const(:O)`
    # Treat `:const(:O)` as a label lookup (equivalent to @ggb["O"]) so that
    # bracket-based indexing remains dedicated to slice/index forms.
    if length(toks) >= 2
        f = toks[1]
        s = toks[2]
        # Get a safe string representation for the first token (f).
        fstr = _tok_to_str(f)
        if fstr === nothing
            try
                fstr = string(f)
            catch
                fstr = ""
            end
        end
        # Consider it a `construction` shorthand if the token text contains "cons".
        if !isempty(fstr) && occursin("cons", lowercase(fstr)) && s isa Expr && s.head == :call && length(s.args) >= 1
            arg = s.args[1]
            lbl = _tok_to_str(arg)
            if lbl === nothing
                try
                    lbl = string(arg)
                catch
                    lbl = nothing
                end
            end
                if lbl !== nothing
                return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
            end
        end
    end
    if length(toks) == 1
        ex = toks[1]
        # Handle call-form provided as a single token: e.g. `@ggb :const(:O)`
        if ex isa Expr && ex.head == :call && length(ex.args) >= 2
            fn = ex.args[1]
            fnstr = _tok_to_str(fn)
            if fnstr === nothing
                try
                    fnstr = string(fn)
                catch
                    fnstr = nothing
                end
            end
            if fnstr !== nothing && startswith(fnstr, "cons")
                # extract inner arg which may be Symbol, QuoteNode, or Expr
                arg = ex.args[2]
                if arg isa Expr && length(arg.args) >= 1
                    cand = arg.args[1]
                else
                    cand = arg
                end
                lbl = _tok_to_str(cand)
                if lbl === nothing
                    try
                        lbl = string(cand)
                    catch
                        lbl = nothing
                    end
                end
                if lbl !== nothing && lbl != ":" && lbl != "end"
                    return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
                end
            end
        end
        # Early-handle common indexed/quoted forms so they are treated as
        # construction lookups instead of falling through to command send.
        # numeric indexing intentionally unsupported here; fall through
        if ex isa QuoteNode && isa(ex.value, String)
            s = ex.value
            # Only support string label forms like ["O"] here
            mstr = match(r"^\s*\[\s*\"(.+)\"\s*\]\s*$", s)
                if mstr !== nothing
                lbl = mstr.captures[1]
                return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
            end
        end
        if ex isa Expr && ex.head == :vect && length(ex.args) == 1
            # single-element vector literal: treat as label lookup when possible
            lbl = _tok_to_str(ex.args[1])
            if lbl !== nothing
                return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
            end
        end
    end
    # Support special construction inspection syntax:
    # - `@ggblab construction` -> returns the full construction history
    # - `@ggblab construction[n]` -> returns the nth entry from history
    if length(toks) >= 1
        first = toks[1]
        is_cons_str = s -> (isa(s, String) && length(s) >= 4 && startswith(s, "cons"))
        # Shortcut commands under the `:const` namespace, e.g.:
        # - `@ggb :const :new`  -> start a new construction (clears history)
        # - `@ggb :const :undo` -> undo last construction entry (returns nothing)
        fstr_top = _tok_to_str(first)
        if fstr_top !== nothing && is_cons_str(fstr_top) && length(toks) >= 2
            snd = toks[2]
            sndstr = _tok_to_str(snd)
            if sndstr === "new"
                # Call the module function which itself invokes the bridge API.
                return esc(:(GeoGebra.new_construction!()))
            elseif sndstr === "undo"
                return esc(:(let ch = GeoGebra.construction_protocol(); if !isempty(ch)
                                    g = pop!(ch)
                                    try
                                        GeoGebra.send_function("deleteObject", g.label)
                                    catch
                                    end
                                end; nothing end))
            end
        end
        if first isa Expr && first.head == :vect
            # Handle array-literal form like @ggb["O"] where the macro sees
            # an Expr(:vect, elem...). If single-element and the element is a
            # string/symbol/quoted symbol, treat as label lookup into construction.
            elems = first.args
            if length(elems) == 1
                lbl = _tok_to_str(elems[1])
                if lbl !== nothing
                    expr = :(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end)
                    return esc(expr)
                end
            end
        end

        if first isa Expr && first.head == :ref
            args_ref = first.args
            # Case 0: empty index -> return all construction entries
            if length(args_ref) == 0
                return esc(:(GeoGebra.construction_protocol()))
            end
            # Case A: form like `construction[idx]` (two-arg ref)
            if length(args_ref) == 2
                headsym = args_ref[1]
                hstr = _tok_to_str(headsym)
                if is_cons_str(hstr)
                    idx_node = args_ref[2]
                    # If the index node is a parenthesized/call form like `(:O)`
                    # or `:const(:O)`, extract the inner token and treat it as a
                    # label lookup. Otherwise fall back to direct token-to-string.
                    if idx_node isa Expr && (idx_node.head == :call || idx_node.head == :paren) && length(idx_node.args) >= 1
                        lbl = _tok_to_str(idx_node.args[1])
                    else
                        lbl = _tok_to_str(idx_node)
                    end
                    if lbl !== nothing && lbl != ":" && lbl != "end"
                        expr = :(begin
                            ch = GeoGebra.construction_protocol()
                            lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                            isempty(lbls) ? lbls : lbls[end]
                        end)
                        return esc(expr)
                    else
                        # Simplified support: accept full-slice `:`/`[:]`, `[end]`,
                        # or a positive integer index like `1` or `[1]`.
                        # Handle various parser node shapes for slice/index forms
                        # Prefer structural checks when possible (Expr/Symbol),
                        # falling back to string-matching for QuoteNode/text forms.
                        if isa(idx_node, Expr)
                            # vector literal form like `[:]' or `[:]' -> Expr(:vect, ...)
                            if idx_node.head == :vect && length(idx_node.args) == 1
                                e = idx_node.args[1]
                                if isa(e, Symbol) && string(e) == ":"
                                    return esc(:([(i, g.label, GeoGebra.send_function("getCommandString", g.label)) for (i, g) in enumerate(GeoGebra.construction_protocol())]))
                                elseif isa(e, Symbol) && string(e) == "end"
                                    return esc(:(let ch = GeoGebra.construction_protocol(); g = ch[end]; (length(ch), g.label, GeoGebra.send_function("getCommandString", g.label)) end))
                                end
                            end
                            # direct colon expression (rare) -> treat as full slice
                            if idx_node.head == :colon
                                return esc(:([(i, g.label, GeoGebra.send_function("getCommandString", g.label)) for (i, g) in enumerate(GeoGebra.construction_protocol())]))
                            end
                        end
                        s = isa(idx_node, QuoteNode) && isa(idx_node.value, String) ? idx_node.value : string(idx_node)
                        # Full-slice forms -> return all tuples
                        if strip(s) == ":" || match(r"^\s*\[\s*:\s*\]\s*$", s) !== nothing
                            return esc(:([(i, g.label, GeoGebra.send_function("getCommandString", g.label)) for (i, g) in enumerate(GeoGebra.construction_protocol())]))
                        end
                        # [end]
                        if match(r"^\s*\[?\s*end\s*\]?\s*$", s) !== nothing
                            return esc(:(let ch = GeoGebra.construction_protocol(); g = ch[end]; (length(ch), g.label, GeoGebra.send_function("getCommandString", g.label)) end))
                        end
                        # Positive integer index fallback like "1" or "[1]"
                        m = match(r"^\s*\[?\s*(\d+)\s*\]?\s*$", s)
                        if m !== nothing
                            numstr = m.captures[1]
                            return esc(:(let ch = GeoGebra.construction_protocol();
                                            idx = parse(Int, $(QuoteNode(numstr)));
                                            if idx == 0
                                                throw(BoundsError("index 0 invalid"))
                                            end
                                            g = ch[idx]
                                            (idx, g.label, GeoGebra.send_function("getCommandString", g.label))
                                         end))
                        end
                        # non-label two-arg ref: fall through to command fallback
                    end
                end
            # Case B: form like `@ggb[idx]` (single-arg ref) — treat as construction lookup
            elseif length(args_ref) == 1
                idx_node = args_ref[1]
                lbl = _tok_to_str(idx_node)
                if lbl !== nothing
                    expr = :(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end)
                    return esc(expr)
                else
                    # non-label single-ref: fall through to command fallback
                end
            end
        else
            fstr = _tok_to_str(first)
            if is_cons_str(fstr)
                return esc(:([(i, g.label, GeoGebra.send_function("getCommandString", g.label)) for (i, g) in enumerate(GeoGebra.construction_protocol())]))
            end
        end
    end
    ex = nothing
    if length(toks) == 1
        ex = toks[1]
        # Additional handling: if macro is invoked with a bare index form like
        # `@ggb[1]` the parser may present the index as various node types
        # (Integer, QuoteNode("[1]"), Expr(:vect,...)). Normalize common
        # cases here so they are treated as construction lookups rather than
        # falling back to sending a command string.
        # Normalize single-token vector forms (label lookup). Numeric bare-index
        # forms (e.g. @ggb[1]) are intentionally not supported and will fall
        # through to the command fallback — this keeps behavior consistent
        # with @ggb[:O] / @ggb["O"] label lookups which are supported above.
        if ex isa Expr && ex.head == :vect
            elems = ex.args
            if length(elems) == 1
                lbl = _tok_to_str(elems[1])
                if lbl !== nothing
                        return esc(:((begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end)))
                end
            end
        end
    else
        tokstr = _tok_to_str(toks[1])
        if tokstr == "api"
            if length(toks) < 2
                error("@ggblab api usage must be like `@ggblab api fn(args...)`")
            end
            ex = Expr(:call, :api, toks[2])
        else
            head = toks[1]
            args_rest = toks[2:end]
            ex = Expr(:call, head, args_rest...)
        end
    end

    if ex isa Expr && ex.head == :call && ex.args !== nothing && length(ex.args) >= 1 && ex.args[1] == :api
        inner = ex.args[2]
        return Expr(:macrocall, Symbol("@ggblab_function"), __source__, inner)
    end

    # Delegate non-API branch to the module-qualified `@ggblab_command` macro
    return Expr(:macrocall, Symbol("@ggblab_command"), __source__, ex)
end


# Alias `@pggb` to `@ggblab` for convenience
# const var"@ggb" = var"@ggblab"

@eval const $(Symbol("@ggb")) = $(Symbol("@ggblab"))

# macro ggb(args...)
#     return esc(Expr(:macrocall, Symbol("@ggblab"), args...))
# end

"""Run a Python coroutine (PythonCall.PyObject) with asyncio.run.

Usage:
```
# obtain a coroutine object, e.g. via `py"coro()"` or `pyeval("coro()")`
# coro = py"coro()"
result = @await coro
```
"""
macro await(expr)
    return :(let _asyncio = PythonCall.pyimport("asyncio")
                _coro = $(esc(expr))
                _asyncio.run(_coro)
             end)
end



export request, poll_reply, request_with_retry, set_default_host, set_default_port, send_command, send_function, send_command_eval, send_function_eval, fetch_object, refresh, refresh!, GGBObject, set_object!, set!, construction_protocol, new_construction!, evalXML_from_element, @ggblab, @ggb, @ggblab_command, @ggblab_function, @await, OOBClient

end # module
