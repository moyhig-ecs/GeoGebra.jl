"""WebSocket ingest server (TCP).

Starts a TCP WebSocket server bound to localhost on a given port (default
8081) and forwards incoming text messages (JSON) into the kernel comm
queues via `_enqueue_comm_message` and `INGEST_HANDLER_CHANNEL`.

This file provides `start_ingest_ws_server(; port=nothing)` which returns
`(port, task)` where `task` is the background Task running the server.
"""

using Sockets
using Sockets
using HTTP
using HTTP.WebSockets
using JSON
using Logging

# Helper to rethrow InterruptException so Ctrl-C / task interrupts
# are not swallowed by broad `catch err` handlers.
function _rethrow_if_interrupt(err)
    if err isa InterruptException
        rethrow(err)
    end
end

# Keep a reference to the background Task so it isn't garbage-collected.
const INGEST_WS_TASK = Ref{Union{Task,Nothing}}(nothing)

function start_ingest_ws_server(; port::Union{Nothing,Int}=nothing)
    # assume HTTP and HTTP.WebSockets are available (using above)

    host = "127.0.0.1"
    if port === nothing
        # find an ephemeral (free) port by binding to port 0 and then closing
        function _find_free_port()
            srv = nothing
            try
                srv = Sockets.listen(0)
                a, p = Sockets.getsockname(srv)
                return p
            catch err
                _rethrow_if_interrupt(err)
                @warn "start_ingest_ws_server: failed to find free port, defaulting to 8081" err=err
                return 8081
            finally
                try
                    if srv !== nothing && isopen(srv)
                        close(srv)
                    end
                catch err
                    _rethrow_if_interrupt(err)
                    @warn "start_ingest_ws_server: failed to close temporary socket" err=err
                end
            end
        end

        p = _find_free_port()
        @debug "start_ingest_ws_server: auto-selected free port $p" host=host
    else
        p = Int(port)
    end
    @debug "start_ingest_ws_server: starting WebSocket server on port $p" host=host
    task = @async begin
        try
            @debug "[comm_ingest_ws] Starting WebSocket server" host=host port=p

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
                @debug "[comm_ingest_ws] Client connected"
                # Per-connection channels to decouple reading from processing
                in_chan = Channel{Any}(128)
                out_chan = Channel{Any}(8)

                # Reading task: put raw messages onto the inbound channel
                read_task = Base.Threads.@spawn begin
                    try
                        for msg in ws
                            try
                                put!(in_chan, msg)
                            catch err_put
                                _rethrow_if_interrupt(err_put)
                                @warn "comm_ingest_ws: failed to put message into in_chan" err=err_put
                            end
                        end
                    catch err
                        _rethrow_if_interrupt(err)
                        @warn "comm_ingest_ws: WebSocket read error" err=err
                    finally
                        try
                            close(in_chan)
                        catch err
                            _rethrow_if_interrupt(err)
                        end
                    end
                end

                # Processing task: consume inbound messages and forward to kernel
                proc_task = Base.Threads.@spawn begin
                    for raw in in_chan
                        try
                            @debug "[comm_ingest_ws] Received message" msg=raw
                            parsed = try JSON.parse(raw) catch raw end
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
                            try
                                _enqueue_comm_message(k, s)
                            catch err
                                _rethrow_if_interrupt(err)
                                @warn "comm_ingest_ws: _enqueue_comm_message failed" err=err
                            end
                            conn = get_registered_connection(k)
                            if conn !== nothing
                                try
                                    put!(INGEST_HANDLER_CHANNEL, (conn, parsed))
                                catch err_put
                                    _rethrow_if_interrupt(err_put)
                                    @warn "comm_ingest_ws: INGEST_HANDLER_CHANNEL put failed" err=err_put
                                end
                            end
                        catch err
                            _rethrow_if_interrupt(err)
                            @warn "comm_ingest_ws: message processing failed" err=err
                        end
                    end
                end

                # Outbound task placeholder: user requested not to send, so we
                # keep a separate loop ready to handle outbound messages but
                # do not perform `send(ws, ...)` here.
                out_task = Base.Threads.@spawn begin
                    try
                        while isopen(ws)
                            msg = take!(out_chan) # currently not used
                            @debug "comm_ingest_ws: outbound message (not sent)" msg=msg
                        end
                    catch err
                        # ignore and allow graceful shutdown
                    end
                end

                # Wait for read and processing tasks to finish
                try
                    wait(read_task)
                    wait(proc_task)
                catch err
                    _rethrow_if_interrupt(err)
                finally
                    @debug "[comm_ingest_ws] Client disconnected"
                    try
                        close(out_chan)
                    catch err
                        _rethrow_if_interrupt(err)
                    end
                end
            end
        catch err
            _rethrow_if_interrupt(err)
            @warn "comm_ingest_ws: listener terminated" err=err
        end
    end

    INGEST_WS_TASK[] = task
    # Return a named tuple so callers can access `.port` or destructure
    return (port=p, task=task)
end

