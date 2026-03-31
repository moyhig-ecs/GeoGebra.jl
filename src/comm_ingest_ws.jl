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
# Keep listener host/port so `stop_ingest_ws_server()` can poke the
# listener to ensure it wakes up and exits.
const INGEST_WS_HOST = Ref{Union{Nothing,String}}(nothing)
const INGEST_WS_PORT = Ref{Union{Nothing,Int}}(nothing)
# Last activity timestamp and idle-monitor task
# `INGEST_WS_LAST_ACTIVITY` is 0.0 when no message has yet been received.
const INGEST_WS_LAST_ACTIVITY = Ref{Float64}(0.0)
const INGEST_WS_IDLE_SECONDS = Ref{Int}(0)
const INGEST_WS_MONITOR = Ref{Union{Task,Nothing}}(nothing)

function start_ingest_ws_server(; port::Union{Nothing,Int}=nothing, idle_timeout::Int=3)
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
    # Supervisor task: keep restarting the listener so service is
    # continuous. When the listener exits (e.g. due to socket close),
    # the loop will start a fresh listener immediately.
    task = @async begin
        while true
            try
                @debug "[comm_ingest_ws] Starting WebSocket server" host=host port=p
                HTTP.WebSockets.listen(host, p) do ws
                    @debug "[comm_ingest_ws] Client connected"
                    try
                        for msg in ws
                            # each incoming message processed async to avoid
                            # blocking the receive loop
                            @async begin
                                try
                                    @debug "[comm_ingest_ws] Received message" msg=msg
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
                                            return
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
                                    # update last-activity timestamp for idle detection
                                    try
                                        prev = INGEST_WS_LAST_ACTIVITY[]
                                        INGEST_WS_LAST_ACTIVITY[] = time()
                                        # start idle-monitor only after first receive
                                        if prev == 0.0 && INGEST_WS_IDLE_SECONDS[] > 0 && INGEST_WS_MONITOR[] === nothing
                                            INGEST_WS_MONITOR[] = @async begin
                                                try
                                                    idle_timeout = INGEST_WS_IDLE_SECONDS[]
                                                    while true
                                                        sleep(max(1, min(idle_timeout ÷ 4, 5)))
                                                        last = INGEST_WS_LAST_ACTIVITY[]
                                                        if last == 0.0
                                                            continue
                                                        end
                                                        if time() - last >= idle_timeout
                                                            @info "comm_ingest_ws: idle timeout reached, poking listener to restart" idle=idle_timeout
                                                            try
                                                                stop_ingest_ws_server()
                                                            catch err
                                                                _rethrow_if_interrupt(err)
                                                                @warn "comm_ingest_ws: stop failed during idle restart" err=err
                                                            end
                                                            # reset last-activity so we don't repeatedly restart
                                                            INGEST_WS_LAST_ACTIVITY[] = 0.0
                                                            # supervisor loop will restart the listener; continue monitoring
                                                            continue
                                                        end
                                                    end
                                                catch err
                                                    _rethrow_if_interrupt(err)
                                                finally
                                                    INGEST_WS_MONITOR[] = nothing
                                                end
                                            end
                                        end
                                    catch
                                    end
                                    conn = get_registered_connection(k)
                                    if conn !== nothing
                                        @async try
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
                    finally
                        @debug "[comm_ingest_ws] Client disconnected"
                    end
                end
            catch err
                # listener terminated; log and immediately restart
                _rethrow_if_interrupt(err)
                @warn "comm_ingest_ws: listener terminated, restarting" err=err
                # Run a garbage collection to help free socket buffers and
                # other resources before attempting to restart.
                try
                    GC.gc()
                catch gcerr
                    @warn "comm_ingest_ws: GC.gc() failed" err=gcerr
                end
            end
            # brief pause to avoid tight restart loop
            sleep(0.01)
        end
    end

    INGEST_WS_TASK[] = task
    # store host/port and idle settings
    INGEST_WS_HOST[] = host
    INGEST_WS_PORT[] = p
    INGEST_WS_IDLE_SECONDS[] = idle_timeout

    # Start an idle-monitor task if requested
    if idle_timeout > 0 && INGEST_WS_MONITOR[] === nothing
        INGEST_WS_MONITOR[] = @async begin
            try
                while true
                    sleep(max(1, min(idle_timeout ÷ 4, 5)))
                    last = INGEST_WS_LAST_ACTIVITY[]
                    # If we've never received a message, do not restart.
                    if last == 0.0
                        continue
                    end
                    # Restart only when the configured seconds have elapsed
                    # since the last received message.
                    if time() - last >= idle_timeout
                        @info "comm_ingest_ws: idle timeout reached, poking listener to restart" idle=idle_timeout
                        try
                            stop_ingest_ws_server()
                        catch err
                            _rethrow_if_interrupt(err)
                            @warn "comm_ingest_ws: stop failed during idle restart" err=err
                        end
                        # reset last-activity so we don't immediately retrigger
                        INGEST_WS_LAST_ACTIVITY[] = 0.0
                        # supervisor loop will restart the listener; continue monitoring
                        continue
                    end
                end
            catch err
                _rethrow_if_interrupt(err)
            finally
                INGEST_WS_MONITOR[] = nothing
            end
        end
    end

    # Return a named tuple so callers can access `.port` or destructure
    return (port=p, task=task)
end


function stop_ingest_ws_server()
    # Rather than attempting to `throwto` the background task (which can
    # fail if the task already exited), simply poke the listener socket
    # to wake any blocking accept/read. The supervisor loop will detect
    # the listener closure and restart it.
    try
        h = INGEST_WS_HOST[]
        p = INGEST_WS_PORT[]
        if h !== nothing && p !== nothing
            try
                sock = connect(h, p)
                close(sock)
            catch err_conn
                # ignore connection errors — listener may already be closed
            end
        end
    catch err
        _rethrow_if_interrupt(err)
        @warn "stop_ingest_ws_server: wakeup poke failed" err=err
    end

    # Trigger GC to encourage release of resources associated with the
    # previous listener so the supervisor can rebind cleanly.
    try
        GC.gc()
    catch gcerr
        @warn "stop_ingest_ws_server: GC.gc() failed" err=gcerr
    end

    return true
end

