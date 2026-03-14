module GeoGebra

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

# Implicit construction history (default construction protocol storage).
# Use a `Ref` to allow rebinding the contained vector without changing the
# exported binding; users should use provided APIs rather than touching this.
const _CONSTRUCTION_HISTORY = Ref{Vector{GGBObject}}(GGBObject[])

"""Return the current construction history vector (live reference)."""
function construction_history()
    return _CONSTRUCTION_HISTORY[]
end

"""Clear the construction history in-place and return the cleared vector."""
function clear_construction_history!()
    empty!(_CONSTRUCTION_HISTORY[])
    return _CONSTRUCTION_HISTORY[]
end

"""Dump the construction history to `path` as a simple textual report.
Each entry contains the object's label and a `show` rendering of its data.
"""
function dump_construction_history(path::AbstractString)
    open(path, "w") do io
        for g in _CONSTRUCTION_HISTORY[]
            println(io, "Label: ", g.label)
            try
                show(io, g.data)
            catch
                println(io, "<unshowable data>")
            end
            println(io, "\n---\n")
        end
    end
    return path
end

"""Internal helper to append result(s) into the construction history.
Accepts a single `GGBObject` or a vector of them."""
function _push_construction_result!(res)
    if isa(res, GGBObject)
        push!(_CONSTRUCTION_HISTORY[], res)
    elseif isa(res, AbstractVector{GGBObject})
        append!(_CONSTRUCTION_HISTORY[], res)
    end
    return _CONSTRUCTION_HISTORY[]
end


"""Encode a single `element`-shaped dict using the Python-side schema
and send it to the applet via the `evalXML` API.

`elem_data` should be the dictionary representing a single element as
produced in `GGBObject.data["element"][i]`.
"""
function evalXML_from_element(elem_data; host::String=DEFAULT_HOST, port::Int=DEFAULT_PORT)
    try
        xmlschema = PythonCall.pyimport("xmlschema")
        pyggb = PythonCall.pyimport("ggblab")
        # Encode the element into an ElementTree (or compatible object)
        encoded = getproperty(pyggb, :schema).encode(elem_data, "element")
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
        py = PythonCall.pyimport("ggblab")
        schema = getproperty(py, :schema)
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
                    push!(mapped_args, :(GeoGebra.construction_history()[end]))
                    continue
                elseif s == "__"
                    push!(mapped_args, :(GeoGebra.construction_history()[end-1]))
                    continue
                elseif startswith(s, "_") && length(s) > 1
                    numstr = s[2:end]
                    if all(isdigit, collect(numstr))
                        idx = parse(Int, numstr)
                        push!(mapped_args, Expr(:ref, :(GeoGebra.construction_history()), idx))
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
    if length(toks) == 0
        error("@ggblab requires an expression")
    end
    # Support special construction inspection syntax:
    # - `@ggblab construction` -> returns the full construction history
    # - `@ggblab construction[n]` -> returns the nth entry from history
    if length(toks) >= 1
        first = toks[1]
        is_cons_str = s -> (isa(s, String) && length(s) >= 4 && startswith(s, "cons"))
        if first isa Expr && first.head == :ref
            headsym = first.args[1]
            hstr = _tok_to_str(headsym)
            if is_cons_str(hstr)
                idx = first.args[2]
                return esc(Expr(:ref, :(GeoGebra.construction_history()), idx))
            end
        else
            fstr = _tok_to_str(first)
            if is_cons_str(fstr)
                return esc(:(GeoGebra.construction_history()))
            end
        end
    end
    ex = nothing
    if length(toks) == 1
        ex = toks[1]
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



export request, poll_reply, request_with_retry, set_default_host, set_default_port, send_command, send_function, send_command_eval, send_function_eval, fetch_object, refresh, refresh!, GGBObject, set_object!, set!, construction_history, clear_construction_history!, dump_construction_history, evalXML_from_element, @ggblab, @ggb, @ggblab_command, @ggblab_function, @await

end # module
