"""Utilities for representing and managing objects created in the
GeoGebra applet and a simple in-memory construction protocol.

This file provides the `GGBObject` container type, a construction
protocol storage, and helpers to fetch, refresh, serialize and send
elements back to the applet. Functions here are designed to be
lightweight wrappers around the Python/GeoGebra bridge used by the
package.
"""

"""A lightweight wrapper for objects created in the GeoGebra applet.

Fields
- `label::String`: the GeoGebra-assigned object label (e.g. "A", "p1").
- `data::Any`: decoded object data (typically a Python dict via PythonCall).

`GGBObject` is used throughout the package to represent and update
objects fetched from or sent to the applet.
"""
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

# Normalize lowercase scientific 'e' to uppercase 'E' in numeric literals.
# GeoGebra can emit numbers like "3.67e-16" which may not match XML
# schema patterns that expect 'E'. This helper performs a conservative
# regex replacement to convert the exponent marker.
function _normalize_exponent(xml::AbstractString)
    try
        return replace(xml, r"(?<=\d)e(?=[+-]?\d+)" => "E")
    catch
        return xml
    end
end

_normalize_exponent(x) = x

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
    # Defensive synchronous fetch: prefer TCP bridge to avoid re-entering
    # kernel-side comm handlers; add guards for pathological XML and
    # handle decode failures gracefully by returning a placeholder
    lbl = string(label)
    xml_str = ""
    try
        t = @async send_function("getXML", lbl; host=DEFAULT_HOST, port=DEFAULT_PORT)
        xml_str = fetch(t)
    catch e
        @warn "fetch_object: failed to fetch XML" label=lbl err=e
        pdata = Dict("__fetch_failed__" => true, "error" => string(e))
        return GGBObject(lbl, pdata)
    end

    try
        xml_str = _normalize_exponent(xml_str)
        s = strip(xml_str)
        xml_to_decode = startswith(s, "<construction") ? s : "<construction>" * s * "</construction>"
        xml_to_decode = _normalize_exponent(xml_to_decode)

        # Decode using Python-side schema; catch stack overflows and other errors
        try
            ggb_schema = PythonCall.pyimport("ggblab.schema").ggb_schema()
            schema = ggb_schema.schema
            pydict = schema.decode(xml_to_decode)
            return GGBObject(lbl, pydict)
        catch err_decode
            msg = string(err_decode)
            if err_decode isa StackOverflowError || occursin("StackOverflowError", msg)
                @warn "fetch_object: StackOverflowError during decode" label=lbl err=msg
                truncated = length(xml_to_decode) > 4096 ? first(xml_to_decode, 4096) * "..." : xml_to_decode
                pdata = Dict("__decode_failed__" => true, "raw_xml_truncated" => string(truncated), "error_message" => msg)
                return GGBObject(lbl, pdata)
            else
                @warn "fetch_object: decode error" label=lbl err=err_decode
                pdata = Dict("__decode_failed__" => true, "error_message" => string(err_decode))
                return GGBObject(lbl, pdata)
            end
        end
    catch e
        @warn "fetch_object: unexpected error during decode prep" label=lbl err=e
        pdata = Dict("__decode_failed__" => true, "error_message" => string(e))
        return GGBObject(lbl, pdata)
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


"""Return the most-recent `GGBObject` in the construction protocol
matching `label`, or `nothing` if no such object exists.

Example:
```
# returns GGBObject or nothing
obj = get_construction_object("A")
```
"""
function get_construction_object(label::AbstractString)
    ch = _CONSRUCTION_PROTOCOL[]
    matches = [g for g in ch if string(g.label) == string(label)]
    return isempty(matches) ? nothing : matches[end]
end

"""Return all `GGBObject`s in the construction protocol matching `label`.
Returns an empty vector when none match."""
function get_construction_objects(label::AbstractString)
    ch = _CONSRUCTION_PROTOCOL[]
    return [g for g in ch if string(g.label) == string(label)]
end

