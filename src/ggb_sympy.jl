"""Helpers: sympy_to_ggb and expr_to_cmd_string

This file contains reusable helpers that convert SymPy/PythonCall
objects into GeoGebra-friendly strings and stringify Julia Expr/Symbol
nodes into GeoGebra command notation.
"""

using SymPyPythonCall

"""Convert SymPy (Sym/Py) scalar or matrix values into a GeoGebra
matrix/expr string.

Signature:
`function sympy_to_ggb(x::Union{Matrix{Sym{SymPyPythonCall.Py}}, Sym{SymPyPythonCall.Py}})`

If `x` is a Julia matrix of `Sym` elements, each element is stringified
and assembled into a GeoGebra matrix like `{{a,b},{c,d}}`.
If `x` is a Sym (Python-backed) value and its string form contains a
bracketed matrix like `[...]`, the inner rows are parsed and converted
to the GeoGebra nested-brace form. Otherwise the function returns the
string representation of `x`.
"""
function sympy_to_ggb(x::Union{Matrix{Sym{SymPyPythonCall.Py}}, Sym{SymPyPythonCall.Py}})
    # Helper: split at top-level separators only (ignore separators inside
    # parentheses/brackets/braces and quoted strings)
    function split_top_level(s::AbstractString, seps::AbstractVector{Char})
        parts = String[]
        buf = IOBuffer()
        depth_paren = 0
        depth_sq = 0
        depth_brace = 0
        in_quote = false
        quotechar = '\0'
        i = 1
        while i <= lastindex(s)
            ch = s[i]
            if in_quote
                if ch == quotechar
                    in_quote = false
                end
                write(buf, ch)
            else
                if ch == '"' || ch == '\''
                    in_quote = true
                    quotechar = ch
                    write(buf, ch)
                elseif ch == '('
                    depth_paren += 1; write(buf, ch)
                elseif ch == ')'
                    depth_paren = max(depth_paren - 1, 0); write(buf, ch)
                elseif ch == '['
                    depth_sq += 1; write(buf, ch)
                elseif ch == ']'
                    depth_sq = max(depth_sq - 1, 0); write(buf, ch)
                elseif ch == '{'
                    depth_brace += 1; write(buf, ch)
                elseif ch == '}'
                    depth_brace = max(depth_brace - 1, 0); write(buf, ch)
                elseif depth_paren == 0 && depth_sq == 0 && depth_brace == 0 && ch in seps
                    push!(parts, String(take!(buf)))
                else
                    write(buf, ch)
                end
            end
            i += 1
        end
        push!(parts, String(take!(buf)))
        return [strip(p) for p in parts if strip(p) != ""]
    end

    # Matrix-of-Sym elements (native Julia matrix)
    if x isa AbstractMatrix
        r = Int(size(x, 1)); c = Int(size(x, 2))
        rows = String[]
        for i in 1:r
            elems = String[]
            for j in 1:c
                push!(elems, string(x[i, j]))
            end
            push!(rows, "{" * join(elems, ", ") * "}")
        end
        return "{" * join(rows, ", ") * "}"
    end

    # Sym{Py} scalar or Python-side Matrix printed as a string
    s = string(x)
    # Extract the first bracketed region (outermost '[' ... ']') if present
    function extract_bracket_inner(str::AbstractString)
        starti = findfirst(c -> c == '[', str)
        if starti === nothing
            return nothing
        end
        depth = 0
        i = starti
        buf = IOBuffer()
        while i <= lastindex(str)
            ch = str[i]
            if ch == '['
                depth += 1
                if depth > 1
                    write(buf, ch)
                end
            elseif ch == ']'
                depth -= 1
                if depth == 0
                    return String(take!(buf))
                else
                    write(buf, ch)
                end
            else
                if depth >= 1
                    write(buf, ch)
                end
            end
            i += 1
        end
        return nothing
    end

    inner = extract_bracket_inner(s)
    if inner === nothing
        return s
    end

    # Try semicolon row separators first (SymPy printable matrix may use ';')
    rows = split_top_level(inner, [';'])
    if length(rows) == 1
        # Fallback: split top-level on comma which separates inner-row lists
        rows = split_top_level(inner, [','])
        # If rows look like bracketed inner lists, e.g. "[a,b],[c,d]",
        # then rows currently will be like "[a,b]" and "[c,d]" — remove
        # surrounding brackets for each row before splitting elements.
    end

    parsed_rows = String[]
    for rr in rows
        rtrim = rr
        # remove surrounding brackets if present
        if startswith(rtrim, "[") && endswith(rtrim, "]")
            rtrim = rtrim[2:end-1]
        elseif startswith(rtrim, "[") && endswith(rtrim, "]")
            rtrim = rtrim[2:end-1]
        end
        # split elements by top-level comma first
        elems = split_top_level(rtrim, [','])
        if length(elems) == 1
            # maybe elements are space-separated (SymPy row like "a b c")
            # split on whitespace at top level
            # reuse split_top_level by treating space as separator
            elems = split_top_level(rtrim, [' '])
        end
        push!(parsed_rows, "{" * join(elems, ", ") * "}")
    end
    return "{" * join(parsed_rows, ", ") * "}"
end

# Convert an Expr/Symbol/QuoteNode into a GeoGebra command string.
# Used by the macros to stringify RHS expressions safely.
function expr_to_cmd_string(ex)
    if ex isa QuoteNode
        v = ex.value
        if isa(v, Symbol)
            return string(v)
        elseif isa(v, String)
            return v
        else
            return string(v)
        end
    elseif ex isa Symbol
        return string(ex)
    elseif ex isa Expr
        # call expression
        if ex.head == :call && length(ex.args) >= 1
            fn_raw = ex.args[1]
            # Handle common infix/binary operators using conventional notation
            op = isa(fn_raw, Symbol) ? string(fn_raw) : ""
            if op in ("+", "-", "*", "/", "^", "==", "<", ">", "<=", ">=", "!=", "&", "|", "%")
                nargs = length(ex.args) - 1
                # unary minus
                if op == "-" && nargs == 1
                    return "-" * expr_to_cmd_string(ex.args[2])
                end
                parts = [expr_to_cmd_string(a) for a in ex.args[2:end]]
                if nargs == 2
                return "(" * join(parts[1:2], " " * op * " ") * ")"
                else
                    # chain multiple operands: a + b + c
                    return join(parts, " " * op * " ")
                end
            else
                # regular function-style call: name(arg1, arg2, ...)
                fname = expr_to_cmd_string(fn_raw)
                parts = [expr_to_cmd_string(a) for a in ex.args[2:end]]
                return fname * "(" * join(parts, ", ") * ")"
            end
        elseif ex.head == :vect
            parts = [expr_to_cmd_string(a) for a in ex.args]
            return "{" * join(parts, ", ") * "}"
        else
            try
                return string(ex)
            catch
                return string(ex)
            end
        end
    else
        return string(ex)
    end
end