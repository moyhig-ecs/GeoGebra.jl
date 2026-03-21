"""Ingest-only UNIX-domain socket server.

This server reserves a filesystem path (e.g. `/tmp/ggb_<uuid>.sock`) and
listens for frontend connections that will send out-of-band (OOB)
notifications. Incoming messages are forwarded into the kernel-side
`COMM_QUEUES` (via `_enqueue_comm_message`) so the rest of the comm
handling code can process them as if they had arrived via the Jupyter
comm channel.

API:
- `start_ingest_server(path=nothing)` -> `(path, task)` : reserves `path`
  if not provided and starts the background server task; returns the
  socket path and the `Task` that is running the accept loop.
- `stop_ingest_server(path, task)` : stops server and removes socket file.

Notes:
- Uses `Sockets.unixlisten` when available. If not available, throws an
  error; this project targets UNIX-like systems where AF_UNIX is present.
"""

using Sockets
using JSON
using UUIDs
using SHA
using Base64

export start_ingest_server, stop_ingest_server

# Single-channel serialized handler: ensures receive handler runs synchronously
# (processed sequentially by a single worker task) rather than concurrently
# from multiple connection tasks.
const INGEST_HANDLER_CHANNEL = Channel{Tuple{Any,Any}}(1024)
const INGEST_HANDLER_TASK = Ref{Union{Task,Nothing}}(nothing)

function _reserve_socket_path(prefix::AbstractString="/tmp/ggb_")
    # Generate candidate paths and ensure they are actually free by trying
    # to bind a temporary UNIX-domain listener. If bind succeeds we close
    # and remove the temporary listener and accept the path.
    for i in 1:16
        p = string(prefix, replace(string(UUIDs.uuid4()), "-" => ""), ".sock")
        # Skip if a filesystem entry already exists
        if ispath(p)
            continue
        end
        server = nothing
        try
            server = try
                Sockets.listen(p)
            catch
                nothing
            end
            if server !== nothing
                try
                    close(server)
                catch
                end
                # remove the socket file created by the temporary bind
                try
                    if ispath(p)
                        rm(p)
                    end
                catch
                end
                return p
            end
        catch err
            # bind failed; try another candidate
            continue
        finally
            try
                if server !== nothing && isopen(server)
                    close(server)
                end
            catch
            end
        end
    end
    throw(ErrorException("comm_ingest: failed to reserve unique UNIX socket path after multiple attempts"))
end

function start_ingest_server(; path::Union{Nothing,String}=nothing, websocket::Bool=false)
    if path === nothing
        path = _reserve_socket_path()
    end
    # Ensure no stale socket file exists
    try
        if isfile(path)
            rm(path)
        end
    catch err
        @warn "comm_ingest: failed to remove existing socket file" err=err path=path
    end

    # Create a UNIX-domain server using `listen(path)` as in typical examples.
    server = nothing
    err_listen = nothing
    try
        server = try
            Sockets.listen(path)
        catch err
            err_listen = err
            nothing
        end
    catch err
        err_listen = err
    end

    # If binding via Sockets didn't produce a socket file on disk, try UnixSockets.jl
    created = ispath(path)
    if server === nothing || !created
        println("[comm_ingest] Sockets.listen did not create socket file; attempting UnixSockets.listen fallback")
        try
            @eval using UnixSockets
            # close previous server if any
            try
                server !== nothing && isopen(server) && close(server)
            catch
            end
            server = UnixSockets.listen(path)
            created = ispath(path)
        catch err_unix
            # If we already had an earlier error, include both in message
            msg = "comm_ingest: failed to bind UNIX-domain socket at $(path)."
            if err_listen !== nothing
                msg *= " Sockets.listen error: $(err_listen)."
            end
            msg *= " UnixSockets.listen error: $(err_unix)."
            throw(ErrorException(msg))
        end
    end

    if !ispath(path)
        @warn "comm_ingest: socket file not visible at path after listen; behavior may use abstract namespace" path=path
    end

    println("[comm_ingest] listening on: $path")
    # Start (or reuse) the serialized handler worker
    if INGEST_HANDLER_TASK[] === nothing || (INGEST_HANDLER_TASK[] !== nothing && istaskdone(INGEST_HANDLER_TASK[]))
        INGEST_HANDLER_TASK[] = @async begin
            while true
                tup = try
                    take!(INGEST_HANDLER_CHANNEL)
                catch
                    break
                end
                conn, parsed = tup
                try
                    COMM_RECEIVE_HANDLER[](conn, parsed)
                catch err_h
                    @warn "comm_ingest: serialized handler raised" err=err_h
                end
            end
        end
        println("[comm_ingest] started serialized handler task: ", INGEST_HANDLER_TASK[])
    end

    task = @async begin
        try
            while isopen(server)
                client = nothing
                try
                    client = accept(server)
                    println("[comm_ingest] accepted connection")
                catch e
                    if isa(e, EOFError) || isa(e, Base.IOError)
                        break
                    else
                        @warn "comm_ingest: accept failed" err=e
                        continue
                    end
                end
                begin
                    # capture client into a local variable for closure safety
                    c = client
                    try
                        # Read the first lines to detect an HTTP/WebSocket handshake
                        # Accumulate header lines until an empty line (CRLF) is seen.
                        first = true
                        headers = String[]
                        while isopen(c) && !eof(c)
                            line = try
                                readline(c)
                            catch
                                break
                            end
                            # stop header accumulation at empty line
                            if isempty(line)
                                break
                            end
                            push!(headers, line)
                            # For non-handshake simple messages (no HTTP GET), break after first line
                            if first && !(startswith(headers[1], "GET ") || occursin("Upgrade: websocket", lowercase(line)))
                                break
                            end
                            first = false
                        end

                        # If this looks like a WebSocket handshake (HTTP GET + Upgrade), perform handshake
                        is_handshake = false
                        if !isempty(headers)
                            if startswith(headers[1], "GET ") || any(h -> occursin("upgrade: websocket", lowercase(h)), headers)
                                is_handshake = true
                            end
                        end

                        if is_handshake || websocket
                            # parse Sec-WebSocket-Key
                            key = nothing
                            for h in headers
                                parts = split(h, ':', limit=2)
                                if length(parts) == 2
                                    name = lowercase(strip(parts[1])); val = strip(parts[2])
                                    if name == "sec-websocket-key"
                                        key = val
                                        break
                                    end
                                end
                            end
                            if key === nothing
                                @warn "comm_ingest: websocket handshake missing Sec-WebSocket-Key"
                                try close(c) catch end
                                continue
                            end
                            accept_key = Base64.base64encode(sha1(key * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
                            # send handshake response
                            resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept_key\r\n\r\n"
                            try
                                write(c, resp)
                                flush(c)
                            catch err_w
                                @warn "comm_ingest: failed to write websocket handshake response" err=err_w
                                try close(c) catch end
                                continue
                            end

                            # WebSocket frame loop (simple implementation: handle text frames, masked client frames)
                            while isopen(c)
                                # read first two bytes
                                b1 = try read(c, UInt8) catch break end
                                b2 = try read(c, UInt8) catch break end
                                fin = (b1 & 0x80) != 0
                                opcode = b1 & 0x0f
                                masked = (b2 & 0x80) != 0
                                payload_len = Int(b2 & 0x7f)
                                if payload_len == 126
                                    ext = read(c, UInt8, 2)
                                    payload_len = Int(UInt16(ext[1]) << 8 | UInt16(ext[2]))
                                elseif payload_len == 127
                                    ext = read(c, UInt8, 8)
                                    payload_len = 0
                                    for i in 1:8
                                        payload_len = (payload_len << 8) | Int(ext[i])
                                    end
                                end
                                mask_key = UInt8[]
                                if masked
                                    mask_key = read(c, UInt8, 4)
                                end
                                payload = payload_len > 0 ? read(c, UInt8, payload_len) : UInt8[]
                                if masked && payload_len > 0
                                    for i in 1:payload_len
                                        payload[i] = payload[i] ⊻ mask_key[(i-1) % 4 + 1]
                                    end
                                end
                                if opcode == 0x8
                                    # close frame
                                    break
                                elseif opcode == 0x1 || opcode == 0x2 || opcode == 0x0
                                    # text (1) / binary (2) / continuation (0)
                                    msg = try String(payload) catch
                                        String(copy(payload))
                                    end
                                    if isempty(msg)
                                        continue
                                    end
                                    println("[comm_ingest] ws received: ", msg)
                                    parsed = try JSON.parse(msg) catch msg end

                                    # route as before
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
                                            @warn "comm_ingest: no registered comms to route message to"
                                            continue
                                        end
                                        k = ks[1]
                                    end
                                    s = try isa(parsed, AbstractString) ? parsed : JSON.json(parsed) catch; string(parsed) end
                                    _enqueue_comm_message(k, s)
                                    conn = get_registered_connection(k)
                                    if conn !== nothing
                                        try put!(INGEST_HANDLER_CHANNEL, (conn, parsed)) catch err_inner @warn "comm_ingest: failed to enqueue serialized handler" err=err_inner end
                                    end
                                else
                                    # ignore other opcodes (ping/pong handled lightly)
                                end
                            end
                        else
                            # Non-websocket simple single-line messages: process the already-read first line
                            if !isempty(headers)
                                line = headers[1]
                                println("[comm_ingest] received raw: ", line)
                                parsed = try JSON.parse(line) catch line end
                                println("[comm_ingest] parsed: ", isa(parsed, AbstractString) ? parsed : JSON.json(parsed))
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
                                        @warn "comm_ingest: no registered comms to route message to"
                                    else
                                        k = ks[1]
                                        s = try isa(parsed, AbstractString) ? parsed : JSON.json(parsed) catch; string(parsed) end
                                        println("[comm_ingest] enqueue -> key=", k)
                                        _enqueue_comm_message(k, s)
                                        conn = get_registered_connection(k)
                                        if conn === nothing
                                            println("[comm_ingest] no registered connection for key=", k)
                                        else
                                            try
                                                println("[comm_ingest] enqueue handler -> key=", k)
                                                put!(INGEST_HANDLER_CHANNEL, (conn, parsed))
                                            catch err_inner
                                                @warn "comm_ingest: failed to enqueue serialized handler" err=err_inner
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    catch err_client
                        @warn "comm_ingest: client handler failed" err=err_client
                    finally
                        try
                            if c !== nothing && isopen(c)
                                close(c)
                            end
                        catch
                        end
                    end
                end
            end
        catch err
            @warn "comm_ingest: accept loop terminated" err=err
        finally
            try close(server) catch end
            try ispath(path) && rm(path) catch end
        end
    end

    return (path, task)
end

function stop_ingest_server(path::String, t::Task)
    try
        # Cancel background task; it will close server in its finally block
        schedule(t, () -> nothing)
        # Best-effort cancel
        Base.throwto(t, InterruptException())
        # Also cancel serialized handler task if present
        try
            if INGEST_HANDLER_TASK[] !== nothing
                Base.throwto(INGEST_HANDLER_TASK[] , InterruptException())
                INGEST_HANDLER_TASK[] = nothing
            end
        catch err_h
            @warn "comm_ingest: failed to cancel handler task" err=err_h
        end
    catch err
        @warn "comm_ingest: failed to cancel task" err=err
    end
    # Remove socket file if present
    try
        if isfile(path)
            rm(path)
        end
    catch err
        @warn "comm_ingest: failed to remove socket file" err=err path=path
    end
    return nothing
end
