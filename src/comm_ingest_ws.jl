"""WebSocket ingest server (TCP).

Starts a TCP WebSocket server bound to localhost on a given port (default
8081) and forwards incoming text messages (JSON) into the kernel comm
queues via `_enqueue_comm_message` and `INGEST_HANDLER_CHANNEL`.

This file provides `start_ingest_ws_server(; port=nothing)` which returns
`(port, task)` where `task` is the background Task running the server.
"""

using HTTP
using HTTP.WebSockets
using JSON

# Keep a reference to the background Task so it isn't garbage-collected.
const INGEST_WS_TASK = Ref{Union{Task,Nothing}}(nothing)

function start_ingest_ws_server(; port::Union{Nothing,Int}=nothing)
    # assume HTTP and HTTP.WebSockets are available (using above)

    host = "127.0.0.1"
    p = port === nothing ? 8081 : Int(port)

    task = @async begin
        try
            println("[comm_ingest_ws] Starting WebSocket server on ws://$(host):$(p)")

            println("[comm_ingest_ws] Starting WebSocket server on ws://$(host):$(p)")

            # Use the simple pattern requested:
            # HTTP.listen(host, port) do http
            #   HTTP.WebSockets.listen(http) do ws
            #       ...
            #   end
            # end
            # Use the simple pattern the user requested and which matches many
            # HTTP.jl examples: pass the block argument through to
            # `HTTP.WebSockets.listen` and handle messages directly.
            # Direct WebSocket server using host/port (simple pattern)
            HTTP.WebSockets.listen(host, p) do ws
                println("[comm_ingest_ws] Client connected")
                try
                    for msg in ws
                        # Echo back and forward into comm system
                        try
                            send(ws, msg)
                        catch _
                        end
                        println("[comm_ingest_ws] Received: ", msg)
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
                                @warn "comm_ingest_ws: no registered comms to route message to"
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
                    end
                finally
                    println("[comm_ingest_ws] Client disconnected")
                end
            end
        catch err
            @warn "comm_ingest_ws: listener terminated" err=err
        end
    end

    INGEST_WS_TASK[] = task
    return (p, task)
end

