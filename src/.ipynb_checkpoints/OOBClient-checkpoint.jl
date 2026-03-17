module OOBClient

try
    using Sockets
    using Observables
    using JSON
catch e
    @error "Sockets, Observables.jl and JSON.jl are required. Install with `import Pkg; Pkg.add([\"Observables\", \"JSON\"])`"
    rethrow(e)
end

# Observable carrying the latest message; users can subscribe handlers.
# Use an Any-typed Observable so it can hold snapshots, updates, errors, etc.
const messages = Observable{Any}(nothing)

# Per-label observables: map label string -> Observable holding latest value
const label_observables = Dict{String, Observable{Any}}()
# Track per-label unsubscribers (functions returned by `on`) so we can
# remove callbacks when requested.
const label_unsubscribers = Dict{String, Vector{Function}}()

function get_label_observable(label::AbstractString)
    key = string(label)
    if !haskey(label_observables, key)
        label_observables[key] = Observable{Any}(nothing)
    end
    return label_observables[key]
end

function add_label_handler(label::AbstractString, fn::Function)
    obs = get_label_observable(label)
    unsub = on(obs) do v
        try
            fn(v)
        catch e
            @error "Label handler error for $(label): $e"
        end
    end
    key = string(label)
    if !haskey(label_unsubscribers, key)
        label_unsubscribers[key] = Vector{Function}()
    end
    push!(label_unsubscribers[key], unsub)
    return unsub
end

# Backwards-compatible wrapper: allow calling add_label_handler(fn, label)
function add_label_handler(fn::Function, label::AbstractString)
    return add_label_handler(label, fn)
end

function remove_label_observable(label::AbstractString)
    key = string(label)
    if haskey(label_unsubscribers, key)
        for u in label_unsubscribers[key]
            try
                u()
            catch
            end
        end
        delete!(label_unsubscribers, key)
    end
    if haskey(label_observables, key)
        delete!(label_observables, key)
    end
    return nothing
end

function remove_label_handler(label::AbstractString, unsub::Function)
    # Call the unsubscribe function and remove it from our registry
    key = string(label)
    try
        unsub()
    catch
    end
    if haskey(label_unsubscribers, key)
        filter!(x -> x !== unsub, label_unsubscribers[key])
        if isempty(label_unsubscribers[key])
            delete!(label_unsubscribers, key)
        end
    end
    return nothing
end

function list_label_observables()
    return collect(keys(label_observables))
end

function _dispatch_label_updates(parsed)
    if parsed isa AbstractDict
        payload = get(parsed, "payload", nothing)
        if payload isa AbstractDict
            for (k,v) in payload
                try
                    obs = get_label_observable(string(k))
                    obs[] = v
                catch e
                    @warn "Failed to dispatch label update for $(k): $e"
                end
            end
        end
    end
    return
end

# Parse ARGS into host, port. Accept --port=, --port N, --host=, host:port, or bare port.
function parse_args()
    host = "127.0.0.1"
    port = nothing
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if startswith(a, "--port=")
            try
                port = parse(Int, split(a, '=', limit=2)[2])
            catch
            end
        elseif a == "--port" && i < length(ARGS)
            try
                port = parse(Int, ARGS[i+1])
            catch
            end
            i += 1
        elseif startswith(a, "--host=")
            host = split(a, '=', limit=2)[2]
        elseif a == "--host" && i < length(ARGS)
            host = ARGS[i+1]
            i += 1
        elseif occursin(':', a)
            parts = split(a, ':')
            host = parts[1]
            try
                port = parse(Int, parts[2])
            catch
            end
        else
            try
                port = parse(Int, a)
            catch
                host = a
            end
        end
        i += 1
    end
    if port === nothing
        envp = get(ENV, "GGB_WS_PORT", nothing)
        if envp !== nothing
            port = parse(Int, envp)
        else
            port = 8765
        end
    end
    return host, port
end

function _run_tcp_client(host::AbstractString, port::Integer, messages::Observable, stop_ref::Base.RefValue{Bool})
    while !stop_ref[]
        try
            sock = connect(host, port)
            # record current socket so callers can close it to interrupt blocking IO
            try
                global current_socket
            catch
                const current_socket = Ref{Any}(nothing)
            end
            current_socket[] = sock
            io = sock
            try
                # request shared snapshot on connect
                try
                    req = Dict("op" => "get_shared_snapshot")
                    write(io, JSON.json(req))
                    write(io, '\n')
                    flush(io)
                catch e
                    @warn "Failed to request snapshot: $e"
                end

                local_seq = 0
                local_objs = Dict{Any,Any}()

                while !stop_ref[]
                    # readline may block; stop_ref + throwto used to interrupt
                    line = readline(io)
                    if line === nothing
                        break
                    end
                    text = String(line)
                    parsed = try
                        JSON.parse(text)
                    catch
                        text
                    end

                    # handle snapshot / updates
                    try
                        if isa(parsed, Dict) && get(parsed, "type", nothing) == "shared_objects_snapshot"
                                local_seq = get(parsed, "seq", 0)
                                local_objs = get(parsed, "payload", Dict())
                                messages[] = parsed
                                _dispatch_label_updates(parsed)
                                continue
                            elseif isa(parsed, Dict) && get(parsed, "type", nothing) == "shared_objects_update"
                                seq = get(parsed, "seq", 0)
                                payload = get(parsed, "payload", Dict())
                                if seq > local_seq
                                    for (k,v) in payload
                                        local_objs[k] = v
                                    end
                                    local_seq = seq
                                    messages[] = parsed
                                    _dispatch_label_updates(parsed)
                                    continue
                                else
                                    continue
                                end
                            end
                    catch e
                        @warn "Error processing shared_objects message: $e"
                    end

                    messages[] = parsed
                    _dispatch_label_updates(parsed)
                end
            catch e
                # InterruptException is expected when shutting down via stop_oob_client;
                # treat it as graceful and avoid noisy error logging.
                if e isa InterruptException
                    # Break out to allow outer loop to notice stop_ref[] and exit.
                    current_socket[] = nothing
                    break
                else
                    @error "Error while reading from socket: $e"
                    messages[] = e
                end
            finally
                try
                    try
                        close(sock)
                    catch
                    end
                    current_socket[] = nothing
                catch
                end
            end
        catch e
            @error "Connection failed to $host:$port — $e"
            messages[] = e
            sleep(0.5)
        end
    end
end

# Start client in a background Task so handlers can be registered.
function start_oob_client(host::AbstractString, port::Integer)
    println("Starting OOB client to $host:$port...")
    stop_ref = Ref(false)
    t = @async _run_tcp_client(host, port, messages, stop_ref)
    return t, stop_ref
end

function stop_oob_client(t::Task, stop_ref::Base.RefValue{Bool})
    # Request graceful stop and interrupt blocking IO to wake the task.
    stop_ref[] = true
    # Close any active socket to interrupt blocking reads/connect.
    try
        global current_socket
        if !isnothing(current_socket[]) && current_socket[] !== nothing
            try
                close(current_socket[])
            catch
            end
        end
    catch
    end

    try
        Base.throwto(t, InterruptException())
    catch
    end
    try
        wait(t)
    catch
    end
end

# Convenience helper to register handlers
function add_handler(fn::Function)
    on(messages) do msg
        try
            fn(msg)
        catch e
            @error "Handler error: $e"
        end
    end
end

export messages, add_handler, start_oob_client, stop_oob_client, parse_args,
       get_label_observable, add_label_handler, remove_label_observable, list_label_observables,
       remove_label_handler

end # module OOBClient
