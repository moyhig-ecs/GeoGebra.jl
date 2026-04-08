"""Macro implementations for GeoGebra.jl

This file contains the `@ggblab` family of macros extracted from the
main module file to keep macro logic separate and maintainable.
"""

"""Handle `@ggblab api fn(args...)` macro branch.

This internal macro is extracted to handle the API-style invocation:
`@ggblab api fn(args...)`. It constructs a runtime call that evaluates
arguments in the caller's scope and dispatches to `GeoGebra.send_function_eval`.
"""
# Macro implementing the `@ggblab` command-style behavior.
"""Send a GeoGebra command expression at runtime.

`@ggblab_command` is a helper macro used by `@ggblab` to transform an
expression such as `Circle(A, 1)` into a string command and send it
to the bridge at runtime. Symbol arguments that evaluate to `GGBObject`
instances are replaced with their `label` before sending. The macro
ensures evaluation happens in the caller's scope and returns the
processed response (calling `process_labels_response` as needed).
"""
macro ggblab_function(inner)
    if inner isa Expr && inner.head == :call
        name = inner.args[1]
        arg_nodes = inner.args[2:end]
        # Build a tuple of escaped argument expressions so they evaluate in
        # the caller's scope. `send_function_eval` will normalize the tuple
        # into an array when constructing the JSON payload.
        esc_args = Expr[]
        for a in arg_nodes
            push!(esc_args, esc(a))
        end
        args_tuple = Expr(:tuple, esc_args...)
        call_expr = Expr(:call, Expr(:call, :getfield, :(GeoGebra), QuoteNode(:send_function_eval)), QuoteNode(name), args_tuple)
        return esc(call_expr)
    else
        error("@ggblab api usage must be like `@ggblab api fn(args...)`")
    end
end

"""Primary user-facing macro to send commands or API calls.

Usage:
- `@ggblab Circle(0, 0, 1)` sends a command string to the bridge.
- `@ggblab api getVersion()` sends a function-style payload to the bridge.

The macro handles leading expansion tokens (LineNumberNode/Module), routes
API invocations to `@ggblab_function`, and routes command-style expressions
to `@ggblab_command`. The generated runtime calls evaluate arguments in
the caller scope so `x = @ggblab Circle(A, 1)` will assign the returned
value.
"""

macro isdefined_in_module(mod, sym)
    return :(isdefined($(esc(mod)), $(QuoteNode(sym))))
end

macro ggblab_command(expr)
    # Two modes:
    # - call-expr (e.g., Circle(A,1)): evaluate args at runtime so tokens
    #   `_`, `__`, `_n` are expanded and GGBObject args are converted to labels.
    # - other-expr (e.g., assignment `O = (0,0)`): fall back to string
    #   construction at macro-expansion time (original behavior).
    if expr isa Expr && expr.head == :call
        name = expr.args[1]
        arg_nodes = expr.args[2:end]

        # Normalize command name when callers use a quoted symbol like `:l3`
        nm = name
        if nm isa QuoteNode && isa(nm.value, Symbol)
            nm = nm.value
        end

        mapped_args = Any[]
        for a in arg_nodes
            if a isa Symbol
                s = string(a)
                if s == "_"
                    push!(mapped_args, :(GeoGebra.construction_protocol()[end]))
                    continue
                elseif s == "__"
                    push!(mapped_args, :(GeoGebra.construction_protocol()[end-1]))
                    continue
                elseif startswith(s, "_") && length(s) > 1
                    numstr = s[2:end]
                    if all(isdigit, collect(numstr))
                        idx = parse(Int, numstr)
                        push!(mapped_args, Expr(:ref, :(GeoGebra.construction_protocol()), idx))
                        continue
                    end
                end
            end
            push!(mapped_args, a)
        end

        esc_args = Any[]
        for a in mapped_args
            push!(esc_args, esc(a))
        end
        args_tuple = Expr(:tuple, esc_args...)

        # If the command name is an operator (:+, :-, :*, :/, :^, etc.),
        # construct an infix command string like "a + b" and send it
        # via `send_command`. Otherwise fall back to the existing
        # `send_command_eval` behavior.
        op_str = nothing
        if nm isa Symbol
            s_nm = string(nm)
            if occursin(r"^[+\-*/^%<>=!&|]+$", s_nm)
                op_str = s_nm
            end
        elseif nm isa QuoteNode && isa(nm.value, Symbol)
            s_nm = string(nm.value)
            if occursin(r"^[+\-*/^%<>=!&|]+$", s_nm)
                op_str = s_nm
            end
        end

        if op_str !== nothing
            tmp_args = gensym("_ggb_args")
            body = :(let $(tmp_args) = $(args_tuple)
                        _argvals = $(tmp_args)
                        _argstrs = String[]
                        for _v in _argvals
                            if isa(_v, GGBObject)
                                push!(_argstrs, _v.label)
                            else
                                push!(_argstrs, string(_v))
                            end
                        end
                        _cmd = join(_argstrs, " " * $(QuoteNode(op_str)) * " ")
                        _res = GeoGebra.process_labels_response(GeoGebra.send_command(_cmd))
                        try
                            GeoGebra._push_construction_result!(_res)
                        catch
                        end
                        _res
                     end)
            return esc(body)
        end

        call_expr = Expr(:call, Expr(:call, :getfield, :(GeoGebra), QuoteNode(:send_command_eval)), QuoteNode(nm), args_tuple)

        return esc(:(let _res = $(call_expr)
                        _proc = GeoGebra.process_labels_response(_res)
                        try
                            GeoGebra._push_construction_result!(_proc)
                        catch
                        end
                        _proc
                     end))
    else
        # Fallback: reproduce original static walk -> command string behavior
        # Special-case assignment forms like `:m = expr` where the left
        # side is a quoted label or symbol. Attempt to convert the RHS
        # via `sympy_to_ggb` at runtime and, if successful, send a
        # GeoGebra assignment using the converted string.
        if expr isa Expr && expr.head == :(=) && length(expr.args) >= 2
            left = expr.args[1]
            right = expr.args[2]
            lbl = nothing
            if left isa QuoteNode
                if isa(left.value, Symbol)
                    lbl = string(left.value)
                elseif isa(left.value, String)
                    lbl = left.value
                end
            elseif left isa Symbol
                lbl = string(left)
            end
            if lbl !== nothing
                # If RHS is a bare symbol, evaluate it in caller scope and
                # attempt sympy conversion. If RHS is a call-expr (e.g.
                # `:l3(_)`) evaluate the arguments at runtime, build the
                # command string with evaluated argument labels/strings,
                # and send the assignment command to the bridge.
                if right isa Expr && right.head == :call && length(right.args) >= 1
                    call_name = right.args[1]
                    # normalize quoted command name
                    nm = call_name
                    if nm isa QuoteNode && isa(nm.value, Symbol)
                        nm = nm.value
                    end
                    name_str = string(nm)
                    # detect operator-like command names so we can format
                    # assignments using infix notation (e.g. `c = a + b`).
                    op_name = nothing
                    if isa(nm, Symbol)
                        s_nm2 = string(nm)
                        if occursin(r"^[+\-*/^%<>=!&|]+$", s_nm2)
                            op_name = s_nm2
                        end
                    elseif isa(nm, QuoteNode) && isa(nm.value, Symbol)
                        s_nm2 = string(nm.value)
                        if occursin(r"^[+\-*/^%<>=!&|]+$", s_nm2)
                            op_name = s_nm2
                        end
                    end
                    # Flatten nested same-operator calls, e.g. +(+(a,b),c) -> [a,b,c]
                    op_sym_val = (nm isa Symbol) ? nm : (nm isa QuoteNode && isa(nm.value, Symbol) ? nm.value : nothing)
                    function _flatten_ops_local(ex)
                        out = Any[]
                        if ex isa Expr && ex.head == :call && op_sym_val !== nothing
                            head = ex.args[1]
                            head_sym = (head isa QuoteNode && isa(head.value, Symbol)) ? head.value : head
                            if head_sym == op_sym_val
                                for ch in ex.args[2:end]
                                    append!(out, _flatten_ops_local(ch))
                                end
                                return out
                            end
                        end
                        push!(out, ex)
                        return out
                    end
                    arg_nodes = _flatten_ops_local(right)
                    mapped_args = Any[]
                    for a in arg_nodes
                        if a isa Symbol
                            s = string(a)
                            if s == "_"
                                push!(mapped_args, :(GeoGebra.construction_protocol()[end]))
                                continue
                            elseif s == "__"
                                push!(mapped_args, :(GeoGebra.construction_protocol()[end-1]))
                                continue
                            elseif startswith(s, "_") && length(s) > 1
                                numstr = s[2:end]
                                if all(isdigit, collect(numstr))
                                    idx = parse(Int, numstr)
                                    push!(mapped_args, Expr(:ref, :(GeoGebra.construction_protocol()), idx))
                                    continue
                                end
                            end
                        end
                        push!(mapped_args, a)
                    end
                    esc_args = Expr[]
                    for a in mapped_args
                        push!(esc_args, esc(a))
                    end
                    args_tuple = Expr(:tuple, esc_args...)
                    tmp_args = gensym("_ggb_args")
                    body = :(let $(tmp_args) = $(args_tuple)
                                _argvals = $(tmp_args)
                                _argstrs = String[]
                                for _v in _argvals
                                    if isa(_v, GGBObject)
                                        push!(_argstrs, _v.label)
                                    else
                                        push!(_argstrs, string(_v))
                                    end
                                end
                                # If we detected an operator name at macro-expansion time,
                                # format as infix joining all operands (e.g. "d = a + b + c").
                                if $(QuoteNode(op_name)) !== nothing && length(_argstrs) >= 2
                                    _cmd = $(QuoteNode(string(lbl * " = " ))) * join(_argstrs, " " * $(QuoteNode(op_name)) * " ")
                                else
                                    _cmd = $(QuoteNode(string(lbl * " = "))) * $(QuoteNode(name_str)) * "(" * join(_argstrs, ", ") * ")"
                                end
                                _res = GeoGebra.process_labels_response(GeoGebra.send_command(_cmd))
                                try
                                    GeoGebra._push_construction_result!(_res)
                                catch
                                end
                                _res
                             end)
                    return esc(body)
                end

                if right isa Symbol || right isa QuoteNode
                    tmp_sym = gensym("_ggb")
                    q = QuoteNode(isa(right, Symbol) ? Symbol(right) : (isa(right, QuoteNode) && isa(right.value, Symbol) ? right.value : right))
                    body = :(let $(tmp_sym) = Core.eval($(QuoteNode(__module__)), $(q))
                                _conv = try GeoGebra.sympy_to_ggb($(tmp_sym)) catch; nothing end
                                if isa(_conv, String)
                                    _res = GeoGebra.process_labels_response(GeoGebra.send_command($(QuoteNode(lbl)) * " = " * _conv))
                                else
                                    _res = GeoGebra.process_labels_response(GeoGebra.send_command($(QuoteNode(lbl)) * " = " * string($(tmp_sym))))
                                end
                                try
                                    GeoGebra._push_construction_result!(_res)
                                catch
                                end
                                _res
                             end)
                    return esc(body)
                else
                    # Static stringify the RHS expression (convert Symbols/QuoteNode to plain labels)
                    cmd_str = expr_to_cmd_string(right)
                    return esc(:(let _cmd = $(QuoteNode(string(lbl * " = " * cmd_str)))
                                    _res = GeoGebra.process_labels_response(GeoGebra.send_command(_cmd))
                                    try
                                        GeoGebra._push_construction_result!(_res)
                                    catch
                                    end
                                    _res
                                 end))
                end
            end
        end
        # BUT: if the expression is an index/array-literal/quoted-index that
        # is intended as a construction lookup (e.g. `@ggb[1]`, `@ggb["O"]`),
        # handle those forms here to avoid sending them as commands.
        if expr isa Expr && (expr.head == :ref || expr.head == :vect)
            # Delegate to the macro-level handling by constructing an Expr
            # that queries the protocol at runtime.
            if expr.head == :vect && length(expr.args) == 1
                lbl = expr.args[1]
                lblstr = isa(lbl, QuoteNode) && isa(lbl.value, String) ? lbl.value : (isa(lbl, Symbol) ? string(lbl) : nothing)
                if lblstr !== nothing
                    return esc(:(GeoGebra.get_construction_object($(QuoteNode(lblstr)))))
                end
            elseif expr.head == :ref
                args_ref = expr.args
                if length(args_ref) == 0
                    return esc(:(GeoGebra.construction_protocol()))
                elseif length(args_ref) == 1
                    idx_node = args_ref[1]
                    lbl = isa(idx_node, QuoteNode) && isa(idx_node.value, String) ? idx_node.value : (isa(idx_node, Symbol) ? string(idx_node) : nothing)
                    if lbl !== nothing
                        return esc(:(GeoGebra.get_construction_object($(QuoteNode(lbl)))))
                    else
                        # non-label single-ref form: fall through to command fallback
                    end
                elseif length(args_ref) == 2
                    # form like construction[idx]
                    idx_node = args_ref[2]
                    lbl = isa(idx_node, QuoteNode) && isa(idx_node.value, String) ? idx_node.value : (isa(idx_node, Symbol) ? string(idx_node) : nothing)
                    if lbl !== nothing
                        return esc(:(GeoGebra.get_construction_object($(QuoteNode(lbl)))))
                    else
                        # non-label two-arg ref: fall through to command fallback
                    end
                end
            end
        end
        # Also handle QuoteNode forms like QuoteNode("[1]") which can appear
        # in macroexpand output; treat strings of the form "[n]" or "[\"O\"]".
        if expr isa QuoteNode && isa(expr.value, String)
            s = expr.value
            mnum = match(r"^\[(\-?\d+)\]$", s)
            if mnum !== nothing
                idx = parse(Int, mnum.captures[1])
                return esc(:(let ch = GeoGebra.construction_protocol()
                                if idx == 0
                                    throw(BoundsError("index 0 invalid"))
                                elseif idx > 0
                                    ch[$(idx)]
                                else
                                    ch[end + $(idx) + 1]
                                end
                             end))
            end
            mstr = match(r"^\[\"(.+)\"\]$", s)
            if mstr !== nothing
                lbl = mstr.captures[1]
                    return esc(:(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end))
            end
        end
        function walk(ex, depth=0)
            block = nothing
            indent = repeat(" ", depth)
            if ex isa Expr
                block = Expr(ex.head)
                for arg in ex.args
                    push!(block.args, walk(arg, depth + 1))
                end
                return block
            elseif ex isa Symbol
                if isdefined(__module__, Symbol(ex))
                    v = getfield(__module__, Symbol(ex))
                    return isa(v, GGBObject) ? Symbol(v.label) : ex
                else
                    return ex
                end
            elseif ex isa QuoteNode
                return ex.value
            else
                return ex
            end
        end
        cmd_str = string(walk(expr))
        return esc(:(let _cmd = $(QuoteNode(cmd_str))
                        _res = GeoGebra.process_labels_response(GeoGebra.send_command(_cmd))
                        try
                            GeoGebra._push_construction_result!(_res)
                        catch
                        end
                        _res
                     end))
    end
end

macro ggblab(args...)
    toks = args
    
    # Helper: normalize a token to String when possible (Symbol, QuoteNode(:sym), or String)
    function _tok_to_str(tok)
        if isa(tok, QuoteNode) && isa(tok.value, Symbol)
            return string(tok.value)
        elseif isa(tok, Symbol)
            return string(tok)
        elseif isa(tok, String)
            return tok
        else
            return nothing
        end
    end
    # If the macro was expanded with a leading LineNumberNode, the layout is
    # typically: (LineNumberNode, Module, expr...). Drop the first two in that case.
    if length(toks) >= 2 && toks[1] isa LineNumberNode
        toks = toks[3:end]
    elseif length(toks) >= 1 && toks[1] isa Module
        # Some callsites include just the Module as the first token; drop it.
        toks = toks[2:end]
    end

    # Special-case: handle call-form label lookup like `@ggblab :const(:O)`
    # Treat `:const(:O)` as a label lookup (equivalent to @ggb["O"]) so that
    # bracket-based indexing remains dedicated to slice/index forms.
    if length(toks) >= 2
        f = toks[1]
        s = toks[2]
        # Get a safe string representation for the first token (f).
        fstr = _tok_to_str(f)
        if fstr === nothing
            try
                fstr = string(f)
            catch
                fstr = ""
            end
        end
        # Consider it a `construction` shorthand if the token text contains "cons".
        if !isempty(fstr) && occursin("cons", lowercase(fstr)) && s isa Expr && s.head == :call && length(s.args) >= 1
            arg = s.args[1]
            lbl = _tok_to_str(arg)
            if lbl === nothing
                try
                    lbl = string(arg)
                catch
                    lbl = nothing
                end
            end
                if lbl !== nothing
                return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
            end
        end
    end
    if length(toks) == 1
        ex = toks[1]
        # If macro invoked as a single bare symbol like `@ggb m`, evaluate
        # the variable at runtime and attempt to convert via
        # `sympy_to_ggb`. If conversion yields a string, send an
        # assignment `m = {{...}}` to GeoGebra; otherwise send the
        # stringified value.
        if ex isa Symbol
            lbl = string(ex)
            tmp_sym = gensym("_ggb")
            # Fetch caller-module global named `ex` (works for REPL/global variables)
            body = :(let $(tmp_sym) = Core.eval($(QuoteNode(__module__)), $(QuoteNode(Symbol(ex))))
                        _conv = try GeoGebra.sympy_to_ggb($(tmp_sym)) catch; nothing end
                        if isa(_conv, String)
                            _res = GeoGebra.process_labels_response(GeoGebra.send_command($(QuoteNode(lbl)) * " = " * _conv))
                        else
                            _res = GeoGebra.process_labels_response(GeoGebra.send_command(string($(tmp_sym))))
                        end
                        try
                            GeoGebra._push_construction_result!(_res)
                        catch
                        end
                        _res
                     end)
            return esc(body)
        end
        # Handle call-form provided as a single token: e.g. `@ggb :const(:O)`
        if ex isa Expr && ex.head == :call && length(ex.args) >= 2
            fn = ex.args[1]
            fnstr = _tok_to_str(fn)
            if fnstr === nothing
                try
                    fnstr = string(fn)
                catch
                    fnstr = nothing
                end
            end
            if fnstr !== nothing && startswith(fnstr, "cons")
                # extract inner arg which may be Symbol, QuoteNode, or Expr
                arg = ex.args[2]
                if arg isa Expr && length(arg.args) >= 1
                    cand = arg.args[1]
                else
                    cand = arg
                end
                lbl = _tok_to_str(cand)
                if lbl === nothing
                    try
                        lbl = string(cand)
                    catch
                        lbl = nothing
                    end
                end
                if lbl !== nothing && lbl != ":" && lbl != "end"
                    return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
                end
            end
        end
        # Early-handle common indexed/quoted forms so they are treated as
        # construction lookups instead of falling through to command send.
        # numeric indexing intentionally unsupported here; fall through
        if ex isa QuoteNode && isa(ex.value, String)
            s = ex.value
            # Only support string label forms like ["O"] here
            mstr = match(r"^\s*\[\s*\"(.+)\"\s*\]\s*$", s)
                if mstr !== nothing
                lbl = mstr.captures[1]
                return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
            end
        end
        if ex isa Expr && ex.head == :vect && length(ex.args) == 1
            # single-element vector literal: treat as label lookup when possible
            lbl = _tok_to_str(ex.args[1])
            if lbl !== nothing
                return esc(:(begin ch = GeoGebra.construction_protocol(); lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]; isempty(lbls) ? lbls : lbls[end] end))
            end
        end
    end
    # Support special construction inspection syntax:
    # - `@ggblab construction` -> returns the full construction history
    # - `@ggblab construction[n]` -> returns the nth entry from history
    if length(toks) >= 1
        first = toks[1]
        is_cons_str = s -> (isa(s, String) && length(s) >= 4 && startswith(s, "cons"))
        # Shortcut commands under the `:const` namespace, e.g.:
        # - `@ggb :const :new`  -> start a new construction (clears history)
        # - `@ggb :const :undo` -> undo last construction entry (returns nothing)
        fstr_top = _tok_to_str(first)
        if fstr_top !== nothing && is_cons_str(fstr_top) && length(toks) >= 2
            snd = toks[2]
            sndstr = _tok_to_str(snd)
            if sndstr === "new"
                # Call the module function which itself invokes the bridge API.
                return esc(:(GeoGebra.new_construction!()))
            elseif sndstr === "undo"
                return esc(:(let ch = GeoGebra.construction_protocol(); if !isempty(ch)
                                    g = pop!(ch)
                                    try
                                        GeoGebra.send_function("deleteObject", g.label)
                                    catch
                                    end
                                end; nothing end))
            end
        end
        # Support `@ggb :listen :O` shorthand: send a listen request and
        # return the object's observable for downstream consumers.
        if fstr_top !== nothing && lowercase(fstr_top) == "listen" && length(toks) >= 2
            snd = toks[2]
            lbl = _tok_to_str(snd)
            if lbl === nothing
                try
                    lbl = string(snd)
                catch
                    lbl = nothing
                end
            end
            if lbl !== nothing
                return esc(:(begin
                    GeoGebra.send_listen($(QuoteNode(lbl)); enabled=true)
                    GeoGebra.get_object_observable($(QuoteNode(lbl)))
                end))
            end
        end
        # Support `@ggb :unlisten :O` shorthand: send a listen request with
        # enabled=false to stop listening for updates for the object.
        if fstr_top !== nothing && lowercase(fstr_top) == "unlisten" && length(toks) >= 2
            snd = toks[2]
            lbl = _tok_to_str(snd)
            if lbl === nothing
                try
                    lbl = string(snd)
                catch
                    lbl = nothing
                end
            end
            if lbl !== nothing
                return esc(:(begin
                    GeoGebra.send_listen($(QuoteNode(lbl)); enabled=false)
                    nothing
                end))
            end
        end
        if first isa Expr && first.head == :vect
            # Handle array-literal form like @ggb["O"] where the macro sees
            # an Expr(:vect, elem...). If single-element and the element is a
            # string/symbol/quoted symbol, treat as label lookup into construction.
            elems = first.args
            if length(elems) == 1
                lbl = _tok_to_str(elems[1])
                if lbl !== nothing
                    expr = :(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end)
                    return esc(expr)
                end
            end
        end

        if first isa Expr && first.head == :ref
            args_ref = first.args
            # Case 0: empty index -> return all construction entries
            if length(args_ref) == 0
                return esc(:(GeoGebra.construction_protocol()))
            end
            # Case A: form like `construction[idx]` (two-arg ref)
            if length(args_ref) == 2
                headsym = args_ref[1]
                hstr = _tok_to_str(headsym)
                if is_cons_str(hstr)
                    idx_node = args_ref[2]
                    # If the index node is a parenthesized/call form like `(:O)`
                    # or `:const(:O)`, extract the inner token and treat it as a
                    # label lookup. Otherwise fall back to direct token-to-string.
                    if idx_node isa Expr && (idx_node.head == :call || idx_node.head == :paren) && length(idx_node.args) >= 1
                        lbl = _tok_to_str(idx_node.args[1])
                    else
                        lbl = _tok_to_str(idx_node)
                    end
                    if lbl !== nothing && lbl != ":" && lbl != "end"
                        expr = :(begin
                            ch = GeoGebra.construction_protocol()
                            lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                            isempty(lbls) ? lbls : lbls[end]
                        end)
                        return esc(expr)
                    else
                        # Simplified support: accept full-slice `:`/`[:]`, `[end]`,
                        # or a positive integer index like `1` or `[1]`.
                        # Handle various parser node shapes for slice/index forms
                        # Prefer structural checks when possible (Expr/Symbol),
                        # falling back to string-matching for QuoteNode/text forms.
                        if isa(idx_node, Expr)
                            # vector literal form like `[:]` -> Expr(:vect, ...)
                            if idx_node.head == :vect && length(idx_node.args) == 1
                                e = idx_node.args[1]
                                if isa(e, Symbol) && string(e) == ":"
                                    return esc(:(let ch = GeoGebra.construction_protocol(); labels = [g.label for g in ch]; args = [[lbl] for lbl in labels]; cmds = GeoGebra.send_function("getCommandString", args); cmds_arr = try isa(cmds, AbstractVector) ? cmds : collect(cmds) catch; cmds end; [(i, ch[i].label, cmds_arr[i]) for i in 1:length(ch)] end))
                                elseif isa(e, Symbol) && string(e) == "end"
                                    return esc(:(let ch = GeoGebra.construction_protocol(); g = ch[end]; (length(ch), g.label, GeoGebra.send_function("getCommandString", [ [g.label] ])) end))
                                end
                            end
                            # direct colon expression (rare) -> treat as full slice
                                if idx_node.head == :colon
                                return esc(:(let ch = GeoGebra.construction_protocol(); labels = [g.label for g in ch]; args = [[lbl] for lbl in labels]; cmds = GeoGebra.send_function("getCommandString", args); cmds_arr = try isa(cmds, AbstractVector) ? cmds : collect(cmds) catch; cmds end; [(i, ch[i].label, cmds_arr[i]) for i in 1:length(ch)] end))
                            end
                        end
                        s = isa(idx_node, QuoteNode) && isa(idx_node.value, String) ? idx_node.value : string(idx_node)
                        # Full-slice forms -> return all tuples
                        if strip(s) == ":" || match(r"^\s*\[\s*:\s*\]\s*$", s) !== nothing
                                    return esc(:(let ch = GeoGebra.construction_protocol(); labels = [g.label for g in ch]; args = [[lbl] for lbl in labels]; cmds = GeoGebra.send_function("getCommandString", args); cmds_arr = try isa(cmds, AbstractVector) ? cmds : collect(cmds) catch; cmds end; [(i, ch[i].label, cmds_arr[i]) for i in 1:length(ch)] end))
                        end
                        # [end]
                        if match(r"^\s*\[?\s*end\s*\]?\s*$", s) !== nothing
                            return esc(:(let ch = GeoGebra.construction_protocol(); g = ch[end]; (length(ch), g.label, GeoGebra.send_function("getCommandString", g.label)) end))
                        end
                        # Positive integer index fallback like "1" or "[1]"
                        m = match(r"^\s*\[?\s*(\d+)\s*\]?\s*$", s)
                        if m !== nothing
                            numstr = m.captures[1]
                            return esc(:(let ch = GeoGebra.construction_protocol();
                                            idx = parse(Int, $(QuoteNode(numstr)));
                                            if idx == 0
                                                throw(BoundsError("index 0 invalid"))
                                            end
                                            g = ch[idx]
                                            (idx, g.label, GeoGebra.send_function("getCommandString", g.label))
                                         end))
                        end
                        # non-label two-arg ref: fall through to command fallback
                    end
                end
            # Case B: form like `@ggb[idx]` (single-arg ref) — treat as construction lookup
            elseif length(args_ref) == 1
                idx_node = args_ref[1]
                lbl = _tok_to_str(idx_node)
                if lbl !== nothing
                    expr = :(begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end)
                    return esc(expr)
                else
                    # non-label single-ref: fall through to command fallback
                end
            end
        else
            fstr = _tok_to_str(first)
                if is_cons_str(fstr)
                return esc(:(let ch = GeoGebra.construction_protocol(); labels = [g.label for g in ch]; args = [[lbl] for lbl in labels]; cmds = GeoGebra.send_function("getCommandString", args); cmds_arr = try isa(cmds, AbstractVector) ? cmds : collect(cmds) catch; cmds end; [(i, ch[i].label, cmds_arr[i]) for i in 1:length(ch)] end))
            end
        end
    end
    ex = nothing
    if length(toks) == 1
        ex = toks[1]
        # Additional handling: if macro is invoked with a bare index form like
        # `@ggb[1]` the parser may present the index as various node types
        # (Integer, QuoteNode("[1]"), Expr(:vect,...)). Normalize common
        # cases here so they are treated as construction lookups rather than
        # falling back to sending a command string.
        # Normalize single-token vector forms (label lookup). Numeric bare-index
        # forms (e.g. @ggb[1]) are intentionally not supported and will fall
        # through to the command fallback — this keeps behavior consistent
        # with @ggb[:O] / @ggb["O"] label lookups which are supported above.
        if ex isa Expr && ex.head == :vect
            elems = ex.args
            if length(elems) == 1
                lbl = _tok_to_str(elems[1])
                if lbl !== nothing
                        return esc(:((begin
                        ch = GeoGebra.construction_protocol()
                        lbls = [g for g in ch if g.label == $(QuoteNode(lbl))]
                        isempty(lbls) ? lbls : lbls[end]
                    end)))
                end
            end
        end
    else
        tokstr = _tok_to_str(toks[1])
        if tokstr == "api"
            if length(toks) < 2
                error("@ggblab api usage must be like `@ggblab api fn(args...)`")
            end
            ex = Expr(:call, :api, toks[2])
        else
            head = toks[1]
            args_rest = toks[2:end]
            ex = Expr(:call, head, args_rest...)
        end
    end

    if ex isa Expr && ex.head == :call && ex.args !== nothing && length(ex.args) >= 1 && ex.args[1] == :api
        inner = ex.args[2]
        return Expr(:macrocall, Symbol("@ggblab_function"), __source__, inner)
    end

    # Delegate non-API branch to the module-qualified `@ggblab_command` macro
    return Expr(:macrocall, Symbol("@ggblab_command"), __source__, ex)
end


# Alias `@ggb` to `@ggblab` for convenience
# const var"@ggb" = var"@ggblab"

@eval const $(Symbol("@ggb")) = $(Symbol("@ggblab"))

# macro ggb(args...)
#     return esc(Expr(:macrocall, Symbol("@ggblab"), args...))
# end

"""Run a Python coroutine (PythonCall.PyObject) with asyncio.run.

Usage:
```
# obtain a coroutine object, e.g. via `py"coro()"` or `pyeval("coro()")`
# coro = py"coro()"
result = @await coro
```
"""
macro await(expr)
    return :(let _asyncio = PythonCall.pyimport("asyncio")
                _coro = $(esc(expr))
                _asyncio.run(_coro)
             end)
end
