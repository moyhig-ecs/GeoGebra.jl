module CommBridge

using JSON
using PythonCall

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
    name_str = isa(name, Symbol) ? string(name) : string(name)
    arg_strs = [string(a) for a in args]
    args_field = length(arg_strs) == 0 ? nothing : arg_strs
    payload = Dict("type"=>"function", "payload"=>Dict("name"=>name_str, "args"=>args_field))
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

export request_tcp, send_command_tcp, send_function_tcp, send_command_eval_tcp, send_function_eval_tcp

end # module CommBridge
