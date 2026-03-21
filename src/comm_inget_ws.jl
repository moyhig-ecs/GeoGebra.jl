"""WebSocket ingest server (TCP).

Starts a TCP WebSocket server bound to localhost on an ephemeral port
and forwards incoming text messages (JSON) into the kernel comm queues
via `_enqueue_comm_message` and `INGEST_HANDLER_CHANNEL`.

API:
- `start_ingest_ws_server(; port=nothing)` -> `(port, task)` : starts
  a background task listening for WebSocket connections and returns
  the numeric port and the Task handle.
"""

using Sockets
using JSON

const HTTP_WS_AVAILABLE = try
    @eval using HTTP
    @eval using HTTP.WebSockets
    true
catch
    false
end

export start_ingest_ws_server

function _extract_port_from_sock(server)
    addr = try
        Sockets.getsockname(server)
    catch
        nothing
    end
    if addr === nothing
        return 0
    end
    try
        if isa(addr, Tuple) && length(addr) >= 2
            return Int(addr[2])
        elseif hasproperty(addr, :port)
            return Int(getfield(addr, :port))
        else
            s = string(addr)
            parts = split(s, ":")
            return parse(Int, parts[end])
        end
    catch
        return 0
    end
end

function start_ingest_ws_server(; port::Union{Nothing,Int}=nothing)
    if !HTTP_WS_AVAILABLE
        throw(ErrorException("comm_inget_ws: HTTP.WebSockets not available; install HTTP.jl"))
    end

    # Bind to provided port or ephemeral port (0)
    host = "127.0.0.1"
    p = port === nothing ? 0 : Int(port)
    server = nothing
    try
        server = Sockets.listen(host, p)
    catch err
        throw(ErrorException("comm_inget_ws: failed to bind TCP socket: $err"))
    end

    ws_port = _extract_port_from_sock(server)

    task = @async begin
        try
            HTTP.WebSockets.listen!(server) do ws
                println("[comm_inget_ws] ws client connected on port $(ws_port)")
                try
                    for msg in ws
                        try
                            println("[comm_inget_ws] ws received: ", msg)
                            parsed = try JSON.parse(msg) catch msg end
                            k = nothing
                            if isa(parsed, AbstractDict)
                                if haskey(parsed, "comm_key")
                                    k = string(parsed["comm_key"])
                                elseif haskey(parsed, "key")
                                    k = string(parsed["key"])
                                elseif haskey(parsed, "kernelId")
                                    k = string(parsed["kernelId"])
                                end
                            end
                            if k === nothing
                                ks = list_registered_comm_keys()
                                if isempty(ks)
                                    @warn "comm_inget_ws: no registered comms to route message to"
                                    continue
                                end
                                k = ks[1]
                            end
                            s = try isa(parsed, AbstractString) ? parsed : JSON.json(parsed) catch; string(parsed) end
                            _enqueue_comm_message(k, s)
                            conn = get_registered_connection(k)
                            if conn !== nothing
                                put!(INGEST_HANDLER_CHANNEL, (conn, parsed))
                            end
                        catch err_msg
                            @warn "comm_inget_ws: websocket message handler error" err=err_msg
                        end
                    end
                catch err_ws
                    @warn "comm_inget_ws: websocket connection failed" err=err_ws
                finally
                    try close(ws) catch end
                end
            end
        catch err
            @warn "comm_inget_ws: websocket listener terminated" err=err
        finally
            try close(server) catch end
        end
    end

    return (ws_port, task)
end
