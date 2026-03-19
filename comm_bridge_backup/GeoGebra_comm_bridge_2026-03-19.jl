module GeoGebra

# Include package-local OOBClient implementation and expose it from this package
try
    include("OOBClient.jl")
    using .OOBClient
catch
    # Fail silently; OOBClient is optional in some contexts
end

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

using JSON
using PythonCall

# Defaults are mutable so users can change the bridge host/port at runtime
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765

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
    data = isa(payload, String) ? payload : JSON.json(payload)
    return _unwrap_reply(_send_and_recv(data; host=host, port=port, timeout=timeout))
end

"""Send a textual GeoGebra command string directly to the bridge.

`cmd_text` should be a complete command such as `A = (0,0)`,
`Circle(A, 1)`, or `l1 = {Intersect(g,f)}`. The function sends the string
unchanged as the command payload.
"""
function send_command(cmd_text::AbstractString; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    payload = Dict("type"=>"command", "payload"=>cmd_text)
    return request(payload; host=host, port=port)
end

"""Send a function call payload to the bridge.

`name` is the function name (Symbol or String); `args` are converted to
strings and sent inside the `payload` object:
`{"type":"function","payload":{"name":...,"args":[...]}}`.
"""
function send_function(name, args...; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    name_str = isa(name, Symbol) ? string(name) : string(name)
    arg_strs = [string(a) for a in args]
    args_field = length(arg_strs) == 0 ? nothing : arg_strs
    payload = Dict("type"=>"function", "payload"=>Dict("name"=>name_str, "args"=>args_field))
    resp = request(payload; host=host, port=port)
    try
        if resp isa AbstractDict && haskey(resp, "value")
            return resp["value"]
        elseif resp isa AbstractDict && haskey(resp, "payload")
            p = resp["payload"]
            if p isa AbstractDict && haskey(p, "value")
                return p["value"]
            end
        end
    catch
        # fall through and return original response on any error
    end
    return resp
end

"""Helper called by the macro: evaluate an argument tuple and call `send_command`.
When arguments include a `GGBObject`, replace it with its `label` before sending."""
function send_command_eval(name, args_tuple)
    # evaluate and normalize args: replace GGBObject with its label
    args = Tuple((isa(a, GGBObject) ? a.label : a) for a in args_tuple)
    name_str = isa(name, Symbol) ? string(name) : string(name)
    arg_strs = [string(a) for a in args]
    cmd_text = string(name_str, "(", join(arg_strs, ", "), ")")
    return send_command(cmd_text; host=DEFAULT_HOST, port=DEFAULT_PORT)
end

"""Helper called by the macro: evaluate an argument tuple and call `send_function`.
When arguments include a `GGBObject`, replace it with its `label` before sending."""
function send_function_eval(name, args_tuple)
    args = Tuple((isa(a, GGBObject) ? a.label : a) for a in args_tuple)
    return send_function(name, args...; host=DEFAULT_HOST, port=DEFAULT_PORT)
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
