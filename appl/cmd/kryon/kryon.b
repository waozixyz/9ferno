implement Kryon;

Kryon: module
{
    init: fn(ctxt: ref Draw->Context, argv: list of string);
};

include "sys.m";
    sys: Sys;
include "draw.m";
include "bufio.m";
    bufio: Bufio;
    Iobuf: import bufio;
include "sh.m";
    sh: Sh;
include "ast.m";
    ast: Ast;
include "lexer.m";
    lexer: Lexer;

# Import useful types from ast
Program, Widget, Property, Value, ReactiveFunction: import ast;

# Import useful types from lexer
LexerObj, Token: import lexer;

# Internal Parser ADT
Parser: adt {
    l: ref LexerObj;
    peek_tok: ref Token;
    has_peek: int;

    create: fn(l: ref LexerObj): ref Parser;
    next: fn(p: self ref Parser): ref Token;
    peek: fn(p: self ref Parser): ref Token;
    expect: fn(p: self ref Parser, typ: int): (ref Token, string);
};

Parser.create(l: ref LexerObj): ref Parser
{
    return ref Parser(l, nil, 0);
}

Parser.next(p: self ref Parser): ref Token
{
    if (p.has_peek) {
        p.has_peek = 0;
        return p.peek_tok;
    }
    return lexer->lex(p.l);
}

Parser.peek(p: self ref Parser): ref Token
{
    if (!p.has_peek) {
        p.peek_tok = lexer->lex(p.l);
        p.has_peek = 1;
    }
    return p.peek_tok;
}

Parser.expect(p: self ref Parser, typ: int): (ref Token, string)
{
    tok := p.next();
    if (tok.toktype != typ) {
        return (nil, sys->sprint("line %d: expected token type %d, got %d",
            tok.lineno, typ, tok.toktype));
    }
    return (tok, nil);
}

# Internal Codegen ADT
Codegen: adt {
    module_name: string;
    output: ref Sys->FD;
    tk_cmds: list of string;
    widget_counter: int;
    callbacks: list of (string, string);
    width: int;
    height: int;
    reactive_bindings: list of (string, string, string);  # (widget_path, property_name, fn_name)

    create: fn(output: ref Sys->FD, module_name: string): ref Codegen;
};

Codegen.create(output: ref Sys->FD, module_name: string): ref Codegen
{
    return ref Codegen(module_name, output, nil, 0, nil, 400, 300, nil);
}

# =========================================================================
# Parser functions
# =========================================================================

# Format error message with line number
fmt_error(p: ref Parser, msg: string): string
{
    lineno := lexer->get_lineno(p.l);
    return sys->sprint("line %d: %s", lineno, msg);
}

# Parse a reactive function declaration: name: fn() = expression every N
parse_reactive_function(p: ref Parser): (ref ReactiveFunction, string)
{
    # Parse name (before ":")
    (name_tok, err1) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err1 != nil) {
        return (nil, err1);
    }
    name := name_tok.string_val;

    # Expect ":"
    (tok1, err2) := p.expect(':');
    if (err2 != nil) {
        return (nil, fmt_error(p, "expected ':' after reactive function name"));
    }

    # Expect "fn"
    (fn_tok, err3) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err3 != nil) {
        return (nil, err3);
    }
    if (fn_tok.string_val != "fn") {
        return (nil, fmt_error(p, "expected 'fn' keyword"));
    }

    # Expect "()"
    (tok2, err4) := p.expect('(');
    if (err4 != nil) {
        return (nil, err4);
    }
    (tok3, err5) := p.expect(')');
    if (err5 != nil) {
        return (nil, err5);
    }

    # Expect "="
    (tok4, err6) := p.expect('=');
    if (err6 != nil) {
        return (nil, err6);
    }

    # Parse expression (until "every")
    expr := "";
    while (p.peek().toktype != Lexer->TOKEN_EVERY) {
        tok := p.next();

        # Build expression from tokens
        if (tok.toktype == Lexer->TOKEN_STRING) {
            expr += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            expr += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            expr += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            # Single char token
            expr += sys->sprint("%c", tok.toktype);
        }

        # Add space for next token
        if (p.peek().toktype != Lexer->TOKEN_EVERY) {
            expr += " ";
        }
    }

    # Expect "every"
    (tok5, err7) := p.expect(Lexer->TOKEN_EVERY);
    if (err7 != nil) {
        return (nil, err7);
    }

    # Parse interval number
    interval_tok := p.next();
    if (interval_tok.toktype != Lexer->TOKEN_NUMBER) {
        return (nil, fmt_error(p, "expected number after 'every'"));
    }
    interval := int interval_tok.number_val;

    return (ast->reactivefn_create(name, expr, interval), nil);
}

# Parse a value (STRING, NUMBER, COLOR, IDENTIFIER, FN_CALL)
parse_value(p: ref Parser): (ref Value, string)
{
    tok := p.next();

    case tok.toktype {
    Lexer->TOKEN_STRING =>
        # Check for function call pattern: "name()"
        s := tok.string_val;
        if (len s > 2 && s[len s - 1] == ')' && s[len s - 2] == '(') {
            fn_name := s[0: len s - 2];
            return (ast->value_create_fn_call(fn_name), nil);
        }
        return (ast->value_create_string(s), nil);

    Lexer->TOKEN_NUMBER =>
        return (ast->value_create_number(tok.number_val), nil);

    Lexer->TOKEN_COLOR =>
        return (ast->value_create_color(tok.string_val), nil);

    Lexer->TOKEN_IDENTIFIER =>
        # Check for function call pattern: name ( )
        # Peek to see if next tokens are '(' and ')'
        id_name := tok.string_val;
        if (p.peek().toktype == '(') {
            p.next();  # consume '('
            (close_paren, err) := p.expect(')');
            if (err != nil) {
                return (nil, err);
            }
            return (ast->value_create_fn_call(id_name), nil);
        }
        return (ast->value_create_ident(id_name), nil);

    * =>
        return (nil, fmt_error(p, "expected value (string, number, color, or identifier)"));
    }
}

# Parse a property (name = value)
parse_property(p: ref Parser): (ref Property, string)
{
    tok := p.next();

    if (tok.toktype != Lexer->TOKEN_IDENTIFIER) {
        return (nil, fmt_error(p, "expected property name"));
    }

    name := tok.string_val;

    # Expect '='
    (tok1, err1) := p.expect('=');
    if (err1 != nil) {
        return (nil, err1);
    }

    # Parse value
    (val, err2) := parse_value(p);
    if (err2 != nil) {
        return (nil, err2);
    }

    prop := ast->property_create(name);
    prop.value = val;

    return (prop, nil);
}

# Parse widget body content (properties and children)
parse_widget_body_content(p: ref Parser): (ref Property, ref Widget, string)
{
    props: ref Property = nil;
    children: ref Widget = nil;

    while (1) {
        tok := p.peek();

        # Check for end of body
        if (tok.toktype == '}' || tok.toktype == Lexer->TOKEN_ENDINPUT) {
            break;
        }

        # Property: identifier = value
        if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            # Peek ahead to see if next token is '='
            (prop, err1) := parse_property(p);
            if (err1 != nil) {
                return (nil, nil, err1);
            }

            if (props == nil) {
                props = prop;
            } else {
                ast->property_list_add(props, prop);
            }
        }
        # Widget: Window/Frame/Button/etc { ... }
        else if (tok.toktype >= Lexer->TOKEN_WINDOW && tok.toktype <= Lexer->TOKEN_CENTER) {
            (child, err2) := parse_widget(p);
            if (err2 != nil) {
                return (nil, nil, err2);
            }

            if (children == nil) {
                children = child;
            } else {
                ast->widget_list_add(children, child);
            }
        } else {
            return (nil, nil, fmt_error(p, "expected property or widget in body"));
        }
    }

    return (props, children, nil);
}

# Parse widget body: { ... }
parse_widget_body(p: ref Parser): (ref Widget, string)
{
    # Expect '{'
    (tok1, err1) := p.expect('{');
    if (err1 != nil) {
        return (nil, err1);
    }

    (props, children, err2) := parse_widget_body_content(p);
    if (err2 != nil) {
        return (nil, err2);
    }

    # Expect '}'
    (tok2, err3) := p.expect('}');
    if (err3 != nil) {
        return (nil, err3);
    }

    # Create a wrapper widget to hold props and children
    w := ast->widget_create(Ast->WIDGET_FRAME);
    w.props = props;
    w.children = children;
    w.is_wrapper = 1;

    return (w, nil);
}

# Parse specific widget types
parse_window(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_WINDOW);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_frame(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_FRAME);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_button(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_BUTTON);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_label(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_LABEL);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_entry(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_ENTRY);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_column(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_COLUMN);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_row(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_ROW);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_center(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_CENTER);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_checkbutton(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_CHECKBUTTON);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_radiobutton(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_RADIOBUTTON);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_listbox(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_LISTBOX);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_canvas(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_CANVAS);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_scale(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_SCALE);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_menubutton(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_MENUBUTTON);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

parse_message(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_MESSAGE);
    w.props = body.props;
    w.children = body.children;

    return (w, nil);
}

# Parse a widget (dispatch based on type)
parse_widget(p: ref Parser): (ref Widget, string)
{
    tok := p.next();

    case tok.toktype {
    Lexer->TOKEN_WINDOW =>
        return parse_window(p);

    Lexer->TOKEN_FRAME =>
        return parse_frame(p);

    Lexer->TOKEN_BUTTON =>
        return parse_button(p);

    Lexer->TOKEN_LABEL =>
        return parse_label(p);

    Lexer->TOKEN_ENTRY =>
        return parse_entry(p);

    Lexer->TOKEN_CHECKBUTTON =>
        return parse_checkbutton(p);

    Lexer->TOKEN_RADIOBUTTON =>
        return parse_radiobutton(p);

    Lexer->TOKEN_LISTBOX =>
        return parse_listbox(p);

    Lexer->TOKEN_CANVAS =>
        return parse_canvas(p);

    Lexer->TOKEN_SCALE =>
        return parse_scale(p);

    Lexer->TOKEN_MENUBUTTON =>
        return parse_menubutton(p);

    Lexer->TOKEN_MESSAGE =>
        return parse_message(p);

    Lexer->TOKEN_COLUMN =>
        return parse_column(p);

    Lexer->TOKEN_ROW =>
        return parse_row(p);

    Lexer->TOKEN_CENTER =>
        return parse_center(p);

    * =>
        return (nil, fmt_error(p, sys->sprint("unknown widget type token: %d", tok.toktype)));
    }
}

# Parse a single code block or reactive function
parse_code_block(p: ref Parser): (ref Ast->CodeBlock, string)
{
    tok := p.next();

    code := "";
    typ := 0;

    case tok.toktype {
    Lexer->TOKEN_LIMBO =>
        typ = Ast->CODE_LIMBO;
        code = tok.string_val;

    Lexer->TOKEN_TCL =>
        typ = Ast->CODE_TCL;
        code = tok.string_val;

    Lexer->TOKEN_LUA =>
        typ = Ast->CODE_LUA;
        code = tok.string_val;

    * =>
        return (nil, fmt_error(p, "expected code block (@limbo, @tcl, or @lua)"));
    }

    return (ast->code_block_create(typ, code), nil);
}

# Parse multiple code blocks and reactive functions
parse_code_blocks(p: ref Parser): (ref Ast->CodeBlock, string)
{
    first: ref Ast->CodeBlock = nil;
    last: ref Ast->CodeBlock = nil;

    while (1) {
        tok := p.peek();

        if (tok.toktype != Lexer->TOKEN_LIMBO &&
            tok.toktype != Lexer->TOKEN_TCL &&
            tok.toktype != Lexer->TOKEN_LUA) {
            break;
        }

        (cb, err) := parse_code_block(p);
        if (err != nil) {
            return (nil, err);
        }

        if (first == nil) {
            first = cb;
            last = cb;
        } else {
            last.next = cb;
            last = cb;
        }
    }

    return (first, nil);
}

# Parse app declaration
parse_app_decl(p: ref Parser): (ref Ast->AppDecl, string)
{
    tok := p.next();

    case tok.toktype {
    Lexer->TOKEN_WINDOW =>
        # OK, continue
    * =>
        return (nil, fmt_error(p, "expected Window declaration"));
    }

    # Expect '{'
    (tok1, err1) := p.expect('{');
    if (err1 != nil) {
        return (nil, err1);
    }

    (props, children, err2) := parse_widget_body_content(p);
    if (err2 != nil) {
        return (nil, err2);
    }

    # Expect '}'
    (tok2, err3) := p.expect('}');
    if (err3 != nil) {
        return (nil, err3);
    }

    app := ast->app_decl_create();
    app.props = props;
    app.body = children;

    return (app, nil);
}

# Parse a complete program
parse_program(p: ref Parser): (ref Program, string)
{
    prog := ast->program_create();

    # Parse optional code blocks
    tok := p.peek();
    if (tok.toktype == Lexer->TOKEN_LIMBO ||
        tok.toktype == Lexer->TOKEN_TCL ||
        tok.toktype == Lexer->TOKEN_LUA) {

        (code_blocks, err) := parse_code_blocks(p);
        if (err != nil) {
            return (nil, err);
        }
        prog.code_blocks = code_blocks;

        # Extract reactive functions from @limbo code blocks
        cb := prog.code_blocks;
        while (cb != nil) {
            if (cb.cbtype == Ast->CODE_LIMBO && cb.code != nil) {
                code := cb.code;

                # Look for reactive function pattern: name: fn() = expr every N
                (nlines, lines_list) := sys->tokenize(code, "\n");
                lines := array[nlines] of string;
                i := 0;
                for (ll := lines_list; ll != nil; ll = tl ll) {
                    lines[i++] = hd ll;
                }

                for (kline := 0; kline < nlines; kline++) {
                    line := lines[kline];

                    # Check if line contains "every"
                    (nwords, words_list) := sys->tokenize(line, " ");
                    if (nwords >= 2) {
                        # Convert list to array for easier access
                        words := array[nwords] of string;
                        j := 0;
                        for (wl := words_list; wl != nil; wl = tl wl) {
                            words[j++] = hd wl;
                        }

                        # Look for "every" keyword
                        found_every := 0;
                        for (j = 0; j < nwords; j++) {
                            if (words[j] == "every") {
                                found_every = 1;
                                break;
                            }
                        }

                        if (found_every) {
                            # This is a reactive function declaration
                            # Parse it manually
                            # Format: name: fn() = expression every N

                            # Find name (before ":")
                            colon := 0;
                            for (k := 0; k < len line; k++) {
                                if (line[k] == ':') {
                                    colon = k;
                                    break;
                                }
                            }

                            if (colon > 0) {
                                name := line[0:colon];

                                # Find "every"
                                every_pos := 0;
                                for (k := 0; k < len line; k++) {
                                    if (k + 5 <= len line &&
                                        line[k:k+5] == "every") {
                                        every_pos = k;
                                        break;
                                    }
                                }

                                if (every_pos > 0) {
                                    # Extract expression (after "=" and before "every")
                                    eq_pos := colon + 1;
                                    while (eq_pos < every_pos && line[eq_pos] != '=')
                                        eq_pos++;

                                    if (eq_pos < every_pos) {
                                        expr_start := eq_pos + 1;
                                        while (expr_start < every_pos &&
                                               (line[expr_start] == ' ' || line[expr_start] == '\t'))
                                            expr_start++;

                                        expr_end := every_pos - 1;
                                        while (expr_end > expr_start &&
                                               (line[expr_end] == ' ' || line[expr_end] == '\t'))
                                            expr_end--;

                                        expr := line[expr_start:expr_end + 1];

                                        # Extract interval
                                        interval_str := line[every_pos + 5:];
                                        while (len interval_str > 0 &&
                                               (interval_str[0] == ' ' || interval_str[0] == '\t'))
                                            interval_str = interval_str[1:];

                                        interval := 0;
                                        (nintv, intv_list) := sys->tokenize(interval_str, " ");
                                        if (nintv > 0) {
                                            interval = int big hd intv_list;
                                        }

                                        # Create reactive function
                                        rfn := ast->reactivefn_create(name, expr, interval);
                                        ast->program_add_reactive_fn(prog, rfn);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            cb = cb.next;
        }
    }

    # Parse app declaration
    (app, err) := parse_app_decl(p);
    if (err != nil) {
        return (nil, err);
    }
    prog.app = app;

    return (prog, nil);
}

# =========================================================================
# Code generation functions
# =========================================================================

# Escape a string for Tk
escape_tk_string(s: string): string
{
    if (s == nil)
        return "{}";

    # Check if string needs braces
    needs_braces := 0;
    for (i := 0; i < len s; i++) {
        c := s[i];
        if (c == ' ' || c == '{' || c == '}' || c == '\\' ||
            c == '$' || c == '[' || c == ']') {
            needs_braces = 1;
            break;
        }
    }

    if (!needs_braces)
        return s;

    # Build {value} with escapes
    result := "{";

    for (j := 0; j < len s; j++) {
        c := s[j];
        if (c == '}' || c == '\\')
            result[len result] = '\\';
        result[len result] = c;
    }

    result[len result] = '}';

    return result;
}

# Map Kryon property names to Tk property names
map_property_name(prop_name: string): string
{
    # Tk color properties
    if (prop_name == "fg")
        return "fg";

    if (prop_name == "bg")
        return "bg";

    # Label widget uses -label for text (not -text)
    if (prop_name == "text")
        return "label";

    # Border properties
    if (prop_name == "borderwidth")
        return "borderwidth";

    if (prop_name == "bordercolor")
        return "bordercolor";

    # Pack options - handled separately via pack command
    if (prop_name == "fill" || prop_name == "expand" ||
        prop_name == "side" || prop_name == "weight" ||
        prop_name == "anchor" || prop_name == "posX" ||
        prop_name == "posY" || prop_name == "contentAlignment")
        return "";

    # Widget-specific Tk options - return as-is
    return prop_name;
}

# Convert widget type to Tk widget type
widget_type_to_tk(typ: int): string
{
    case typ {
    Ast->WIDGET_WINDOW =>
        return "toplevel";
    Ast->WIDGET_FRAME =>
        return "frame";
    Ast->WIDGET_BUTTON =>
        return "button";
    Ast->WIDGET_LABEL =>
        return "label";
    Ast->WIDGET_ENTRY =>
        return "entry";
    Ast->WIDGET_CHECKBUTTON =>
        return "checkbutton";
    Ast->WIDGET_RADIOBUTTON =>
        return "radiobutton";
    Ast->WIDGET_LISTBOX =>
        return "listbox";
    Ast->WIDGET_CANVAS =>
        return "canvas";
    Ast->WIDGET_SCALE =>
        return "scale";
    Ast->WIDGET_MENUBUTTON =>
        return "menubutton";
    Ast->WIDGET_MESSAGE =>
        return "message";
    Ast->WIDGET_COLUMN =>
        return "frame";
    Ast->WIDGET_ROW =>
        return "frame";
    Ast->WIDGET_CENTER =>
        return "frame";
    * =>
        return "frame";
    }
}

# Check if a property is a callback (returns event name or nil)
is_callback_property(prop_name: string): string
{
    # Callbacks start with "on" (onClick, onChanged, onChecked, etc.)
    if (len prop_name >= 2 && prop_name[0:1] == "o" && prop_name[1:2] == "n")
        return prop_name;

    return nil;
}

# Convert value to Tk string
value_to_tk(v: ref Value): string
{
    if (v == nil)
        return "{}";

    if (v.valtype == Ast->VALUE_STRING)
        return escape_tk_string(ast->value_get_string(v));
    if (v.valtype == Ast->VALUE_NUMBER)
        return sys->sprint("%bd", ast->value_get_number(v));
    if (v.valtype == Ast->VALUE_COLOR)
        return escape_tk_string(ast->value_get_color(v));
    if (v.valtype == Ast->VALUE_IDENTIFIER)
        return ast->value_get_ident(v);

    return "{}";
}

# Append a Tk command to the commands list
append_tk_cmd(cg: ref Codegen, cmd: string)
{
    cg.tk_cmds = cmd :: cg.tk_cmds;
}

# Add a callback to the callback list
add_callback(cg: ref Codegen, name: string, event: string)
{
    cg.callbacks = (name, event) :: cg.callbacks;
}

# Add a reactive binding to the bindings list
add_reactive_binding(cg: ref Codegen, widget_path: string, property_name: string, fn_name: string)
{
    cg.reactive_bindings = (widget_path, property_name, fn_name) :: cg.reactive_bindings;
}

# Generate code for a single widget
generate_widget(cg: ref Codegen, w: ref Widget, parent: string, is_root: int): string
{
    if (w == nil)
        return nil;

    # Skip wrapper widgets only (keep layout widgets!)
    if (w.is_wrapper) {
        return generate_widget_list(cg, w.children, parent, is_root);
    }

    # Build widget path
    widget_path := "";

    if (is_root) {
        widget_path = sys->sprint(".w%d", cg.widget_counter);
    } else {
        widget_path = sys->sprint("%s.w%d", parent, cg.widget_counter);
    }
    cg.widget_counter++;

    # Build widget creation command
    tk_type := widget_type_to_tk(w.wtype);

    # Collect properties into a list, then reverse and build command
    # Each property is stored as [prop_name, value]
    props_list: list of string = nil;

    # NEW: Extract pack options from properties
    pack_fill := "";
    pack_expand := 0;
    pack_side := "";
    pack_anchor := "";

    # Generate properties
    callbacks: list of (string, string) = nil;

    prop := w.props;
    while (prop != nil) {
        # Check for pack-specific properties first
        if (prop.name == "fill") {
            pack_fill = ast->value_get_string(prop.value);
            prop = prop.next;
            continue;
        }
        if (prop.name == "expand") {
            s := ast->value_get_string(prop.value);
            if (s == "1" || s == "true")
                pack_expand = 1;
            prop = prop.next;
            continue;
        }
        if (prop.name == "side") {
            pack_side = ast->value_get_string(prop.value);
            prop = prop.next;
            continue;
        }
        if (prop.name == "anchor") {
            pack_anchor = ast->value_get_string(prop.value);
            prop = prop.next;
            continue;
        }

        # Handle callbacks and regular properties
        cb_event := is_callback_property(prop.name);

        if (cb_event != nil && prop.value != nil) {
            # Check if this is a callback (value should be Identifier)
            is_callback := 0;
            callback_name := "";

            if (prop.value.valtype == Ast->VALUE_IDENTIFIER) {
                is_callback = 1;
                callback_name = ast->value_get_ident(prop.value);
            }

            if (is_callback) {
                callbacks = (callback_name, prop.name) :: callbacks;
            } else {
                # Regular property
                tk_prop := map_property_name(prop.name);

                # Skip properties that don't map to valid Tk options
                if (tk_prop != "") {
                    # Check if value is a function call (reactive binding)
                    val_str := "";
                    if (prop.value != nil && prop.value.valtype == Ast->VALUE_FN_CALL) {
                        # Extract function name from FnCall value
                        fn_name := "";
                        pick fv := prop.value {
                        FnCall =>
                            fn_name = fv.fn_name;
                        * =>
                            # Fall through to regular handling
                        }

                        if (fn_name != nil && fn_name != "") {
                            # Track reactive binding
                            add_reactive_binding(cg, widget_path, prop.name, fn_name);
                            # Use placeholder for initial value
                            val_str = "{}";
                        } else {
                            val_str = value_to_tk(prop.value);
                        }
                    } else {
                        val_str = value_to_tk(prop.value);
                    }

                    prop_cmd := sys->sprint("-%s", tk_prop);
                    # Prepend to list (will be reversed later)
                    props_list = val_str :: prop_cmd :: props_list;
                }
            }
        } else {
            # Regular property
            tk_prop := map_property_name(prop.name);

            # Skip properties that don't map to valid Tk options
            if (tk_prop != "") {
                # Check if value is a function call (reactive binding)
                val_str := "";
                if (prop.value != nil && prop.value.valtype == Ast->VALUE_FN_CALL) {
                    # Extract function name from FnCall value
                    fn_name := "";
                    pick fv := prop.value {
                    FnCall =>
                        fn_name = fv.fn_name;
                    * =>
                        # Fall through to regular handling
                    }

                    if (fn_name != nil && fn_name != "") {
                        # Track reactive binding
                        add_reactive_binding(cg, widget_path, prop.name, fn_name);
                        # Use placeholder for initial value
                        val_str = "{}";
                    } else {
                        val_str = value_to_tk(prop.value);
                    }
                } else {
                    val_str = value_to_tk(prop.value);
                }

                prop_cmd := sys->sprint("-%s", tk_prop);
                # Prepend to list (will be reversed later)
                props_list = val_str :: prop_cmd :: props_list;
            }
        }

        prop = prop.next;
    }

    # Reverse props_list to get correct order
    # Currently: [val2, -prop2, val1, -prop1]
    # After reverse: [-prop1, val1, -prop2, val2]
    rev_props: list of string = nil;
    while (props_list != nil) {
        rev_props = hd props_list :: rev_props;
        props_list = tl props_list;
    }

    # Build command string: "type path -prop1 val1 -prop2 val2 ..."
    cmd := sys->sprint("%s %s", tk_type, widget_path);

    while (rev_props != nil) {
        cmd += " " + hd rev_props;
        rev_props = tl rev_props;
    }

    # Add callbacks to widget creation command
    # For Tk, callbacks use -command option
    # Make a copy for widget command, keep original for dispatcher
    cbs_for_widget := callbacks;
    while (cbs_for_widget != nil) {
        (name, event) := hd cbs_for_widget;
        # Map Kryon event names to Tk command names
        # For most widgets, it's just -command
        cmd += " -command {send cmd " + name + "}";
        cbs_for_widget = tl cbs_for_widget;
    }

    append_tk_cmd(cg, cmd);

    # For root widgets (direct children of toplevel), configure their size
    # Root widgets have no parent to give them dimensions, so they need explicit size
    if (is_root) {
        append_tk_cmd(cg, sys->sprint("%s configure -width %d -height %d", widget_path, cg.width, cg.height));
    }

    # Process children FIRST (they need to be packed before this widget)
    if (w.children != nil) {
        err := generate_widget_list(cg, w.children, widget_path, 0);
        if (err != nil)
            return err;
    }

    # Generate pack command with explicit options
    pack_opts := "";

    # Layout widget defaults
    if (w.wtype == Ast->WIDGET_CENTER) {
        pack_anchor = "center";
    } else if (w.wtype == Ast->WIDGET_COLUMN) {
        pack_side = "top";
        pack_fill = "x";
    } else if (w.wtype == Ast->WIDGET_ROW) {
        pack_side = "left";
        pack_fill = "y";
    }

    # User-specified options override defaults
    if (pack_side != nil && pack_side != "")
        pack_opts += " -side " + pack_side;
    if (pack_fill != nil && pack_fill != "" && pack_fill != "none")
        pack_opts += " -fill " + pack_fill;
    if (pack_expand)
        pack_opts += " -expand 1";
    if (pack_anchor != nil && pack_anchor != "")
        pack_opts += " -anchor " + pack_anchor;

    # Default fill behavior if no options specified
    if (pack_opts == nil || pack_opts == "")
        pack_opts = " -fill both -expand 1";
    else if (!pack_expand && (pack_fill == nil || pack_fill == ""))
        # Add -fill both if not specified and no expand
        pack_opts += " -fill both -expand 1";

    pack_cmd := sys->sprint("pack %s%s", widget_path, pack_opts);
    append_tk_cmd(cg, pack_cmd);

    # Store callbacks for later
    while (callbacks != nil) {
        (name, event) := hd callbacks;
        add_callback(cg, name, event);
        callbacks = tl callbacks;
    }

    return nil;
}

# Process widget list
generate_widget_list(cg: ref Codegen, w: ref Widget, parent: string, is_root: int): string
{
    while (w != nil) {
        if (w.is_wrapper) {
            # Process children of wrapper with same parent
            child := w.children;
            while (child != nil) {
                if (child.is_wrapper) {
                    err := generate_widget_list(cg, child.children, parent, is_root);
                    if (err != nil)
                        return err;
                } else {
                    err := generate_widget(cg, child, parent, is_root);
                    if (err != nil)
                        return err;
                }
                child = child.next;
            }
        } else {
            # Generate widget normally (including layout widgets like Center/Column/Row)
            err := generate_widget(cg, w, parent, is_root);
            if (err != nil)
                return err;
        }
        w = w.next;
    }

    return nil;
}

# Collect widget commands
collect_widget_commands(cg: ref Codegen, prog: ref Program): string
{
    cg.widget_counter = 0;

    if (prog == nil || prog.app == nil || prog.app.body == nil)
        return nil;

    return generate_widget_list(cg, prog.app.body, ".", 1);
}

# Generate reactive function variables and update functions
generate_reactive_functions(cg: ref Codegen, prog: ref Program): string
{
    rfns := prog.reactive_fns;

    while (rfns != nil) {
        name := rfns.name;
        expr := rfns.expression;
        interval := rfns.interval;

        # Generate module variable for cached value
        sys->fprint(cg.output, "%s: string;\n\n", name);

        # Generate update function
        sys->fprint(cg.output, "%s_update()\n", name);
        sys->fprint(cg.output, "{\n");
        sys->fprint(cg.output, "    %s = %s;\n", name, expr);

        # Generate widget updates for all bindings
        # Reverse bindings to get correct order
        bindings := cg.reactive_bindings;
        rev_bindings: list of (string, string, string) = nil;
        while (bindings != nil) {
            rev_bindings = hd bindings :: rev_bindings;
            bindings = tl bindings;
        }

        while (rev_bindings != nil) {
            (widget_path, prop_name, fn_name) := hd rev_bindings;
            if (fn_name == name) {
                tk_prop := map_property_name(prop_name);
                if (tk_prop != "") {
                    sys->fprint(cg.output, "    tk->cmd(toplevel, \"%s configure -%s {\"+%s+\"};update\");\n",
                        widget_path, tk_prop, name);
                }
            }
            rev_bindings = tl rev_bindings;
        }

        sys->fprint(cg.output, "}\n\n");

        rfns = rfns.next;
    }

    return nil;
}

# Generate reactive timer function
generate_reactive_timer(cg: ref Codegen, prog: ref Program): string
{
    if (prog.reactive_fns == nil)
        return nil;

    # Find the minimum interval
    min_interval := 1000000;
    rfns := prog.reactive_fns;

    while (rfns != nil) {
        if (rfns.interval > 0 && rfns.interval < min_interval)
            min_interval = rfns.interval;
        rfns = rfns.next;
    }

    if (min_interval >= 1000000)
        return nil;

    # Generate timer function
    sys->fprint(cg.output, "reactive_timer(tick: chan of int)\n");
    sys->fprint(cg.output, "{\n");
    sys->fprint(cg.output, "    for(;;) {\n");
    sys->fprint(cg.output, "        tick <-= 1;\n");
    sys->fprint(cg.output, "        sys->sleep(%d);\n", min_interval);
    sys->fprint(cg.output, "    }\n");
    sys->fprint(cg.output, "}\n\n");

    return nil;
}

# Check if program has reactive functions
has_reactive_functions(prog: ref Program): int
{
    return (prog.reactive_fns != nil);
}

# Generate prologue
generate_prologue(cg: ref Codegen, prog: ref Program): string
{
    buf := "";

    buf += sys->sprint("implement %s;\n\n", cg.module_name);

    buf += "include \"sys.m\";\n";
    buf += "include \"draw.m\";\n";
    buf += "include \"tk.m\";\n";
    buf += "include \"tkclient.m\";\n";

    # Add daytime.m include if reactive functions use it
    rfns := prog.reactive_fns;
    while (rfns != nil) {
        if (rfns.expression != nil && len rfns.expression > 0) {
            # Check if expression uses "daytime"
            (nparts, parts_list) := sys->tokenize(rfns.expression, "->");
            if (nparts > 1) {
                if (hd parts_list == "daytime") {
                    buf += "include \"daytime.m\";\n";
                    break;
                }
            }
        }
        rfns = rfns.next;
    }

    buf += "\n";

    buf += "sys: Sys;\n";
    buf += "draw: Draw;\n";
    buf += "tk: Tk;\n";
    buf += "tkclient: Tkclient;\n";

    # Add module imports for reactive functions (like daytime)
    rfn := prog.reactive_fns;
    while (rfn != nil) {
        if (rfn.expression != nil && len rfn.expression > 0) {
            # Check if expression uses "daytime"
            (nwords, words_list) := sys->tokenize(rfn.expression, " ");
            if (nwords > 0 && hd words_list == "daytime->time()" ||
                len rfn.expression > 10 && rfn.expression[0:10] == "daytime->") {
                buf += "daytime: Daytime;\n";
                break;
            }
        }
        rfn = rfn.next;
    }

    buf += "\n";

    # Generate module declaration
    buf += sys->sprint("%s: module\n{\n", cg.module_name);
    buf += "    init: fn(ctxt: ref Draw->Context, nil: list of string);\n";

    # Add function signatures from code blocks (excluding reactive functions)
    cb := prog.code_blocks;
    while (cb != nil) {
        if (cb.cbtype == Ast->CODE_LIMBO && cb.code != nil) {
            # Try to extract function name from code like "funcName: fn(...) {"
            code := cb.code;
            colon := 0;

            # Find colon
            for (j := 0; j < len code; j++) {
                if (code[j] == ':') {
                    colon = j;
                    break;
                }
            }

            if (colon > 0 && colon + 4 < len code) {
                if (code[colon+1] == ' ' && code[colon+2] == 'f' &&
                    code[colon+3] == 'n' && code[colon+4] == '(') {

                    # Check if this line contains "every" - if so, skip it (reactive function)
                    line_start := colon;
                    while (line_start > 0 && code[line_start] != '\n')
                        line_start--;

                    line_end := colon + 5;
                    while (line_end < len code && code[line_end] != '\n')
                        line_end++;

                    is_reactive := 0;
                    if (line_end < len code) {
                        line := code[line_start : line_end];
                        for (k := 0; k < len line - 4; k++) {
                            if (line[k:k+5] == "every") {
                                is_reactive = 1;
                                break;
                            }
                        }
                    }

                    if (!is_reactive) {
                        # Find function name start
                        start := colon - 1;
                        while (start > 0 && (code[start] == '\n' || code[start] == ' ' || code[start] == '\t'))
                            start--;

                        # Find end of name
                        name_end := start;
                        while (name_end > 0 && code[name_end] != '\n' &&
                               code[name_end] != ' ' && code[name_end] != '\t')
                            name_end--;

                        func_name := code[name_end+1 : start+1];

                        if (len func_name > 0 && func_name[0] >= 'a' && func_name[0] <= 'z') {
                            buf += sys->sprint("    %s: fn();\n", func_name);
                        }
                    }
                }
            }
        }
        cb = cb.next;
    }

    # Add reactive function signatures
    rfns2 := prog.reactive_fns;
    while (rfns2 != nil) {
        buf += sys->sprint("    %s_update: fn();\n", rfns2.name);
        rfns2 = rfns2.next;
    }

    # Add reactive_timer signature if we have reactive functions
    if (has_reactive_functions(prog)) {
        buf += "    reactive_timer: fn(tick: chan of int);\n";
    }

    buf += "};\n";

    # Write prologue
    sys->fprint(cg.output, "%s", buf);

    return nil;
}

# Generate code blocks (Limbo functions)
generate_code_blocks(cg: ref Codegen, prog: ref Program): string
{
    cb := prog.code_blocks;

    while (cb != nil) {
        if (cb.cbtype == Ast->CODE_LIMBO && cb.code != nil) {
            code := cb.code;
            current := 0;

            # Process each function in the code block
            while (current < len code) {
                # Skip leading whitespace
                while (current < len code &&
                       (code[current] == '\n' || code[current] == ' ' || code[current] == '\t'))
                    current++;

                if (current >= len code)
                    break;

                # Check for reactive function declaration (contains "every")
                # Skip these as they're handled separately
                line_start := current;
                while (current < len code && code[current] != '\n')
                    current++;

                if (current > line_start) {
                    line := code[line_start : current];
                    # Check if this line is a reactive function (contains "every")
                    has_every := 0;
                    for (j := 0; j < len line - 4; j++) {
                        if (line[j:j+5] == "every") {
                            has_every = 1;
                            break;
                        }
                    }
                    if (has_every) {
                        # Skip this line - it's a reactive function
                        current++;
                        continue;
                    }
                }

                # Reset current to parse the line
                current = line_start;

                # Find function name (ends with ':')
                colon := current;
                found := 0;

                while (colon < len code) {
                    if (code[colon] == ':') {
                        found = 1;
                        break;
                    }
                    colon++;
                }

                if (!found)
                    break;

                # Find opening brace
                lbrace := colon;
                while (lbrace < len code && code[lbrace] != '{')
                    lbrace++;

                if (lbrace >= len code)
                    break;

                # Find matching closing brace
                rbrace := lbrace + 1;
                brace_count := 1;

                while (rbrace < len code && brace_count > 0) {
                    if (code[rbrace] == '{')
                        brace_count++;
                    else if (code[rbrace] == '}')
                        brace_count--;
                    rbrace++;
                }

                if (brace_count != 0)
                    break;

                # Extract function name
                name_start := current;
                while (name_start < colon &&
                       (code[name_start] == '\n' || code[name_start] == ' ' || code[name_start] == '\t'))
                    name_start++;

                func_name := code[name_start : colon];

                # Output function
                sys->fprint(cg.output, "\n%s()\n", func_name);

                # Find body start
                body_start := lbrace + 1;
                while (body_start < rbrace &&
                       (code[body_start] == '\n' || code[body_start] == ' ' || code[body_start] == '\t'))
                    body_start++;

                if (rbrace - 1 > body_start) {
                    body_end := rbrace - 2;
                    while (body_end > body_start &&
                           (code[body_end] == '\n' || code[body_end] == ' ' || code[body_end] == '\t'))
                        body_end--;

                    body := code[body_start : body_end + 1];

                    # Indent body
                    sys->fprint(cg.output, "{\n");

                    (count, lines) := sys->tokenize(body, "\n");
                    line_list := lines;

                    while (line_list != nil) {
                        line := hd line_list;
                        if (line != "")
                            sys->fprint(cg.output, "    %s\n", line);
                        else
                            sys->fprint(cg.output, "\n");
                        line_list = tl line_list;
                    }

                    sys->fprint(cg.output, "}\n");
                }

                current = rbrace;

                # Skip semicolons and whitespace
                while (current < len code &&
                       (code[current] == ';' || code[current] == '\n' ||
                        code[current] == ' ' || code[current] == '\t'))
                    current++;
            }
        }
        cb = cb.next;
    }

    return nil;
}

# Generate tkcmds array
generate_tkcmds_array(cg: ref Codegen): string
{
    sys->fprint(cg.output, "\ntkcmds := array[] of {\n");

    # Reverse commands to get correct order
    cmds := cg.tk_cmds;
    rev: list of string = nil;

    while (cmds != nil) {
        rev = hd cmds :: rev;
        cmds = tl cmds;
    }

    while (rev != nil) {
        sys->fprint(cg.output, "    \"%s\",\n", hd rev);
        rev = tl rev;
    }

    # Add pack propagate before update to prevent window from auto-sizing
    sys->fprint(cg.output, "    \"pack propagate . 0\",\n");
    sys->fprint(cg.output, "    \"update\"\n");
    sys->fprint(cg.output, "};\n\n");

    return nil;
}

# Get string property value
get_string_prop(props: ref Property, name: string): string
{
    while (props != nil) {
        if (props.name == name && props.value != nil) {
            if (props.value.valtype == Ast->VALUE_STRING)
                return ast->value_get_string(props.value);
            if (props.value.valtype == Ast->VALUE_COLOR)
                return ast->value_get_color(props.value);
        }
        props = props.next;
    }
    return nil;
}

# Get number property value
get_number_prop(props: ref Property, name: string): (int, int)
{
    while (props != nil) {
        if (props.name == name && props.value != nil) {
            if (props.value.valtype == Ast->VALUE_NUMBER)
                return (int ast->value_get_number(props.value), 1);
        }
        props = props.next;
    }
    return (0, 0);
}

# Generate init function
generate_init(cg: ref Codegen, prog: ref Program): string
{
    sys->fprint(cg.output, "init(ctxt: ref Draw->Context, nil: list of string)\n");
    sys->fprint(cg.output, "{\n");

    sys->fprint(cg.output, "    sys = load Sys Sys->PATH;\n");
    sys->fprint(cg.output, "    draw = load Draw Draw->PATH;\n");
    sys->fprint(cg.output, "    tk = load Tk Tk->PATH;\n");
    sys->fprint(cg.output, "    tkclient = load Tkclient Tkclient->PATH;\n");

    # Load daytime if reactive functions use it
    rfns := prog.reactive_fns;
    while (rfns != nil) {
        if (rfns.expression != nil && len rfns.expression > 0) {
            # Check if expression uses "daytime"
            (nparts, parts_list) := sys->tokenize(rfns.expression, "->");
            if (nparts > 1) {
                if (hd parts_list == "daytime") {
                    sys->fprint(cg.output, "    daytime = load Daytime Daytime->PATH;\n");
                    break;
                }
            }
        }
        rfns = rfns.next;
    }

    sys->fprint(cg.output, "\n");
    sys->fprint(cg.output, "    sys->pctl(Sys->NEWPGRP, nil);\n");
    sys->fprint(cg.output, "    tkclient->init();\n\n");

    # Get app properties
    title := "Application";
    width := 400;
    height := 300;
    bg := "#191919";

    if (prog.app != nil && prog.app.props != nil) {
        t := get_string_prop(prog.app.props, "title");
        if (t != nil)
            title = t;

        bg = get_string_prop(prog.app.props, "background");
        if (bg == nil)
            bg = get_string_prop(prog.app.props, "backgroundColor");
        if (bg == nil)
            bg = "#191919";

        (w, ok) := get_number_prop(prog.app.props, "width");
        if (ok)
            width = w;

        (h, ok2) := get_number_prop(prog.app.props, "height");
        if (ok2)
            height = h;
    }

    # Store width and height in Codegen for later use
    cg.width = width;
    cg.height = height;

    sys->fprint(cg.output, "    (toplevel, wmctl) := tkclient->toplevel(ctxt, \"\", \"%s\", 0);\n", title);
    sys->fprint(cg.output, "    tk->cmd(toplevel, \"wm geometry . %dx%d\");\n", width, height);
    sys->fprint(cg.output, "    tk->cmd(toplevel, \"configure -background %s\");\n", bg);
    sys->fprint(cg.output, "\n");

    # Create command channel if we have callbacks
    has_callbacks := (cg.callbacks != nil);

    if (has_callbacks) {
        sys->fprint(cg.output, "    cmd := chan of string;\n");
        sys->fprint(cg.output, "    tk->namechan(toplevel, cmd, \"cmd\");\n\n");
    }

    # Execute tk commands
    sys->fprint(cg.output, "    for (i := 0; i < len tkcmds; i++)\n");
    sys->fprint(cg.output, "        tk->cmd(toplevel, tkcmds[i]);\n\n");

    # Setup reactive timer if we have reactive functions
    has_reactive := has_reactive_functions(prog);
    if (has_reactive) {
        sys->fprint(cg.output, "    tick := chan of int;\n");
        sys->fprint(cg.output, "    spawn reactive_timer(tick);\n\n");

        # Call initial reactive update
        rfns := prog.reactive_fns;
        while (rfns != nil) {
            sys->fprint(cg.output, "    %s_update();\n", rfns.name);
            rfns = rfns.next;
        }
        sys->fprint(cg.output, "\n");
    }

    # Show window
    sys->fprint(cg.output, "    tkclient->onscreen(toplevel, nil);\n");
    sys->fprint(cg.output, "    tkclient->startinput(toplevel, \"kbd\"::\"ptr\"::nil);\n\n");

    if (has_callbacks) {
        sys->fprint(cg.output, "    for(;;) {\n");
        sys->fprint(cg.output, "        alt {\n");
        sys->fprint(cg.output, "        s := <-toplevel.ctxt.kbd =>\n");
        sys->fprint(cg.output, "            tk->keyboard(toplevel, s);\n");
        sys->fprint(cg.output, "        s := <-toplevel.ctxt.ptr =>\n");
        sys->fprint(cg.output, "            tk->pointer(toplevel, *s);\n");
        sys->fprint(cg.output, "        c := <-toplevel.ctxt.ctl or\n");
        sys->fprint(cg.output, "        c = <-toplevel.wreq or\n");
        sys->fprint(cg.output, "        c = <-wmctl =>\n");
        sys->fprint(cg.output, "            tkclient->wmctl(toplevel, c);\n");
        sys->fprint(cg.output, "        s := <-cmd =>\n");

        # Generate callback cases
        cbs := cg.callbacks;
        while (cbs != nil) {
            (name, event) := hd cbs;
            sys->fprint(cg.output, "            if(s == \"%s\")\n", name);
            sys->fprint(cg.output, "                %s();\n", name);
            cbs = tl cbs;
        }

        # Add tick case for reactive functions
        if (has_reactive) {
            sys->fprint(cg.output, "        <-tick =>\n");
            rfns := prog.reactive_fns;
            while (rfns != nil) {
                sys->fprint(cg.output, "            %s_update();\n", rfns.name);
                rfns = rfns.next;
            }
        }

        sys->fprint(cg.output, "        }\n");
        sys->fprint(cg.output, "    }\n");
    } else {
        sys->fprint(cg.output, "    for(;;) {\n");
        sys->fprint(cg.output, "        alt {\n");
        sys->fprint(cg.output, "        s := <-toplevel.ctxt.kbd =>\n");
        sys->fprint(cg.output, "            tk->keyboard(toplevel, s);\n");
        sys->fprint(cg.output, "        s := <-toplevel.ctxt.ptr =>\n");
        sys->fprint(cg.output, "            tk->pointer(toplevel, *s);\n");
        sys->fprint(cg.output, "        c := <-toplevel.ctxt.ctl or\n");
        sys->fprint(cg.output, "        c = <-toplevel.wreq or\n");
        sys->fprint(cg.output, "        c = <-wmctl =>\n");
        sys->fprint(cg.output, "            tkclient->wmctl(toplevel, c);\n");

        # Add tick case for reactive functions
        if (has_reactive) {
            sys->fprint(cg.output, "        <-tick =>\n");
            rfns := prog.reactive_fns;
            while (rfns != nil) {
                sys->fprint(cg.output, "            %s_update();\n", rfns.name);
                rfns = rfns.next;
            }
        }

        sys->fprint(cg.output, "        }\n");
        sys->fprint(cg.output, "    }\n");
    }

    sys->fprint(cg.output, "}\n");

    return nil;
}

# Main generation function
generate(output: string, prog: ref Program, module_name: string): string
{
    if (prog == nil)
        return "nil program";

    if (output == nil || output == "")
        return "nil output path";

    # Open output file
    fd := sys->create(output, Sys->OWRITE, 8r666);
    if (fd == nil)
        return sys->sprint("cannot create output file: %s", output);

    cg := Codegen.create(fd, module_name);

    # Generate code
    err := generate_prologue(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    # Generate reactive functions before code blocks (so they're available)
    err = generate_reactive_functions(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    err = generate_code_blocks(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    # Generate reactive timer after code blocks
    err = generate_reactive_timer(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    err = collect_widget_commands(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    err = generate_tkcmds_array(cg);
    if (err != nil) {
        fd = nil;
        return err;
    }

    err = generate_init(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    fd = nil;

    return nil;
}

# =========================================================================
# Main entry point
# =========================================================================

# Show usage message
show_usage()
{
    sys->fprint(sys->fildes(2), "Usage: kryon [-o output] input.kry\n");
    sys->fprint(sys->fildes(2), "\nOptions:\n");
    sys->fprint(sys->fildes(2), "  -o <output>  Specify output file (default: input.b)\n");
    sys->fprint(sys->fildes(2), "  -h           Show this help message\n");
    sys->fprint(sys->fildes(2), "\nExamples:\n");
    sys->fprint(sys->fildes(2), "  kryon input.kry           Generate input.b\n");
    sys->fprint(sys->fildes(2), "  kryon -o out.b in.kry    Generate to out.b\n");
}

# Derive module name from input file
derive_module_name(input_file: string): string
{
    if (input_file == nil)
        return "Module";

    # Find basename
    basename := input_file;
    for (i := len input_file - 1; i >= 0; i--) {
        if (input_file[i] == '/') {
            basename = input_file[i+1:];
            break;
        }
    }

    # Remove extension
    module_name := basename;
    dot := len module_name - 1;

    while (dot >= 0 && module_name[dot] != '.')
        dot--;

    if (dot > 0)
        module_name = module_name[0:dot];

    # Capitalize first letter
    if (len module_name > 0) {
        first := module_name[0];
        if (first >= 'a' && first <= 'z') {
            # Capitalize
            c := first - ('a' - 'A');
            module_name = sys->sprint("%c", c) + module_name[1:];
        }
    }

    return module_name;
}

# Derive output filename from input
derive_output_file(input_file: string): string
{
    if (input_file == nil)
        return nil;

    output := input_file;
    dot := len output - 1;

    while (dot >= 0 && output[dot] != '.')
        dot--;

    if (dot > 0)
        output = output[0:dot] + ".b";
    else
        output = output + ".b";

    return output;
}

# Read entire file into string
read_file(path: string): (string, string)
{
    iobuf := bufio->open(path, bufio->OREAD);
    if (iobuf == nil)
        return (nil, sys->sprint("cannot open file: %s: %r", path));

    # Read all lines and join them
    data := "";
    while ((s := iobuf.gets('\n')) != nil) {
        data += s;
    }

    iobuf.close();
    return (data, nil);
}

# Parse command line arguments
parse_args(argv: list of string): (string, string, string)
{
    input_file := "";
    output_file := "";

    # Skip program name
    args := tl argv;

    while (args != nil) {
        arg := hd args;
        args = tl args;

        if (arg == "-o") {
            if (args == nil)
                return (nil, nil, "missing argument for -o");

            output_file = hd args;
            args = tl args;
        } else if (arg == "-h" || arg == "--help") {
            show_usage();
            raise "success:help";
        } else if (arg[0] == '-') {
            return (nil, nil, "unknown option: " + arg);
        } else {
            if (input_file != nil && input_file != "")
                return (nil, nil, "multiple input files specified");

            input_file = arg;
        }
    }

    if (input_file == nil || input_file == "")
        return (nil, nil, "no input file specified");

    # Derive output file if not specified
    if (output_file == nil || output_file == "")
        output_file = derive_output_file(input_file);

    return (input_file, output_file, nil);
}

init(ctxt: ref Draw->Context, argv: list of string)
{
    sys = load Sys Sys->PATH;
    bufio = load Bufio Bufio->PATH;

    # Load dependent modules (use dis file paths)
    ast = load Ast "/dis/ast.dis";
    lexer = load Lexer "/dis/lexer.dis";

    # Parse arguments
    (input, output, err) := parse_args(argv);

    if (err != nil) {
        if (err == "success:help")
            return;

        sys->fprint(sys->fildes(2), "Error: %s\n", err);
        show_usage();
        raise "fail:args";
    }

    sys->print("Parsing %s...\n", input);

    # Read input file
    (contents, read_err) := read_file(input);
    if (read_err != nil) {
        sys->fprint(sys->fildes(2), "Error: %s\n", read_err);
        raise "fail:read";
    }

    # Create lexer
    l := lexer->create(input, contents);

    # Create parser
    p := Parser.create(l);

    # Parse
    (prog, parse_err) := parse_program(p);

    if (parse_err != nil) {
        sys->fprint(sys->fildes(2), "Parse error: %s\n", parse_err);
        raise "fail:parse";
    }

    # Derive module name
    module_name := derive_module_name(input);

    sys->print("Generating %s from %s...\n", output, input);

    # Generate code
    gen_err := generate(output, prog, module_name);

    if (gen_err != nil) {
        sys->fprint(sys->fildes(2), "Code generation error: %s\n", gen_err);
        raise "fail:codegen";
    }

    sys->print("Successfully generated %s\n", output);
}
