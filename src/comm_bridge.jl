module CommBridge

using JSON
# using PythonCall

# Simple TCP JSON bridge client utilities extracted from backup.
# These functions implement a TCP transport for the bridge and are
# intentionally grouped in this submodule so other transport
# implementations can be added later.

# Internal: send/receive a JSON line over TCP
function _tcp_send_and_recv(msg::String; host::String="127.0.0.1", port::Int=8765, timeout::Real=10.0)
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

function _tcp_unwrap_reply(resp)
    if resp isa AbstractDict && haskey(resp, "reply")
        return resp["reply"]
    else
        return resp
    end
end

function request_tcp(payload; host::String="127.0.0.1", port::Int=8765, timeout::Real=10.0)
    data = isa(payload, String) ? payload : JSON.json(payload)
    return _tcp_unwrap_reply(_tcp_send_and_recv(data; host=host, port=port, timeout=timeout))
end

function send_command_tcp(cmd_text::AbstractString; host::String="127.0.0.1", port::Int=8765)
    payload = Dict("type"=>"command", "payload"=>cmd_text)
    return request_tcp(payload; host=host, port=port)
end

function send_function_tcp(name, args...; host::String="127.0.0.1", port::Int=8765)
    # If `name` is a collection, send it as a JSON array of strings so the
    # frontend receives a real list instead of Julia's printed representation.
    if isa(name, AbstractArray)
        name_field = [isa(n, Symbol) ? string(n) : string(n) for n in name]
    else
        name_field = isa(name, Symbol) ? string(name) : string(name)
    end
    arg_strs = [string(a) for a in args]
    args_field = length(arg_strs) == 0 ? nothing : arg_strs
    payload = Dict("type"=>"function", "payload"=>Dict("name"=>name_field, "args"=>args_field))
    resp = request_tcp(payload; host=host, port=port)
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
        # fall through
    end
    return resp
end

function send_command_eval_tcp(name, args_tuple)
    args = Tuple((isa(a, GGBObject) ? a.label : a) for a in args_tuple)
    name_str = isa(name, Symbol) ? string(name) : string(name)
    arg_strs = [string(a) for a in args]
    cmd_text = string(name_str, "(", join(arg_strs, ", "), ")")
    return send_command_tcp(cmd_text)
end

function send_function_eval_tcp(name, args_tuple)
    args = Tuple((isa(a, GGBObject) ? a.label : a) for a in args_tuple)
    return send_function_tcp(name, args...)
end

# High-level transport abstraction
const _REQUEST_HANDLER = Ref{Function}(payload -> request_tcp(payload))

"""Set a custom request handler function that accepts a payload and returns a reply.
By default the TCP bridge `request_tcp` is used. Users can call
`set_request_handler!(fn)` to route requests to a different transport (e.g. comm_direct).
"""
function set_request_handler!(fn::Function)
    _REQUEST_HANDLER[] = fn
    return nothing
end

function request(payload; host::String="127.0.0.1", port::Int=8765, timeout::Real=10.0)
    # Handler is responsible for interpreting host/port if needed.
    return _REQUEST_HANDLER[](payload)
end

function send_command(cmd_text::AbstractString; host::String="127.0.0.1", port::Int=8765)
    payload = Dict("type"=>"command", "payload"=>cmd_text)
    return request(payload; host=host, port=port)
end

function send_function(name, args...; host::String="127.0.0.1", port::Int=8765)
    # If `name` is iterable, convert to an array of strings so the JSON payload
    # contains a proper list instead of a single string like "Any[...]".
    if isa(name, AbstractArray)
        name_field = [isa(n, Symbol) ? string(n) : string(n) for n in name]
    else
        name_field = isa(name, Symbol) ? string(name) : string(name)
    end
    arg_strs = [string(a) for a in args]
    args_field = length(arg_strs) == 0 ? nothing : arg_strs
    payload = Dict("type"=>"function", "payload"=>Dict("name"=>name_field, "args"=>args_field))
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
        # fall through
    end
    return resp
end

function send_command_eval(name, args_tuple; host::String="127.0.0.1", port::Int=8765)
    args = Tuple((isa(a, GGBObject) ? a.label : a) for a in args_tuple)
    name_str = isa(name, Symbol) ? string(name) : string(name)
    arg_strs = [string(a) for a in args]
    cmd_text = string(name_str, "(", join(arg_strs, ", "), ")")
    return send_command(cmd_text; host=host, port=port)
end

function send_function_eval(name, args_tuple; host::String="127.0.0.1", port::Int=8765)
    args = Tuple((isa(a, GGBObject) ? a.label : a) for a in args_tuple)
    return send_function(name, args...; host=host, port=port)
end

export request_tcp, send_command_tcp, send_function_tcp, send_command_eval_tcp, send_function_eval_tcp,
       set_request_handler!, request, send_command, send_function, send_command_eval, send_function_eval

end # module CommBridge
