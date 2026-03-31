"""WebSocket ingest server (TCP).

Starts a TCP WebSocket server bound to localhost on a given port (default
8081) and forwards incoming text messages (JSON) into the kernel comm
queues via `_enqueue_comm_message` and `INGEST_HANDLER_CHANNEL`.

This file provides `start_ingest_ws_server(; port=nothing)` which returns
`(port, task)` where `task` is the background Task running the server.
"""

using Sockets
using HTTP
using HTTP.WebSockets
using JSON
using Logging

# NOTE: interrupt rethrow helper was removed — interrupts will not be rethrown here.

# Keep a reference to the background Task so it isn't garbage-collected.
# Keep listener host/port so `stop_ingest_ws_server()` can poke the
# listener to ensure it wakes up and exits.
const INGEST_WS_HOST = Ref{Union{Nothing,String}}(nothing)
const INGEST_WS_PORT = Ref{Union{Nothing,Int}}(nothing)
# Last activity timestamp and idle-monitor task
# `INGEST_WS_LAST_ACTIVITY` is 0.0 when no message has yet been received.
const INGEST_WS_LAST_ACTIVITY = Ref{Float64}(0.0)
const INGEST_WS_IDLE_SECONDS = Ref{Float64}(3.0)
const INGEST_WS_MONITOR = Ref{Union{Task,Nothing}}(nothing)
# Periodic maintenance restart interval (seconds). 0 disables periodic restarts.
const INGEST_WS_PERIODIC_SECONDS = Ref{Float64}(180.0)
const INGEST_WS_PERIODIC_MONITOR = Ref{Union{Task,Nothing}}(nothing)

function start_ingest_ws_server(; given_port::Union{Nothing,UInt16}=nothing)
    # assume HTTP and HTTP.WebSockets are available (using above)

    host = "127.0.0.1"
    port::UInt16 = 0
    if given_port === nothing
        # find an ephemeral (free) port by binding to port 0 and then closing
        function _find_free_port()::UInt16
            srv = nothing
            try
                srv = Sockets.listen(0)
                addr = Sockets.getsockname(srv)
                return UInt16(addr[2])
            catch err
                @warn "start_ingest_ws_server: failed to find free port, defaulting to 8081" err=err
                return UInt16(8081)
            finally
                try
                    if srv !== nothing && isopen(srv)
                        close(srv)
                    end
                catch err
                    @warn "start_ingest_ws_server: failed to close temporary socket" err=err
                end
            end
        end

        port = _find_free_port()
        @debug "start_ingest_ws_server: auto-selected free port $port" host=host
    else
        port = UInt16(given_port)
    end
    @debug "start_ingest_ws_server: starting WebSocket server on port $port" host=host
    
    # Supervisor task: keep restarting the listener so service is
    # continuous. When the listener exits (e.g. due to socket close),
    # the loop will start a fresh listener immediately.
    task = @async begin
        let lp = port
            while true
                try
                    @debug "[comm_ingest_ws] Starting WebSocket server" host=host port=lp
                    HTTP.WebSockets.listen(host, lp) do ws
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
                                                        last = INGEST_WS_LAST_ACTIVITY[]
                                                        if last == 0.0
                                                            sleep(0.1)
                                                            continue
                                                        end
                                                        deadline = last + float(idle_timeout)
                                                        wait = deadline - time()
                                                        if wait > 0
                                                            sleep(min(wait, 1.0))
                                                            continue
                                                        end
                                                        @info "comm_ingest_ws: idle timeout reached, poking listener to restart" idle=idle_timeout
                                                        try
                                                            stop_ingest_ws_server()
                                                        catch err
                                                            @warn "comm_ingest_ws: stop failed during idle restart" err=err
                                                        end
                                                        # reset last-activity so we don't repeatedly restart
                                                        INGEST_WS_LAST_ACTIVITY[] = 0.0
                                                        # supervisor loop will restart the listener; continue monitoring
                                                        continue
                                                    end
                                                catch err
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
                                            @warn "comm_ingest_ws: INGEST_HANDLER_CHANNEL put failed" err=err_put
                                        end
                                    end
                                catch err
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
                @warn "comm_ingest_ws: listener terminated" err=err
                # GC call removed here (not required)
            end
                # brief pause to avoid tight restart loop
                sleep(0.01)
            end
        end
    end

    
    # store host/port
    INGEST_WS_HOST[] = host
    INGEST_WS_PORT[] = port

    # Start a periodic maintenance monitor if requested. This performs
    # a periodic restart+GC (useful to mitigate HTTP.WebSockets stateful
    # deadlocks) in addition to the per-receive idle restart.
    if INGEST_WS_PERIODIC_SECONDS[] > 0 && INGEST_WS_PERIODIC_MONITOR[] === nothing
        INGEST_WS_PERIODIC_MONITOR[] = @async begin
            try
                while true
                    sleep(INGEST_WS_PERIODIC_SECONDS[])
                    @info "comm_ingest_ws: periodic restart due; poking listener to restart" interval=INGEST_WS_PERIODIC_SECONDS[]
                    try
                        stop_ingest_ws_server()
                    catch err
                        @warn "comm_ingest_ws: periodic stop failed" err=err
                    end
                    # continue loop
                    continue
                end
            catch err
            finally
                INGEST_WS_PERIODIC_MONITOR[] = nothing
            end
        end
    end

    # Return a named tuple so callers can access `.port` or destructure
    return (port=port, task=task)
end


function stop_ingest_ws_server()
    # Rather than attempting to `throwto` the background task (which can
    # fail if the task already exited), simply poke the listener socket
    # to wake any blocking accept/read. The supervisor loop will detect
    # the listener closure and restart it.
    try
        @debug "stop_ingest_ws_server: poking listener to wake (host,port)" host=INGEST_WS_HOST[] port=INGEST_WS_PORT[]
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
        @warn "stop_ingest_ws_server: wakeup poke failed" err=err
    end

    # Trigger GC to encourage release of resources associated with the
    # previous listener so the supervisor can rebind cleanly.
    try
        # NOTE: HTTP.WebSockets (as of Julia 1.12.5) can deadlock without
        # periodic re-initialization. We call GC.gc() as a mitigation and
        # emit a warning to make this behavior visible to operators.
        @debug "stop_ingest_ws_server: running GC; HTTP.WebSockets may require periodic reinitialization"
        GC.gc()
    catch gcerr
        @warn "stop_ingest_ws_server: GC.gc() failed" err=gcerr
    end

    return true
end

