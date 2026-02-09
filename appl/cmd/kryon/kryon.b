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
include "ast.m";
    ast: Ast;
include "lexer.m";
    lexer: Lexer;

# Import useful types from ast
Program, Widget, Property, Value, ReactiveFunction, ModuleImport, SymbolTable, StructField, StructDecl: import ast;

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
    is_draw_backend: int;    # 1 if using Draw/wmclient
    ondraw_fn: string;        # name of onDraw function
    ondraw_interval: int;     # timer interval in ms
    oninit_fn: string;        # name of onInit function

    create: fn(output: ref Sys->FD, module_name: string): ref Codegen;
};

Codegen.create(output: ref Sys->FD, module_name: string): ref Codegen
{
    return ref Codegen(module_name, output, nil, 0, nil, 0, 0, nil, 0, "", 0, "");
}

# Module info for code generation
Module: adt {
    mod_file: string;  # module file name (e.g., "sys", "draw")
    var_name: string;  # variable name (e.g., "sys", "draw")
    type_name: string; # type name (e.g., "Sys", "Draw")
};

# =========================================================================
# Parser functions
# =========================================================================

# Format error message with line number
fmt_error(p: ref Parser, msg: string): string
{
    lineno := lexer->get_lineno(p.l);
    return sys->sprint("line %d: %s", lineno, msg);
}

# Determine if we should add a space between current and next token
should_add_space(curr_toktype: int, next_toktype: int): int
{
    # No space after opening delimiters
    if (curr_toktype == '(' || curr_toktype == '[' || curr_toktype == '{' ||
        curr_toktype == ':')
        return 0;

    # No space before closing delimiters or separators
    if (next_toktype == ')' || next_toktype == ']' || next_toktype == '}' ||
        next_toktype == ',' || next_toktype == ';' || next_toktype == '.' ||
        next_toktype == ':' || next_toktype == '[')
        return 0;

    # No space around the arrow operator
    if (curr_toktype == Lexer->TOKEN_ARROW || next_toktype == Lexer->TOKEN_ARROW)
        return 0;

    # No space before opening parenthesis (function calls)
    if (next_toktype == '(')
        return 0;

    # No space after dot operator
    if (curr_toktype == '.')
        return 0;

    # No space around compound operators (+=, -=, ==, !=, <=, >=, ++, --, *=, /=, %=)
    if (is_compound_operator(curr_toktype) || is_compound_operator(next_toktype))
        return 0;

    # Default: add space for keywords and identifiers
    return 1;
}

# Check if token type is a compound operator
is_compound_operator(toktype: int): int
{
    if (toktype == '+' + 256 || toktype == '-' + 256 || toktype == '=' + 256 ||
        toktype == '!' + 256 || toktype == '<' + 256 || toktype == '>' + 256 ||
        toktype == '+' + 512 || toktype == '-' + 512 ||
        toktype == '*' + 256 || toktype == '/' + 256 || toktype == '%' + 256 ||
        toktype == ':' + 256)
        return 1;
    return 0;
}

# Convert token type to string for function bodies
token_to_string(tok: ref Token): string
{
    tt := tok.toktype;

    if (tt == Lexer->TOKEN_VAR)
        return "var";
    if (tt == Lexer->TOKEN_FN)
        return "fn";
    if (tt == Lexer->TOKEN_WINDOW)
        return "Window";
    if (tt == Lexer->TOKEN_FRAME)
        return "Frame";
    if (tt == Lexer->TOKEN_BUTTON)
        return "Button";
    if (tt == Lexer->TOKEN_LABEL)
        return "Label";
    if (tt == Lexer->TOKEN_ENTRY)
        return "Entry";
    if (tt == Lexer->TOKEN_CHECKBUTTON)
        return "Checkbutton";
    if (tt == Lexer->TOKEN_RADIOBUTTON)
        return "Radiobutton";
    if (tt == Lexer->TOKEN_LISTBOX)
        return "Listbox";
    if (tt == Lexer->TOKEN_CANVAS)
        return "Canvas";
    if (tt == Lexer->TOKEN_SCALE)
        return "Scale";
    if (tt == Lexer->TOKEN_MENUBUTTON)
        return "Menubutton";
    if (tt == Lexer->TOKEN_MESSAGE)
        return "Message";
    if (tt == Lexer->TOKEN_COLUMN)
        return "Column";
    if (tt == Lexer->TOKEN_ROW)
        return "Row";
    if (tt == Lexer->TOKEN_CENTER)
        return "Center";
    if (tt == Lexer->TOKEN_TYPE)
        return "type";
    if (tt == Lexer->TOKEN_STRUCT)
        return "struct";
    if (tt == Lexer->TOKEN_CHAN)
        return "chan";
    if (tt == Lexer->TOKEN_SPAWN)
        return "spawn";
    if (tt == Lexer->TOKEN_OF)
        return "of";
    if (tt == Lexer->TOKEN_ARRAY)
        return "array";
    if (tt == Lexer->TOKEN_IF)
        return "if";
    if (tt == Lexer->TOKEN_ELSE)
        return "else";
    if (tt == Lexer->TOKEN_FOR)
        return "for";
    if (tt == Lexer->TOKEN_WHILE)
        return "while";
    if (tt == Lexer->TOKEN_RETURN)
        return "return";
    if (tt == Lexer->TOKEN_IN)
        return "in";
    if (tt == '+' + 256)
        return "+=";
    if (tt == '-' + 256)
        return "-=";
    if (tt == '=' + 256)
        return "==";
    if (tt == '!' + 256)
        return "!=";
    if (tt == '<' + 256)
        return "<=";
    if (tt == '>' + 256)
        return ">=";
    if (tt == '+' + 512)
        return "++";
    if (tt == '-' + 512)
        return "--";
    if (tt == '*' + 256)
        return "*=";
    if (tt == '/' + 256)
        return "/=";
    if (tt == '%' + 256)
        return "%=";

    return "";
}

# Parse a use statement: use module_name [alias]
parse_use_statement(p: ref Parser): (ref ModuleImport, string)
{
    # Expect "use" keyword
    (use_tok, err1) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err1 != nil) {
        return (nil, err1);
    }
    if (use_tok.string_val != "use") {
        return (nil, fmt_error(p, "expected 'use' keyword"));
    }

    # Expect module name
    (module_tok, err2) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err2 != nil) {
        return (nil, err2);
    }
    module_name := module_tok.string_val;

    # Require ';' after use statement
    tok := p.peek();
    if (tok.toktype != ';') {
        return (nil, fmt_error(p, "use statement must end with semicolon"));
    }
    p.next();  # consume ';'

    return (ast->moduleimport_create(module_name, ""), nil);
}

# Parse a reactive function declaration: name: fn() = expression @ N
# OR: name: fn() = expression @ varname
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

    # Parse expression until "@"
    expr := "";
    while (p.peek().toktype != Lexer->TOKEN_AT) {
        tok := p.next();

        # Build expression from tokens
        if (tok.toktype == Lexer->TOKEN_STRING) {
            expr += "\"" + tok.string_val + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            expr += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            expr += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            expr += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            # Single char token
            expr += sys->sprint("%c", tok.toktype);
        }

        # Add space for next token (with proper spacing rules)
        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_AT &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            expr += " ";
        }
    }

    # Expect "@"
    (tok5, err7) := p.expect(Lexer->TOKEN_AT);
    if (err7 != nil) {
        return (nil, err7);
    }

    # Check what follows @
    next_tok := p.peek();

    if (next_tok.toktype == Lexer->TOKEN_NUMBER) {
        # Time-based: @ 1000
        p.next();
        interval := int next_tok.number_val;
        return (ast->reactivefn_create(name, expr, interval, nil), nil);
    } else if (next_tok.toktype == Lexer->TOKEN_IDENTIFIER) {
        # Var-based: @ var1, var2
        watch_vars: ref Ast->WatchVar = nil;
        while (p.peek().toktype == Lexer->TOKEN_IDENTIFIER) {
            var_tok := p.next();
            wv := ast->watchvar_create(var_tok.string_val);
            watch_vars = ast->watchvar_list_add(watch_vars, wv);

            # Check for comma
            if (p.peek().toktype == ',')
                p.next();
        }
        return (ast->reactivefn_create(name, expr, 0, watch_vars), nil);
    }

    return (nil, fmt_error(p, "expected number or identifier after '@'"));
}

# Parse a reactive function after already consuming NAME and ':'
parse_reactive_function_after_colon(p: ref Parser, name: string): (ref ReactiveFunction, string)
{
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

    # Parse expression until "@"
    expr := "";
    while (p.peek().toktype != Lexer->TOKEN_AT) {
        tok := p.next();

        # Build expression from tokens
        if (tok.toktype == Lexer->TOKEN_STRING) {
            expr += "\"" + tok.string_val + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            expr += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            expr += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            expr += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            # Single char token
            expr += sys->sprint("%c", tok.toktype);
        }

        # Add space for next token (with proper spacing rules)
        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_AT &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            expr += " ";
        }
    }

    # Expect "@"
    (tok5, err7) := p.expect(Lexer->TOKEN_AT);
    if (err7 != nil) {
        return (nil, err7);
    }

    # Check what follows @
    next_tok := p.peek();

    if (next_tok.toktype == Lexer->TOKEN_NUMBER) {
        # Time-based: @ 1000
        p.next();
        interval := int next_tok.number_val;
        return (ast->reactivefn_create(name, expr, interval, nil), nil);
    } else if (next_tok.toktype == Lexer->TOKEN_IDENTIFIER) {
        # Var-based: @ var1, var2
        watch_vars: ref Ast->WatchVar = nil;
        while (p.peek().toktype == Lexer->TOKEN_IDENTIFIER) {
            var_tok := p.next();
            wv := ast->watchvar_create(var_tok.string_val);
            watch_vars = ast->watchvar_list_add(watch_vars, wv);

            # Check for comma
            if (p.peek().toktype == ',')
                p.next();
        }
        return (ast->reactivefn_create(name, expr, 0, watch_vars), nil);
    }

    return (nil, fmt_error(p, "expected number or identifier after '@'"));
}

# Parse a constant declaration: const NAME = value
# 'const' already consumed, we parse NAME = value
parse_const_decl(p: ref Parser): (ref Ast->ConstDecl, string)
{
    # Expect constant name
    (name_tok, err1) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err1 != nil) {
        return (nil, err1);
    }
    name := name_tok.string_val;

    # Expect "="
    (eq_tok, err2) := p.expect('=');
    if (err2 != nil) {
        return (nil, fmt_error(p, "expected '=' after constant name"));
    }

    # Parse value until semicolon (required)
    value := "";

    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.peek();

        # Stop at semicolon (required)
        if (tok.toktype == ';') {
            p.next();  # consume the semicolon
            break;
        }

        # Stop at any keyword (signals end of const declaration without semicolon)
        if (tok.toktype >= Lexer->TOKEN_VAR && tok.toktype <= Lexer->TOKEN_IN) {
            return (nil, fmt_error(p, "const declaration must end with semicolon"));
        }

        # Stop at widget type keywords
        if (tok.toktype >= Lexer->TOKEN_WINDOW && tok.toktype <= Lexer->TOKEN_IMG) {
            return (nil, fmt_error(p, "const declaration must end with semicolon"));
        }

        tok = p.next();  # actually consume the token

        # Build value from tokens
        if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            value += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            value += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            value += sys->sprint("%g", tok.real_val);
        } else if (tok.toktype == '(' || tok.toktype == ')' ||
                   tok.toktype == '[' || tok.toktype == ']' ||
                   tok.toktype == '{' || tok.toktype == '}' ||
                   tok.toktype == ',' || tok.toktype == '.' ||
                   tok.toktype == '+' || tok.toktype == '-' ||
                   tok.toktype == '*' || tok.toktype == '/' ||
                   tok.toktype == '=') {
            value += sys->sprint("%c", tok.toktype);
        }
    }

    if (len value == 0) {
        return (nil, fmt_error(p, "expected value after '='"));
    }

    return (ast->constdecl_create(name, value), nil);
}

# Parse a struct declaration: struct Name { field: type ... }
# 'struct' already consumed
parse_struct_decl(p: ref Parser): (ref StructDecl, string)
{
    # Expect struct name
    (name_tok, err1) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err1 != nil) {
        return (nil, fmt_error(p, "expected struct name after 'struct'"));
    }
    name := name_tok.string_val;

    # Expect '{'
    (lbrace, err3) := p.expect('{');
    if (err3 != nil) {
        return (nil, err3);
    }

    decl := ast->structdecl_create(name);
    fields: ref StructField = nil;

    # Parse fields
    while (p.peek().toktype != '}') {
        # Expect field name
        (field_name_tok, err4) := p.expect(Lexer->TOKEN_IDENTIFIER);
        if (err4 != nil) {
            return (nil, fmt_error(p, "expected field name or '}'"));
        }

        # Expect ':'
        (colon, err5) := p.expect(':');
        if (err5 != nil) {
            return (nil, fmt_error(p, "expected ':' after field name"));
        }

        # Parse type (handle Type[] syntax for arrays)
        type_str := "";
        while (p.peek().toktype != ';' && p.peek().toktype != '}') {
            tok := p.next();
            if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                type_str += tok.string_val;
            } else if (tok.toktype == '[') {
                # Array syntax Type[] - convert to "array of Type"
                # Check if next is ']'
                if (p.peek().toktype == ']') {
                    p.next();  # consume ']'
                    # type_str currently has the base type, need to prepend "array of "
                    type_str = "array of " + type_str;
                } else {
                    type_str += "[";
                }
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                type_str += sys->sprint("%c", tok.toktype);
            }

            # Add space between tokens if needed
            if (p.peek().toktype != ';' && p.peek().toktype != '}' &&
                p.peek().toktype != ']' && p.peek().toktype != '[') {
                peek_tok := p.peek();
                if (should_add_space(tok.toktype, peek_tok.toktype))
                    type_str += " ";
            }
        }

        # Add field
        field := ast->structfield_create(field_name_tok.string_val, type_str);
        if (fields == nil) {
            fields = field;
        } else {
            ast->structfield_list_add(fields, field);
        }

        # Require ';' after struct field
        tok := p.peek();
        if (tok.toktype != ';') {
            return (nil, fmt_error(p, "struct field must end with semicolon"));
        }
        p.next();  # consume ';'
    }

    decl.fields = fields;

    # Expect '}'
    (rbrace, err6) := p.expect('}');
    if (err6 != nil) {
        return (nil, err6);
    }

    # Require ';' after struct declaration
    tok := p.peek();
    if (tok.toktype != ';') {
        return (nil, fmt_error(p, "struct declaration must end with semicolon"));
    }
    p.next();  # consume ';'

    return (decl, nil);
}

# Parse a var declaration: var name = expr
parse_var_decl(p: ref Parser): (ref Ast->VarDecl, string)
{
    # Expect: var name = expr
    # Already have 'var' token
    name_tok := p.next();
    if (name_tok.toktype != Lexer->TOKEN_IDENTIFIER)
        return (nil, fmt_error(p, "expected variable name after 'var'"));

    name := name_tok.string_val;

    # Check for ':' (typed declaration) or '=' (initializer)
    next_tok := p.peek();
    if (next_tok.toktype == ':') {
        # Typed declaration: var name: type [= value]
        p.next();  # consume ':'

        # Parse type (could be "ref Image", "int", "string", "ref Image[]", etc.)
        # Stop at semicolon, '=', or any keyword (fn, var, Window, etc.)
        type_str := "";
        while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
               p.peek().toktype != ';' &&
               p.peek().toktype != '=') {
            tok := p.peek();
            # Stop if we hit a keyword (these signal end of type declaration)
            if (tok.toktype >= Lexer->TOKEN_VAR && tok.toktype <= Lexer->TOKEN_CONST)
                break;
            if (tok.toktype == Lexer->TOKEN_AT || tok.toktype == Lexer->TOKEN_ARROW)
                break;

            p.next();  # consume the token

            # Handle array/list syntax Type[] -> generates "list of Type"
            if (tok.toktype == '[') {
                # Check if next is ']'
                if (p.peek().toktype == ']') {
                    p.next();  # consume ']'
                    # type_str currently has the base type, convert to "list of Type"
                    type_str = "list of " + type_str;
                } else {
                    type_str += "[";
                }
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                type_str += tok.string_val;
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                type_str += sys->sprint("%c", tok.toktype);
            }
            # Add space between tokens if needed
            if (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
                p.peek().toktype != ';' &&
                p.peek().toktype != '=') {
                peek_tok := p.peek();
                # Stop at keywords
                if (peek_tok.toktype >= Lexer->TOKEN_VAR && peek_tok.toktype <= Lexer->TOKEN_CONST)
                    break;
                if (peek_tok.toktype == Lexer->TOKEN_AT || peek_tok.toktype == Lexer->TOKEN_ARROW)
                    break;
                if (should_add_space(tok.toktype, peek_tok.toktype))
                    type_str += " ";
            }
        }

        # Convert Kryon *Type syntax to Limbo ref Type syntax
        type_str = kryon_type_to_limbo(type_str);

        # Check for optional initialization: = value
        init_expr := "";
        if (p.peek().toktype == '=') {
            p.next();  # consume '='

            # Parse initialization value
            while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
                   p.peek().toktype != ';' &&
                   p.peek().toktype != '\n') {
                # Stop if we encounter a keyword (signals end of value)
                peek_tok := p.peek();
                if (peek_tok.toktype >= Lexer->TOKEN_VAR && peek_tok.toktype <= Lexer->TOKEN_CONST)
                    break;

                tok := p.next();
                if (tok.toktype == Lexer->TOKEN_STRING) {
                    init_expr += "\"" + limbo_escape(tok.string_val) + "\"";
                } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                    init_expr += tok.string_val;
                } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                    init_expr += sys->sprint("%bd", tok.number_val);
                } else if (tok.toktype == Lexer->TOKEN_REAL) {
                    if (tok.real_val == real (big tok.real_val)) {
                        init_expr += sys->sprint("%bd.0", big tok.real_val);
                    } else {
                        init_expr += sys->sprint("%g", tok.real_val);
                    }
                } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                    init_expr += "->";
                } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                    init_expr += sys->sprint("%c", tok.toktype);
                }

                next_tok := p.peek();
                if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                    next_tok.toktype != ';' &&
                    next_tok.toktype != '\n' &&
                    should_add_space(tok.toktype, next_tok.toktype)) {
                    init_expr += " ";
                }
            }
        }

        # Require ';' after variable declaration
        tok := p.peek();
        if (tok.toktype != ';') {
            return (nil, fmt_error(p, "variable declaration must end with semicolon"));
        }
        p.next();  # consume ';'

        return (ast->var_decl_create(name, type_str, init_expr, nil), nil);
    }

    # Expect '=' (initializer style: var name = expr)
    (eq_tok, err) := p.expect('=');
    if (err != nil)
        return (nil, err);

    # Parse initialization expression
    init_expr := "";
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != '\n') {
        tok := p.next();
        if (tok.toktype == Lexer->TOKEN_STRING) {
            init_expr += "\"" + tok.string_val + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            init_expr += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            init_expr += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            # Preserve decimal point for whole real numbers like 180.0
            if (tok.real_val == real (big tok.real_val)) {
                init_expr += sys->sprint("%bd.0", big tok.real_val);
            } else {
                init_expr += sys->sprint("%g", tok.real_val);
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            init_expr += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            init_expr += sys->sprint("%c", tok.toktype);
        }
        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != '\n' &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            init_expr += " ";
        }
    }

    return (ast->var_decl_create(name, "string", init_expr, nil), nil);
}

# =========================================================================
# Statement parsing functions
# =========================================================================

# Parse a statement - dispatcher for different statement types
parse_statement(p: ref Parser): (ref Ast->Statement, string)
{
    tok := p.peek();
    lineno := tok.lineno;

    # Check based on next token type
    if (tok.toktype == Lexer->TOKEN_VAR) {
        return parse_var_stmt(p);
    }
    if (tok.toktype == Lexer->TOKEN_IF) {
        return parse_if_stmt(p);
    }
    if (tok.toktype == Lexer->TOKEN_FOR) {
        return parse_for_stmt(p);
    }
    if (tok.toktype == Lexer->TOKEN_WHILE) {
        return parse_while_stmt(p);
    }
    if (tok.toktype == Lexer->TOKEN_RETURN) {
        return parse_return_stmt(p);
    }
    if (tok.toktype == '{') {
        return parse_block(p);
    }

    # Check for local variable declaration: name : type or name := value
    if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
        next := lexer->peek_token(p.l);
        if (next != nil && (next.toktype == ':' || next.toktype == ':' + 256)) {
            return parse_local_decl(p);
        }
    }

    # Default: expression statement
    return parse_expr_stmt(p);
}

# Parse a variable declaration statement: var name: type = value;
parse_var_stmt(p: ref Parser): (ref Ast->Statement, string)
{
    (stmt, err) := parse_var_stmt_internal(p, 1);
    return (stmt, err);
}

# Parse a variable declaration without requiring semicolon (for for-loop init)
parse_var_stmt_no_semi(p: ref Parser): (ref Ast->Statement, string)
{
    (stmt, err) := parse_var_stmt_internal(p, 0);
    return (stmt, err);
}

# Internal function to parse var declaration
# require_semi: 1 to require semicolon, 0 to not require it
parse_var_stmt_internal(p: ref Parser, require_semi: int): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect 'var'
    (var_tok, err1) := p.expect(Lexer->TOKEN_VAR);
    if (err1 != nil)
        return (nil, err1);

    # Expect variable name
    (name_tok, err2) := p.expect(Lexer->TOKEN_IDENTIFIER);
    if (err2 != nil)
        return (nil, err2);

    name := name_tok.string_val;

    # Expect ':'
    (colon_tok, err3) := p.expect(':');
    if (err3 != nil)
        return (nil, err3);

    # Parse type (could include -> for ref types like daytime->Tm)
    # Read until '=', ';', or newline
    typ := "";
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != '=' &&
           p.peek().toktype != ';' &&
           p.peek().toktype != '\n') {
        tok := p.next();

        if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            typ += tok.string_val;
        } else if (tok.toktype == '[') {
            # Array syntax Type[] - convert to "array of Type"
            if (p.peek().toktype == ']') {
                p.next();  # consume ']'
                typ = "array of " + typ;
            } else {
                typ += "[";
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            typ += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            typ += sys->sprint("%c", tok.toktype);
        }

        # Add space between tokens if needed
        if (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
            p.peek().toktype != '=' &&
            p.peek().toktype != ';' &&
            p.peek().toktype != '\n') {
            peek_tok := p.peek();
            if (should_add_space(tok.toktype, peek_tok.toktype))
                typ += " ";
        }
    }

    # Convert Kryon *Type syntax to Limbo ref Type syntax
    typ = kryon_type_to_limbo(typ);

    # Check for initialization
    init_expr := "";
    if (p.peek().toktype == '=') {
        p.next();  # consume '='

        # Parse initialization expression until ';' or newline
        while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
               p.peek().toktype != ';' && p.peek().toktype != '\n') {
            tok := p.next();

            if (tok.toktype == Lexer->TOKEN_STRING) {
                init_expr += "\"" + limbo_escape(tok.string_val) + "\"";
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                init_expr += tok.string_val;
            } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                init_expr += sys->sprint("%bd", tok.number_val);
            } else if (tok.toktype == Lexer->TOKEN_REAL) {
                if (tok.real_val == real (big tok.real_val)) {
                    init_expr += sys->sprint("%bd.0", big tok.real_val);
                } else {
                    init_expr += sys->sprint("%g", tok.real_val);
                }
            } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                init_expr += "->";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                init_expr += sys->sprint("%c", tok.toktype);
            }

            # Add space for next token
            next_tok := p.peek();
            if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                next_tok.toktype != ';' && next_tok.toktype != '\n' &&
                should_add_space(tok.toktype, next_tok.toktype)) {
                init_expr += " ";
            }
        }
    }

    # Optionally require ';' after local variable declaration
    if (require_semi) {
        tok := p.peek();
        if (tok.toktype != ';') {
            return (nil, fmt_error(p, "local variable declaration must end with semicolon"));
        }
        p.next();
    }

    var_decl := ast->var_decl_create(name, typ, init_expr, nil);
    return (ast->statement_create_vardecl(lineno, var_decl), nil);
}

# Parse a local variable declaration inside a function body:
#   name: type [= value]   - typed declaration
#   name := value          - type-inferred declaration
# This version expects the identifier token to already be consumed
parse_local_decl_internal(p: ref Parser, name: string, lineno: int): (ref Ast->Statement, string)
{
    # Check next token to determine declaration type
    next_tok := p.peek();

    if (next_tok.toktype == ':') {
        # Typed declaration: name: type [= value]
        p.next();  # consume ':'

        # Parse type (could be "int", "string", "ref Image", "list of int", etc.)
        type_str := "";
        while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
               p.peek().toktype != '=' &&
               p.peek().toktype != ';' &&
               p.peek().toktype != '\n') {
            tok := p.peek();
            # Stop at keywords
            if (tok.toktype >= Lexer->TOKEN_VAR && tok.toktype <= Lexer->TOKEN_CONST)
                break;
            if (tok.toktype == Lexer->TOKEN_AT || tok.toktype == Lexer->TOKEN_ARROW)
                break;

            p.next();  # consume the token

            # Handle array/list syntax Type[]
            if (tok.toktype == '[') {
                if (p.peek().toktype == ']') {
                    p.next();  # consume ']'
                    type_str = "array of " + type_str;
                } else {
                    type_str += "[";
                }
            } else if (tok.toktype == ']') {
                # Skip closing bracket if not consumed above
                ;
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                type_str += tok.string_val;
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                type_str += sys->sprint("%c", tok.toktype);
            }

            # Add space if needed
            if (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
                p.peek().toktype != '=' &&
                p.peek().toktype != ';' &&
                p.peek().toktype != '\n') {
                peek_tok := p.peek();
                if (peek_tok.toktype >= Lexer->TOKEN_VAR && peek_tok.toktype <= Lexer->TOKEN_CONST)
                    break;
                if (peek_tok.toktype == Lexer->TOKEN_AT || peek_tok.toktype == Lexer->TOKEN_ARROW)
                    break;
                if (should_add_space(tok.toktype, peek_tok.toktype))
                    type_str += " ";
            }
        }

        # Convert Kryon *Type syntax to Limbo ref Type syntax
        type_str = kryon_type_to_limbo(type_str);

        # Parse optional initialization: = value
        init_expr := "";
        if (p.peek().toktype == '=') {
            p.next();  # consume '='
            (val, _) := parse_init_value(p);
            init_expr = val;
        }

        # Require ';' after typed local variable declaration
        tok := p.peek();
        if (tok.toktype != ';') {
            return (nil, fmt_error(p, "local variable declaration must end with semicolon"));
        }
        p.next();  # consume ';'

        var_decl := ast->var_decl_create(name, type_str, init_expr, nil);
        return (ast->statement_create_vardecl(lineno, var_decl), nil);

    } else if (next_tok.toktype == ':' + 256) {  # := token
        # Type-inferred declaration: name := value
        p.next();  # consume ':='

        # Parse initialization value
        (init_val, _) := parse_init_value(p);

        # Infer type from init expression
        inferred_type := infer_type_from_expr(init_val);

        # Require ';' after type-inferred local variable declaration
        tok := p.peek();
        if (tok.toktype != ';') {
            return (nil, fmt_error(p, "local variable declaration must end with semicolon"));
        }
        p.next();  # consume ';'

        var_decl := ast->var_decl_create(name, inferred_type, init_val, nil);
        return (ast->statement_create_vardecl(lineno, var_decl), nil);
    }

    return (nil, fmt_error(p, "expected ':' or ':=' after variable name"));
}

# Parse a local variable declaration inside a function body:
#   name: type [= value]   - typed declaration
#   name := value          - type-inferred declaration
# This version consumes the identifier token
parse_local_decl(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect identifier (variable name)
    name_tok := p.next();
    if (name_tok.toktype != Lexer->TOKEN_IDENTIFIER)
        return (nil, fmt_error(p, "expected variable name"));

    return parse_local_decl_internal(p, name_tok.string_val, lineno);
}

# Parse initialization value until semicolon or newline
parse_init_value(p: ref Parser): (string, string)
{
    init_expr := "";
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != ';' &&
           p.peek().toktype != '\n') {
        tok := p.next();

        if (tok.toktype == Lexer->TOKEN_STRING) {
            init_expr += "\"" + limbo_escape(tok.string_val) + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            init_expr += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            init_expr += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            if (tok.real_val == real (big tok.real_val)) {
                init_expr += sys->sprint("%bd.0", big tok.real_val);
            } else {
                init_expr += sys->sprint("%g", tok.real_val);
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            init_expr += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            init_expr += sys->sprint("%c", tok.toktype);
        }

        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != ';' &&
            next_tok.toktype != '\n' &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            init_expr += " ";
        }
    }
    return (init_expr, nil);
}

# Infer type from an expression string
infer_type_from_expr(expr: string): string
{
    # Remove leading/trailing whitespace
    if (expr == nil || len expr == 0)
        return "string";  # default

    # Check for string literals
    if (expr[0] == '"')
        return "string";

    # Check for real numbers (contains decimal point or scientific notation)
    has_decimal := 0;
    for (i := 0; i < len expr; i++) {
        c := expr[i];
        if (c == '.') {
            has_decimal = 1;
            break;
        }
        if (c == 'e' && i + 1 < len expr && (expr[i + 1] == '+' || expr[i + 1] == '-')) {
            has_decimal = 1;
            break;
        }
    }
    if (has_decimal)
        return "real";

    # Check for function calls that return specific types by looking for patterns
    # Math->, ->sin, ->cos, ->sqrt, ->atan2 all indicate real
    has_arrow := 0;
    has_math := 0;
    for (i = 0; i < len expr; i++) {
        if (i < len expr - 1 && expr[i] == '-' && expr[i + 1] == '>')
            has_arrow = 1;
        if (i < len expr - 3 && expr[i] == 'M' && expr[i + 1] == 'a' &&
            expr[i + 2] == 't' && expr[i + 3] == 'h')
            has_math = 1;
    }
    if (has_arrow && (has_math || has_math_func(expr)))
        return "real";

    # Check for struct constructors: TypeName(...)
    # Look for identifier followed by '(' that's not a known function
    # Default to int for numeric literals
    return "int";
}

# Check if expression contains a math function name
has_math_func(expr: string): int
{
    funcs := array[] of {"sin", "cos", "tan", "sqrt", "atan2", "atan", "exp", "log", "pow"};
    i := 0;
    while (i < len funcs) {
        if (contains_word(expr, funcs[i]))
            return 1;
        i++;
    }
    return 0;
}

# Check if string contains a whole word (not as substring of another word)
contains_word(s: string, word: string): int
{
    word_len := len word;
    s_len := len s;
    i := 0;
    while (i <= s_len - word_len) {
        match := 1;
        j := 0;
        while (j < word_len) {
            if (s[i + j] != word[j]) {
                match = 0;
                break;
            }
            j++;
        }
        if (match != 0) {
            # Check character before and after to ensure it's a whole word
            before_ok := (i == 0) || (is_alnum(s[i - 1]) == 0);
            after_ok := (i + word_len >= s_len) || (is_alnum(s[i + word_len]) == 0);
            if (before_ok != 0 && after_ok != 0)
                return 1;
        }
        i++;
    }
    return 0;
}

# Check if character is alphanumeric
is_alnum(c: int): int
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return 1;
    return 0;
}

# Parse a block: { statements }
parse_block(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect '{'
    (lbrace, err1) := p.expect('{');
    if (err1 != nil)
        return (nil, err1);

    # Parse statements until '}'
    statements: ref Ast->Statement = nil;

    while (p.peek().toktype != '}' && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        # Skip empty statements (extra semicolons)
        if (p.peek().toktype == ';') {
            p.next();
            continue;
        }

        (stmt, err) := parse_statement(p);
        if (err != nil)
            return (nil, err);

        statements = ast->statement_list_add(statements, stmt);

        # Each statement parser consumes its own terminating semicolon
    }

    # Expect '}'
    (rbrace, err2) := p.expect('}');
    if (err2 != nil)
        return (nil, err2);

    return (ast->statement_create_block(lineno, statements), nil);
}

# Parse an if statement: if (condition) { ... } [else { ... }]
parse_if_stmt(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect 'if'
    (if_tok, err1) := p.expect(Lexer->TOKEN_IF);
    if (err1 != nil)
        return (nil, err1);

    # Expect '('
    (lparen, err2) := p.expect('(');
    if (err2 != nil)
        return (nil, err2);

    # Parse condition expression until ')'
    condition := "";
    paren_count := 1;
    while (paren_count > 0 && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.next();
        if (tok.toktype == '(')
            paren_count++;
        else if (tok.toktype == ')')
            paren_count--;

        if (paren_count > 0) {
            if (tok.toktype == Lexer->TOKEN_STRING) {
                condition += "\"" + limbo_escape(tok.string_val) + "\"";
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                condition += tok.string_val;
            } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                condition += sys->sprint("%bd", tok.number_val);
            } else if (tok.toktype == Lexer->TOKEN_REAL) {
                if (tok.real_val == real (big tok.real_val)) {
                    condition += sys->sprint("%bd.0", big tok.real_val);
                } else {
                    condition += sys->sprint("%g", tok.real_val);
                }
            } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                condition += "->";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                condition += sys->sprint("%c", tok.toktype);
            } else if (tok.toktype >= 256 && tok.toktype < 512) {
                # Two-character compound operator (==, !=, <=, >=, +=, -=, *=, /=, %=)
                c := tok.toktype - 256;
                condition += sys->sprint("%c", c);
                # Add second character based on first
                if (c == '+') condition += "=";
                else if (c == '-') condition += "=";
                else if (c == '=') condition += "=";
                else if (c == '!') condition += "=";
                else if (c == '<') condition += "=";
                else if (c == '>') condition += "=";
                else if (c == '*') condition += "=";
                else if (c == '/') condition += "=";
                else if (c == '%') condition += "=";
            } else if (tok.toktype >= 512) {
                # ++ or -- operator
                base := tok.toktype - 512;
                condition += sys->sprint("%c%c", base, base);
            }

            # Add space for next token
            next_tok := p.peek();
            if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                next_tok.toktype != ')' &&
                should_add_space(tok.toktype, next_tok.toktype)) {
                condition += " ";
            }
        }
    }

    # Parse then statement (block or single statement)
    then_stmt: ref Ast->Statement;
    err3: string;
    if (p.peek().toktype == '{') {
        (then_stmt, err3) = parse_block(p);
    } else {
        (then_stmt, err3) = parse_statement(p);
    }
    if (err3 != nil)
        return (nil, err3);

    # Check for else
    else_stmt: ref Ast->Statement = nil;
    if (p.peek().toktype == Lexer->TOKEN_ELSE) {
        p.next();  # consume 'else'

        err4: string;
        if (p.peek().toktype == '{') {
            (else_stmt, err4) = parse_block(p);
        } else {
            (else_stmt, err4) = parse_statement(p);
        }
        if (err4 != nil)
            return (nil, err4);
    }

    # No semicolon needed after if statement with block - it's a complete statement
    return (ast->statement_create_if(lineno, condition, then_stmt, else_stmt), nil);
}

# Parse a for loop:
#   - for-each: for (var in list) { ... }
#   - C-style: for (init; condition; increment) { ... }
#   - Limbo-style: for (var = list; var != nil; var = tl var) { ... }
parse_for_stmt(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect 'for'
    (for_tok, err1) := p.expect(Lexer->TOKEN_FOR);
    if (err1 != nil)
        return (nil, err1);

    # Expect '('
    (lparen, err2) := p.expect('(');
    if (err2 != nil)
        return (nil, err2);

    # Check for for-each syntax: for (var in list)
    # Look ahead to see if we have pattern: identifier 'in' expression
    is_for_each := 0;
    loop_var := "";
    list_expr := "";

    # Peek to see if we have a simple identifier (not 'var' keyword)
    if (p.peek().toktype == Lexer->TOKEN_IDENTIFIER) {
        # Save parser state to restore if not a for-each
        var_tok := p.peek();
        loop_var = var_tok.string_val;
        p.next();  # consume the variable name

        # Check if next token is 'in'
        if (p.peek().toktype == Lexer->TOKEN_IN) {
            is_for_each = 1;
            p.next();  # consume 'in'

            # Parse the list expression until ')'
            paren_count := 1;
            while (paren_count > 0 && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
                tok := p.next();
                if (tok.toktype == '(')
                    paren_count++;
                else if (tok.toktype == ')')
                    paren_count--;

                if (paren_count > 0) {
                    if (tok.toktype == Lexer->TOKEN_STRING) {
                        list_expr += "\"" + limbo_escape(tok.string_val) + "\"";
                    } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                        list_expr += tok.string_val;
                    } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                        list_expr += sys->sprint("%bd", tok.number_val);
                    } else if (tok.toktype == Lexer->TOKEN_REAL) {
                        if (tok.real_val == real (big tok.real_val)) {
                            list_expr += sys->sprint("%bd.0", big tok.real_val);
                        } else {
                            list_expr += sys->sprint("%g", tok.real_val);
                        }
                    } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                        list_expr += "->";
                    } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                        list_expr += sys->sprint("%c", tok.toktype);
                    }

                    next_tok := p.peek();
                    if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                        next_tok.toktype != ')' &&
                        should_add_space(tok.toktype, next_tok.toktype)) {
                        list_expr += " ";
                    }
                }
            }
        } else {
            # Not a for-each, put back the token (we can't really put back, so handle differently)
            # Fall through to regular for loop parsing
        }
    }

    if (is_for_each) {
        # Parse body (block or single statement)
        body: ref Ast->Statement;
        err6: string;
        if (p.peek().toktype == '{') {
            (body, err6) = parse_block(p);
        } else {
            (body, err6) = parse_statement(p);
        }
        if (err6 != nil)
            return (nil, err6);

        # Generate for-each as a traditional for loop
        # init: for (ls := list; ls != nil; ls = tl ls) { var := hd ls; ... }
        list_var_name := sys->sprint("ls__%s", loop_var);
        condition := sys->sprint("%s != nil", list_var_name);
        increment := sys->sprint("%s = tl %s", list_var_name, list_var_name);

        # Create a var decl statement for the list iterator (ls__var := list)
        # This ensures the variable is properly declared in the symbol table
        list_var_decl := ast->var_decl_create(list_var_name, "", list_expr, nil);
        list_var_stmt := ast->statement_create_vardecl(lineno, list_var_decl);

        # Create a var decl statement for the loop variable
        loop_var_decl := ast->var_decl_create(loop_var, "", "hd " + list_var_name, nil);
        loop_var_stmt := ast->statement_create_vardecl(lineno, loop_var_decl);

        # Prepend the loop var extraction to the body
        # Create a new block with loop_var_stmt first, then original body
        new_block := ast->statement_create_block(lineno, loop_var_stmt);
        loop_var_stmt.next = body;

        return (ast->statement_create_for(lineno, list_var_stmt,
                 condition, increment, new_block), nil);
    }

    # Regular for loop: for (init; condition; increment) { ... }
    # Parse init statement (could be var declaration or expression)
    init: ref Ast->Statement = nil;
    err3: string;
    if (p.peek().toktype == Lexer->TOKEN_VAR) {
        # Parse var declaration without requiring semicolon (for loop will provide it)
        (init, err3) = parse_var_stmt_no_semi(p);
    } else {
        # Parse expression until ';'
        init_expr := "";
        while (p.peek().toktype != ';' && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
            tok := p.next();

            if (tok.toktype == Lexer->TOKEN_STRING) {
                init_expr += "\"" + limbo_escape(tok.string_val) + "\"";
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                init_expr += tok.string_val;
            } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                init_expr += sys->sprint("%bd", tok.number_val);
            } else if (tok.toktype == Lexer->TOKEN_REAL) {
                if (tok.real_val == real (big tok.real_val)) {
                    init_expr += sys->sprint("%bd.0", big tok.real_val);
                } else {
                    init_expr += sys->sprint("%g", tok.real_val);
                }
            } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                init_expr += "->";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                init_expr += sys->sprint("%c", tok.toktype);
            }

            next_tok := p.peek();
            if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                next_tok.toktype != ';' &&
                should_add_space(tok.toktype, next_tok.toktype)) {
                init_expr += " ";
            }
        }
        if (len init_expr > 0)
            init = ast->statement_create_expr(lineno, init_expr);
    }

    if (err3 != nil)
        return (nil, err3);

    # Expect ';'
    (semi1, err4) := p.expect(';');
    if (err4 != nil)
        return (nil, err4);

    # Parse condition expression until ';'
    condition := "";
    while (p.peek().toktype != ';' && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.next();

        if (tok.toktype == Lexer->TOKEN_STRING) {
            condition += "\"" + limbo_escape(tok.string_val) + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            condition += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            condition += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            if (tok.real_val == real (big tok.real_val)) {
                condition += sys->sprint("%bd.0", big tok.real_val);
            } else {
                condition += sys->sprint("%g", tok.real_val);
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            condition += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            condition += sys->sprint("%c", tok.toktype);
        } else if (tok.toktype >= 256 && tok.toktype < 512) {
            # Two-character compound operator
            c := tok.toktype - 256;
            condition += sys->sprint("%c", c);
            if (c == '+') condition += "=";
            else if (c == '-') condition += "=";
            else if (c == '=') condition += "=";
            else if (c == '!') condition += "=";
            else if (c == '<') condition += "=";
            else if (c == '>') condition += "=";
            else if (c == '*') condition += "=";
            else if (c == '/') condition += "=";
            else if (c == '%') condition += "=";
        } else if (tok.toktype >= 512) {
            # ++ or -- operator
            base := tok.toktype - 512;
            condition += sys->sprint("%c%c", base, base);
        }

        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != ';' &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            condition += " ";
        }
    }

    # Expect ';'
    (semi2, err5) := p.expect(';');
    if (err5 != nil)
        return (nil, err5);

    # Parse increment expression until ')'
    increment := "";
    paren_count := 1;
    while (paren_count > 0 && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.next();
        if (tok.toktype == '(')
            paren_count++;
        else if (tok.toktype == ')')
            paren_count--;

        if (paren_count > 0) {
            if (tok.toktype == Lexer->TOKEN_STRING) {
                increment += "\"" + limbo_escape(tok.string_val) + "\"";
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                increment += tok.string_val;
            } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                increment += sys->sprint("%bd", tok.number_val);
            } else if (tok.toktype == Lexer->TOKEN_REAL) {
                if (tok.real_val == real (big tok.real_val)) {
                    increment += sys->sprint("%bd.0", big tok.real_val);
                } else {
                    increment += sys->sprint("%g", tok.real_val);
                }
            } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                increment += "->";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                increment += sys->sprint("%c", tok.toktype);
            } else if (tok.toktype >= 256 && tok.toktype < 512) {
                # Two-character compound operator (+=, -=, ==, !=, <=, >=, etc.)
                c1 := tok.toktype - 256;
                c2 := tok.toktype - 256;  # For two-char ops, encoding is: base + 256
                # Actually need to check the specific encoding
                # +=: 61 + 256 = 317, -: 45, so we get +=
                # The lexer encodes as: first_char + 256
                increment += sys->sprint("%c", c1);
                # For most compound ops, we need the second character too
                # Check based on the first character
                if (c1 == '+') increment += "=";
                else if (c1 == '-') increment += "=";
                else if (c1 == '=') increment += "=";
                else if (c1 == '!') increment += "=";
                else if (c1 == '<') increment += "=";
                else if (c1 == '>') increment += "=";
                else if (c1 == '*') increment += "=";
                else if (c1 == '/') increment += "=";
                else if (c1 == '%') increment += "=";
            } else if (tok.toktype >= 512) {
                # ++ or -- operator (encoded as base_char + 512)
                base := tok.toktype - 512;
                increment += sys->sprint("%c%c", base, base);
            }

            next_tok := p.peek();
            if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                next_tok.toktype != ')' &&
                should_add_space(tok.toktype, next_tok.toktype)) {
                increment += " ";
            }
        }
    }

    # Parse body (block or single statement)
    body: ref Ast->Statement;
    err6: string;
    if (p.peek().toktype == '{') {
        (body, err6) = parse_block(p);
    } else {
        (body, err6) = parse_statement(p);
    }
    if (err6 != nil)
        return (nil, err6);

    # No semolon needed after for statement with block
    return (ast->statement_create_for(lineno, init, condition, increment, body), nil);
}

# Parse a while loop: while (condition) { ... }
parse_while_stmt(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect 'while'
    (while_tok, err1) := p.expect(Lexer->TOKEN_WHILE);
    if (err1 != nil)
        return (nil, err1);

    # Expect '('
    (lparen, err2) := p.expect('(');
    if (err2 != nil)
        return (nil, err2);

    # Parse condition expression until ')'
    condition := "";
    paren_count := 1;
    while (paren_count > 0 && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.next();
        if (tok.toktype == '(')
            paren_count++;
        else if (tok.toktype == ')')
            paren_count--;

        if (paren_count > 0) {
            if (tok.toktype == Lexer->TOKEN_STRING) {
                condition += "\"" + limbo_escape(tok.string_val) + "\"";
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                condition += tok.string_val;
            } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                condition += sys->sprint("%bd", tok.number_val);
            } else if (tok.toktype == Lexer->TOKEN_REAL) {
                if (tok.real_val == real (big tok.real_val)) {
                    condition += sys->sprint("%bd.0", big tok.real_val);
                } else {
                    condition += sys->sprint("%g", tok.real_val);
                }
            } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                condition += "->";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                condition += sys->sprint("%c", tok.toktype);
            } else if (tok.toktype >= 256 && tok.toktype < 512) {
                # Two-character compound operator
                c := tok.toktype - 256;
                condition += sys->sprint("%c", c);
                if (c == '+') condition += "=";
                else if (c == '-') condition += "=";
                else if (c == '=') condition += "=";
                else if (c == '!') condition += "=";
                else if (c == '<') condition += "=";
                else if (c == '>') condition += "=";
                else if (c == '*') condition += "=";
                else if (c == '/') condition += "=";
                else if (c == '%') condition += "=";
            } else if (tok.toktype >= 512) {
                # ++ or -- operator
                base := tok.toktype - 512;
                condition += sys->sprint("%c%c", base, base);
            }

            next_tok := p.peek();
            if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                next_tok.toktype != ')' &&
                should_add_space(tok.toktype, next_tok.toktype)) {
                condition += " ";
            }
        }
    }

    # Parse body (block or single statement)
    body: ref Ast->Statement;
    err3: string;
    if (p.peek().toktype == '{') {
        (body, err3) = parse_block(p);
    } else {
        (body, err3) = parse_statement(p);
    }
    if (err3 != nil)
        return (nil, err3);

    # No semicolon needed after while statement with block
    return (ast->statement_create_while(lineno, condition, body), nil);
}

# Parse a return statement: return; or return expression;
parse_return_stmt(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Expect 'return'
    (ret_tok, err1) := p.expect(Lexer->TOKEN_RETURN);
    if (err1 != nil)
        return (nil, err1);

    # Parse return value (if any) until ';' (newline no longer accepted)
    expression := "";
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != ';' &&
           p.peek().toktype != '}') {
        tok := p.next();

        if (tok.toktype == Lexer->TOKEN_STRING) {
            expression += "\"" + limbo_escape(tok.string_val) + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            expression += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            expression += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            if (tok.real_val == real (big tok.real_val)) {
                expression += sys->sprint("%bd.0", big tok.real_val);
            } else {
                expression += sys->sprint("%g", tok.real_val);
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            expression += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            expression += sys->sprint("%c", tok.toktype);
        }

        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != ';' &&
            next_tok.toktype != '}' &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            expression += " ";
        }
    }

    # Require ';' after return statement
    tok := p.peek();
    if (tok.toktype != ';') {
        return (nil, fmt_error(p, "return statement must end with semicolon"));
    }
    p.next();  # consume ';'

    return (ast->statement_create_return(lineno, expression), nil);
}

# Parse an expression statement: expression;
parse_expr_stmt(p: ref Parser): (ref Ast->Statement, string)
{
    lineno := lexer->get_lineno(p.l);

    # Parse expression until ';' or '}' (newline no longer accepted)
    expression := "";
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != ';' &&
           p.peek().toktype != '}') {
        tok := p.next();

        if (tok.toktype == Lexer->TOKEN_STRING) {
            expression += "\"" + limbo_escape(tok.string_val) + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            expression += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            expression += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            if (tok.real_val == real (big tok.real_val)) {
                expression += sys->sprint("%bd.0", big tok.real_val);
            } else {
                expression += sys->sprint("%g", tok.real_val);
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            expression += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            expression += sys->sprint("%c", tok.toktype);
        } else {
            # Handle keyword tokens
            s := token_to_string(tok);
            if (s != nil && len s > 0)
                expression += s;
        }

        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != ';' &&
            next_tok.toktype != '}' &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            expression += " ";
        }
    }

    # Require ';' after expression statement
    tok := p.peek();
    if (tok.toktype != ';') {
        return (nil, fmt_error(p, "expression statement must end with semicolon"));
    }
    p.next();  # consume ';'

    return (ast->statement_create_expr(lineno, expression), nil);
}

# Parse an expression statement when the first token is already consumed
parse_expr_stmt_with_first(p: ref Parser, first_tok: ref Token): (ref Ast->Statement, string)
{
    lineno := first_tok.lineno;

    # Start expression with the first token
    expression := "";
    if (first_tok.toktype == Lexer->TOKEN_STRING) {
        expression += "\"" + limbo_escape(first_tok.string_val) + "\"";
    } else if (first_tok.toktype == Lexer->TOKEN_IDENTIFIER) {
        expression += first_tok.string_val;
    } else if (first_tok.toktype == Lexer->TOKEN_NUMBER) {
        expression += sys->sprint("%bd", first_tok.number_val);
    } else if (first_tok.toktype == Lexer->TOKEN_REAL) {
        if (first_tok.real_val == real (big first_tok.real_val)) {
            expression += sys->sprint("%bd.0", big first_tok.real_val);
        } else {
            expression += sys->sprint("%g", first_tok.real_val);
        }
    } else if (first_tok.toktype == Lexer->TOKEN_ARROW) {
        expression += "->";
    } else if (first_tok.toktype >= 32 && first_tok.toktype <= 126) {
        expression += sys->sprint("%c", first_tok.toktype);
    }

    # Parse rest of expression until ';' or '}' (newline no longer accepted)
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
           p.peek().toktype != ';' &&
           p.peek().toktype != '}') {
        tok := p.next();

        if (tok.toktype == Lexer->TOKEN_STRING) {
            expression += "\"" + limbo_escape(tok.string_val) + "\"";
        } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            expression += tok.string_val;
        } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
            expression += sys->sprint("%bd", tok.number_val);
        } else if (tok.toktype == Lexer->TOKEN_REAL) {
            if (tok.real_val == real (big tok.real_val)) {
                expression += sys->sprint("%bd.0", big tok.real_val);
            } else {
                expression += sys->sprint("%g", tok.real_val);
            }
        } else if (tok.toktype == Lexer->TOKEN_ARROW) {
            expression += "->";
        } else if (tok.toktype >= 32 && tok.toktype <= 126) {
            expression += sys->sprint("%c", tok.toktype);
        } else {
            # Handle keyword tokens
            s := token_to_string(tok);
            if (s != nil && len s > 0)
                expression += s;
        }

        next_tok := p.peek();
        if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
            next_tok.toktype != ';' &&
            next_tok.toktype != '}' &&
            should_add_space(tok.toktype, next_tok.toktype)) {
            expression += " ";
        }
    }

    # Require ';' after expression statement
    tok := p.peek();
    if (tok.toktype != ';') {
        return (nil, fmt_error(p, "expression statement must end with semicolon"));
    }
    p.next();  # consume ';'

    return (ast->statement_create_expr(lineno, expression), nil);
}

# Parse a regular function declaration: fn name() { ... }
# OR: fn name(): type = expression @ interval
parse_function_decl(p: ref Parser): (ref Ast->FunctionDecl, string)
{
    # Expect: fn name() { ... } or fn name(): type = expression @ interval
    # Already have 'fn' token

    # Parse function name
    name_tok := p.next();
    if (name_tok.toktype != Lexer->TOKEN_IDENTIFIER)
        return (nil, fmt_error(p, "expected function name after 'fn'"));

    name := name_tok.string_val;

    # Expect "(" to start parameter list
    (tok1, err1) := p.expect('(');
    if (err1 != nil)
        return (nil, err1);

    # Skip parameters until ")" - we preserve them in the body
    # For simplicity, we just look for the matching ")"
    paren_count := 1;
    params := "";
    prev_toktype := 0;
    while (paren_count > 0 && p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.next();
        if (tok.toktype == '(')
            paren_count++;
        else if (tok.toktype == ')')
            paren_count--;

        if (paren_count > 0) {
            # Add to params string with proper spacing
            if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                # Check if previous char was not a space and next is not special
                # No space needed after '(', or ':'
                if (len params > 0 && params[len params - 1] != ' ' &&
                    params[len params - 1] != '(' && params[len params - 1] != ':')
                    params += " ";
                params += tok.string_val;
            } else if (tok.toktype == ':') {
                params += ": ";
            } else if (tok.toktype == ',') {
                params += ", ";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                params += sys->sprint("%c", tok.toktype);
            }
            prev_toktype = tok.toktype;
        }
    }

    # Convert Kryon *Type syntax to Limbo ref Type syntax in parameters
    params = kryon_type_to_limbo(params);

    # Check for optional return type: : string
    return_type := "";
    if (p.peek().toktype == ':') {
        p.next();  # consume ':'
        type_tok := p.next();
        if (type_tok.toktype != Lexer->TOKEN_IDENTIFIER)
            return (nil, fmt_error(p, "expected return type identifier after ':'"));

        return_type = type_tok.string_val;
    }

    # Check for inline body (=) or block body ({)
    if (p.peek().toktype == '=') {
        # Inline function: fn name(): type = expression [@ interval]
        p.next();  # consume '='

        # Parse expression until end of line, semicolon, or @
        body_expr := "";
        while (p.peek().toktype != Lexer->TOKEN_ENDINPUT &&
               p.peek().toktype != Lexer->TOKEN_AT &&
               p.peek().toktype != '\n' &&
               p.peek().toktype != ';') {
            tok := p.next();

            # Build expression from tokens
            if (tok.toktype == Lexer->TOKEN_STRING) {
                body_expr += "\"" + limbo_escape(tok.string_val) + "\"";
            } else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
                body_expr += tok.string_val;
            } else if (tok.toktype == Lexer->TOKEN_NUMBER) {
                body_expr += sys->sprint("%bd", tok.number_val);
            } else if (tok.toktype == Lexer->TOKEN_REAL) {
                # Use %.1g to ensure decimal point is preserved for values like 180.0
                # But %g can still drop the decimal, so check if value is whole number
                if (tok.real_val == real (big tok.real_val)) {
                    # Whole number - need to add .0 to preserve type
                    body_expr += sys->sprint("%bd.0", big tok.real_val);
                } else {
                    body_expr += sys->sprint("%g", tok.real_val);
                }
            } else if (tok.toktype == Lexer->TOKEN_ARROW) {
                body_expr += "->";
            } else if (tok.toktype >= 32 && tok.toktype <= 126) {
                body_expr += sys->sprint("%c", tok.toktype);
            }

            # Add space for next token (if not end, with proper spacing rules)
            next_tok := p.peek();
            if (next_tok.toktype != Lexer->TOKEN_ENDINPUT &&
                next_tok.toktype != Lexer->TOKEN_AT &&
                next_tok.toktype != '\n' &&
                next_tok.toktype != ';' &&
                should_add_space(tok.toktype, next_tok.toktype)) {
                body_expr += " ";
            }
        }

        # Check for reactive binding
        interval := 0;
        if (p.peek().toktype == Lexer->TOKEN_AT) {
            p.next();  # consume '@'
            num_tok := p.next();
            if (num_tok.toktype != Lexer->TOKEN_NUMBER)
                return (nil, fmt_error(p, "expected number after '@'"));

            interval = int num_tok.number_val;
        }

        # Consume optional semicolon after inline function
        if (p.peek().toktype == ';') {
            p.next();  # consume ';'
        }

        # Inline functions need explicit return statement
        # Create a Return statement with the expression
        body_stmt := ast->statement_create_return(lexer->get_lineno(p.l), body_expr);

        # Create function declaration with parsed body
        fn_decl := ast->functiondecl_create_with_body(name, params, body_stmt, return_type, interval);
        return (fn_decl, nil);
    }

    # Block body: fn name() { ... }
    # Use parse_block to parse statements
    body_stmt: ref Ast->Statement;
    err3: string;
    (body_stmt, err3) = parse_block(p);
    if (err3 != nil)
        return (nil, err3);

    fn_decl := ast->functiondecl_create_with_body(name, params, body_stmt, return_type, 0);
    return (fn_decl, nil);
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

    Lexer->TOKEN_REAL =>
        return (ast->value_create_real(tok.real_val), nil);

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

    # Accept keywords as property names too (e.g., "type = Appl")
    # Check if it's an identifier or a keyword that can be used as property name
    name := "";
    if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
        name = tok.string_val;
    } else if (tok.toktype == Lexer->TOKEN_TYPE) {
        name = "type";
    } else if (tok.toktype == Lexer->TOKEN_STRUCT) {
        name = "struct";
    } else if (tok.toktype == Lexer->TOKEN_CHAN) {
        name = "chan";
    } else if (tok.toktype == Lexer->TOKEN_SPAWN) {
        name = "spawn";
    } else if (tok.toktype == Lexer->TOKEN_OF) {
        name = "of";
    } else if (tok.toktype == Lexer->TOKEN_ARRAY) {
        name = "array";
    } else if (tok.toktype == Lexer->TOKEN_VAR) {
        name = "var";
    } else if (tok.toktype == Lexer->TOKEN_FN) {
        name = "fn";
    } else {
        return (nil, fmt_error(p, "expected property name"));
    }

    # Expect '='
    (tok1, err1) := p.expect('=');
    if (err1 != nil) {
        return (nil, err1);
    }

    # Check for reactive syntax: identifier @ number
    # But first check if it's an identifier followed by () (function call)
    if (p.peek().toktype == Lexer->TOKEN_IDENTIFIER) {
        # Peek ahead to see what comes after the identifier
        # We need to look at: identifier, then @ or (
        # But we haven't consumed the identifier yet
        # So we peek at identifier, then peek again to check next token

        # Consume the identifier
        id_tok := p.next();
        id_name := id_tok.string_val;

        # Check if next is '(' (function call)
        if (p.peek().toktype == '(') {
            p.next();  # consume '('
            (close_paren, err) := p.expect(')');
            if (err != nil) {
                return (nil, err);
            }
            prop := ast->property_create(name);
            prop.value = ast->value_create_fn_call(id_name);
            return (prop, nil);
        }

        # Check for @ reactive syntax
        if (p.peek().toktype == Lexer->TOKEN_AT) {
            p.next();  # consume @
            num_tok := p.next();
            if (num_tok.toktype != Lexer->TOKEN_NUMBER)
                return (nil, fmt_error(p, "expected number after '@'"));

            interval := int num_tok.number_val;
            prop := ast->property_create(name);
            prop.value = ast->value_create_ident(sys->sprint("%s@%d", id_name, interval));
            return (prop, nil);
        }

        # Just identifier, no @ or ()
        prop := ast->property_create(name);
        prop.value = ast->value_create_ident(id_name);
        return (prop, nil);
    }

    # Parse other value types normally
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

        # Property: identifier (or keyword) = value
        # Check if this could be a property: peek ahead to see if next token is '='
        if (tok.toktype == Lexer->TOKEN_IDENTIFIER ||
            tok.toktype == Lexer->TOKEN_TYPE ||
            tok.toktype == Lexer->TOKEN_VAR ||
            tok.toktype == Lexer->TOKEN_FN ||
            tok.toktype == Lexer->TOKEN_STRUCT ||
            tok.toktype == Lexer->TOKEN_CHAN ||
            tok.toktype == Lexer->TOKEN_ARRAY) {
            # Peek ahead to see if next token is '=' (confirms this is a property)
            next_tok := p.peek();
            # Actually we need to peek TWO tokens ahead since tok is already peeked
            # Consume the token and let parse_property handle it
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
        else if (tok.toktype >= Lexer->TOKEN_WINDOW && tok.toktype <= Lexer->TOKEN_IMG) {
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

parse_img(p: ref Parser): (ref Widget, string)
{
    (body, err) := parse_widget_body(p);
    if (err != nil) {
        return (nil, err);
    }

    w := ast->widget_create(Ast->WIDGET_IMG);
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

    Lexer->TOKEN_IMG =>
        return parse_img(p);

    * =>
        return (nil, fmt_error(p, sys->sprint("unknown widget type token: %d", tok.toktype)));
    }
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

    # Parse use statements at the top
    while (p.peek().toktype == Lexer->TOKEN_IDENTIFIER) {
        # Peek ahead to check if it's "use"
        tok := p.peek();
        if (tok.string_val == "use") {
            (imp, err) := parse_use_statement(p);
            if (err != nil) {
                return (nil, err);
            }
            ast->program_add_module_import(prog, imp);
        } else {
            break;
        }
    }

    # Parse const, struct, var, fn declarations and reactive functions
    while (p.peek().toktype != Lexer->TOKEN_ENDINPUT) {
        tok := p.peek();

        # Check for const declaration: const NAME = value
        if (tok.toktype == Lexer->TOKEN_CONST) {
            p.next();  # consume 'const'
            (cd, err) := parse_const_decl(p);
            if (err != nil) {
                return (nil, err);
            }
            ast->program_add_const(prog, cd);
        }
        # Check for struct declaration: struct Name { ... }
        else if (tok.toktype == Lexer->TOKEN_STRUCT) {
            p.next();  # consume 'struct'
            (sd, err) := parse_struct_decl(p);
            if (err != nil) {
                return (nil, err);
            }
            ast->program_add_struct_decl(prog, sd);
        }
        # Check for regular function declaration
        else if (tok.toktype == Lexer->TOKEN_FN) {
            p.next();  # consume 'fn'
            (fd, err) := parse_function_decl(p);
            if (err != nil) {
                return (nil, err);
            }
            ast->program_add_function_decl(prog, fd);
        }
        # Check for var declaration
        else if (tok.toktype == Lexer->TOKEN_VAR) {
            p.next();  # consume 'var'
            (vd, err) := parse_var_decl(p);
            if (err != nil) {
                return (nil, err);
            }
            ast->program_add_var(prog, vd);
        }
        # Check for Window (app declaration)
        else if (tok.toktype == Lexer->TOKEN_WINDOW) {
            (app, err) := parse_app_decl(p);
            if (err != nil) {
                return (nil, err);
            }
            prog.app = app;

            # Check if we should use Draw backend
            # 1. Window has onDraw property (old behavior)
            # 2. Window contains Canvas widgets (new)
            if (app.props != nil) {
                if (has_property(app.props, "onDraw"))
                    prog.window_type = 1;  # Draw backend
            }

            # Check for Canvas widgets in the body
            if (prog.window_type != 1 && app.body != nil) {
                if (has_canvas_widget(app.body))
                    prog.window_type = 1;  # Draw backend
            }

            break;  # Window is the last thing in the file
        }
        # Check for reactive function (identifier followed by ':')
        else if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            # Peek ahead to check if next token is ':'
            if (p.peek().toktype == ':') {
                (rfn, err) := parse_reactive_function(p);
                if (err != nil) {
                    return (nil, err);
                }
                ast->program_add_reactive_fn(prog, rfn);
            } else {
                return (nil, fmt_error(p, "expected function declaration, var declaration, constant declaration, reactive function, struct declaration, or Window"));
            }
        } else {
            return (nil, fmt_error(p, "expected function declaration, var declaration, constant declaration, reactive function, struct declaration, or Window"));
        }
    }

    # Check for undefined variables
    parse_err: string;
    parse_err = check_undefined_variables(prog);
    if (parse_err != nil)
        return (nil, parse_err);

    # After all parsing, check if we should use Draw backend due to Graphics API usage
    # (this is done after all functions are parsed)
    if (prog.window_type != 1 && prog.app != nil) {
        if (needs_graphics_module(prog))
            prog.window_type = 1;  # Draw backend
    }

    return (prog, nil);
}

# =========================================================================
# Variable validation functions
# =========================================================================

# Built-in Limbo keywords and types that should be excluded from validation
is_builtin_keyword(s: string): int
{
    if (s == "if") return 1;
    if (s == "else") return 1;
    if (s == "for") return 1;
    if (s == "while") return 1;
    if (s == "return") return 1;
    if (s == "nil") return 1;
    if (s == "int") return 1;
    if (s == "real") return 1;
    if (s == "string") return 1;
    # 'ref' removed - Kryon uses *Type syntax instead
    if (s == "array") return 1;
    if (s == "list") return 1;
    if (s == "chan") return 1;
    if (s == "of") return 1;
    if (s == "do") return 1;
    if (s == "case") return 1;
    if (s == "pick") return 1;
    if (s == "con") return 1;
    if (s == "adt") return 1;
    if (s == "fn") return 1;
    if (s == "impl") return 1;
    if (s == "include") return 1;
    if (s == "import") return 1;
    if (s == "type") return 1;
    if (s == "break") return 1;
    if (s == "continue") return 1;
    if (s == "alt") return 1;
    if (s == "load") return 1;
    if (s == "raise") return 1;
    if (s == "spawn") return 1;
    if (s == "exit") return 1;
    # List built-in functions
    if (s == "hd") return 1;
    if (s == "tl") return 1;
    if (s == "len") return 1;
    return 0;
}

# Convert Kryon *Type syntax to Limbo ref Type syntax
# e.g., "*Image" -> "ref Image", "*int" -> "ref int"
# Also handles "* Image" (with space) -> "ref Image"
kryon_type_to_limbo(type_str: string): string
{
    result := "";
    i := 0;

    while (i < len type_str) {
        # Check for *Type pattern
        if (type_str[i] == '*' && i + 1 < len type_str) {
            # Skip any whitespace after *
            j := i + 1;
            while (j < len type_str && (type_str[j] == ' ' || type_str[j] == '\t'))
                j++;

            # If we found a valid type identifier after *, convert to "ref "
            if (j < len type_str && ((type_str[j] >= 'A' && type_str[j] <= 'Z') ||
                                     (type_str[j] >= 'a' && type_str[j] <= 'z') ||
                                     type_str[j] == '_')) {
                result += "ref ";
                i = j;  # Skip the * and any whitespace
            }
        }

        result[len result] = type_str[i];
        i++;
    }

    return result;
}

# Common standard library modules that should be excluded
is_stdlib_module(s: string): int
{
    if (s == "sys") return 1;
    if (s == "draw") return 1;
    if (s == "math") return 1;
    if (s == "daytime") return 1;
    if (s == "wmclient") return 1;
    if (s == "tk") return 1;
    if (s == "bufio") return 1;
    if (s == "bufio") return 1;
    if (s == "sh") return 1;
    if (s == "iostream") return 1;
    if (s == "stringmod") return 1;
    if (s == "rand") return 1;
    if (s == "keyring") return 1;
    if (s == "security") return 1;
    return 0;
}

# Extract parameter names from a parameter string like "c: Point, r: int, degrees: int"
extract_param_names(params: string): list of string
{
    names: list of string = nil;

    if (params == nil || len params == 0)
        return names;

    # Simple parser: split by ',', then take identifier before ':'
    i := 0;
    while (i < len params) {
        # Skip whitespace
        while (i < len params && (params[i] == ' ' || params[i] == '\t'))
            i++;

        if (i >= len params)
            break;

        # Read identifier name
        start := i;
        while (i < len params && ((params[i] >= 'a' && params[i] <= 'z') ||
               (params[i] >= 'A' && params[i] <= 'Z') ||
               (params[i] >= '0' && params[i] <= '9') ||
               params[i] == '_')) {
            i++;
        }

        if (i > start) {
            name := params[start:i];
            # Skip to comma or end
            while (i < len params && params[i] != ',')
                i++;
            if (i < len params && params[i] == ',')
                i++;
            names = name :: names;
        } else {
            # Skip to comma or end
            while (i < len params && params[i] != ',')
                i++;
            if (i < len params && params[i] == ',')
                i++;
        }
    }

    # Reverse to get original order
    result: list of string = nil;
    for (l := names; l != nil; l = tl l)
        result = hd l :: result;

    return result;
}

# Scan a function body statement for local var declarations
# Returns list of local variable names
extract_local_vars_from_stmt(body: ref Ast->Statement): list of string
{
    locals: list of string = nil;

    if (body == nil)
        return locals;

    stmt := body;
    while (stmt != nil) {
        pick s := stmt {
        VarDecl =>
            if (s.var_decl != nil) {
                varname := s.var_decl.name;
                # Add to locals (avoid duplicates)
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == varname) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = varname :: locals;
            }
        Block =>
            # Recursively extract from nested statements
            nested := extract_local_vars_from_stmt(s.statements);
            # Merge nested locals into locals
            while (nested != nil) {
                name := hd nested;
                # Check for duplicate
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == name) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = name :: locals;
                nested = tl nested;
            }
        If =>
            # Extract from then and else branches
            then_locals := extract_local_vars_from_stmt(s.then_stmt);
            else_locals := extract_local_vars_from_stmt(s.else_stmt);
            # Merge
            while (then_locals != nil) {
                name := hd then_locals;
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == name) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = name :: locals;
                then_locals = tl then_locals;
            }
            while (else_locals != nil) {
                name := hd else_locals;
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == name) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = name :: locals;
                else_locals = tl else_locals;
            }
        For =>
            # Extract from init and body
            init_locals := extract_local_vars_from_stmt(s.init);
            body_locals := extract_local_vars_from_stmt(s.body);
            # Merge
            while (init_locals != nil) {
                name := hd init_locals;
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == name) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = name :: locals;
                init_locals = tl init_locals;
            }
            while (body_locals != nil) {
                name := hd body_locals;
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == name) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = name :: locals;
                body_locals = tl body_locals;
            }
        While =>
            # Extract from body
            body_locals := extract_local_vars_from_stmt(s.body);
            while (body_locals != nil) {
                name := hd body_locals;
                found := 0;
                for (l := locals; l != nil; l = tl l) {
                    if (hd l == name) {
                        found = 1;
                        break;
                    }
                }
                if (!found)
                    locals = name :: locals;
                body_locals = tl body_locals;
            }
        * =>
            # Return, Expr statements don't declare variables
        }
        stmt = stmt.next;
    }

    return locals;
}

# Check all identifiers in a function body statement against the symbol table
# Returns error string if undefined variable found, nil otherwise
check_statement_body(stmt: ref Ast->Statement, st: ref Ast->SymbolTable, fn_name: string): string
{
    if (stmt == nil)
        return nil;

    s := stmt;
    while (s != nil) {
        pick cur := s {
        VarDecl =>
            # Check init expression
            if (cur.var_decl != nil && cur.var_decl.init_expr != nil && len cur.var_decl.init_expr > 0) {
                err := check_expression_string(cur.var_decl.init_expr, st, fn_name);
                if (err != nil)
                    return err;
            }
        Block =>
            # Recursively check nested statements
            err := check_statement_body(cur.statements, st, fn_name);
            if (err != nil)
                return err;
        If =>
            # Check condition expression
            err := check_expression_string(cur.condition, st, fn_name);
            if (err != nil)
                return err;
            # Check then and else branches
            err = check_statement_body(cur.then_stmt, st, fn_name);
            if (err != nil)
                return err;
            err = check_statement_body(cur.else_stmt, st, fn_name);
            if (err != nil)
                return err;
        For =>
            # Check init, condition, increment, and body
            err := check_statement_body(cur.init, st, fn_name);
            if (err != nil)
                return err;
            err = check_expression_string(cur.condition, st, fn_name);
            if (err != nil)
                return err;
            err = check_expression_string(cur.increment, st, fn_name);
            if (err != nil)
                return err;
            err = check_statement_body(cur.body, st, fn_name);
            if (err != nil)
                return err;
        While =>
            # Check condition and body
            err := check_expression_string(cur.condition, st, fn_name);
            if (err != nil)
                return err;
            err = check_statement_body(cur.body, st, fn_name);
            if (err != nil)
                return err;
        Return =>
            # Check return expression
            if (cur.expression != nil && len cur.expression > 0) {
                err := check_expression_string(cur.expression, st, fn_name);
                if (err != nil)
                    return err;
            }
        Expr =>
            # Check expression
            if (cur.expression != nil && len cur.expression > 0) {
                err := check_expression_string(cur.expression, st, fn_name);
                if (err != nil)
                    return err;
            }
        }
        s = s.next;
    }

    return nil;
}

# Check identifiers in an expression string against the symbol table
check_expression_string(expr: string, st: ref Ast->SymbolTable, fn_name: string): string
{
    if (expr == nil || len expr == 0)
        return nil;

    # Create a lexer to scan the expression
    lex := lexer->create("<expression>", expr);

    prev_tok: ref Token;
    prev_tok = nil;

    while (1) {
        tok := lexer->lex(lex);
        if (tok.toktype == Lexer->TOKEN_ENDINPUT)
            break;

        # Check identifiers
        if (tok.toktype == Lexer->TOKEN_IDENTIFIER) {
            name := tok.string_val;

            # Skip built-in keywords
            if (is_builtin_keyword(name))
                continue;

            # Skip standard library modules
            if (is_stdlib_module(name))
                continue;

            # Skip if previous token was . or -> (method/member access)
            if (prev_tok != nil) {
                if (prev_tok.toktype == '.' ||
                    prev_tok.toktype == Lexer->TOKEN_ARROW) {
                    prev_tok = tok;
                    continue;
                }
            }

            # Skip uppercase identifiers that are likely type names
            if (len name > 0 && name[0] >= 'A' && name[0] <= 'Z') {
                if (!ast->symboltable_has_var(st, name)) {
                    prev_tok = tok;
                    continue;
                }
            }

            # Check if variable is defined
            if (!ast->symboltable_has_var(st, name)) {
                return sys->sprint("undefined variable '%s'", name);
            }
        }

        # Update previous token
        prev_tok = tok;
    }

    return nil;
}

# Main validation function - checks all function bodies for undefined variables
check_undefined_variables(prog: ref Program): string
{
    if (prog == nil)
        return nil;

    # Build symbol table for module-level variables
    st := ast->symboltable_create();

    # Add module imports
    imp := prog.module_imports;
    while (imp != nil) {
        # Add the module name (e.g., "math" from "use math")
        ast->symboltable_add_import(st, imp.module_name);

        # Also add common aliases if present
        if (imp.alias != nil && len imp.alias > 0)
            ast->symboltable_add_import(st, imp.alias);

        imp = imp.next;
    }

    # Add common standard library modules by default (often used without explicit use)
    ast->symboltable_add_import(st, "sys");
    ast->symboltable_add_import(st, "draw");
    ast->symboltable_add_import(st, "math");
    ast->symboltable_add_import(st, "daytime");
    ast->symboltable_add_import(st, "wmclient");
    ast->symboltable_add_import(st, "tk");

    # Add Draw constants and functions (accessed via Draw->)
    ast->symboltable_add_import(st, "Draw");
    ast->symboltable_add_import(st, "Math");

    # Add module-level variables
    v := prog.vars;
    while (v != nil) {
        ast->symboltable_add_module_var(st, v.name);
        v = v.next;
    }

    # Add function names to module-level symbol table (so functions can call each other)
    fd := prog.function_decls;
    while (fd != nil) {
        ast->symboltable_add_module_var(st, fd.name);
        fd = fd.next;
    }

    # Check each function
    fd = prog.function_decls;
    while (fd != nil) {
        # Create function-specific symbol table
        fn_st := ast->symboltable_create();

        # Copy module-level vars and imports
        fn_st.module_vars = st.module_vars;
        fn_st.imports = st.imports;

        # Copy module-level variables to function symbol table
        fn_st.module_vars = st.module_vars;

        # Add function parameters
        param_names := extract_param_names(fd.params);
        {
        l := param_names;
        while (l != nil) {
            ast->symboltable_add_param(fn_st, hd l);
            l = tl l;
        }
        }

        # Add local variables from function body
        locals := extract_local_vars_from_stmt(fd.body);
        {
        l := locals;
        while (l != nil) {
            ast->symboltable_add_var(fn_st, hd l);
            l = tl l;
        }
        }

        # Check the function body
        err := check_statement_body(fd.body, fn_st, fd.name);
        if (err != nil)
            return err;

        fd = fd.next;
    }

    return nil;
}

# =========================================================================
# Code generation functions
# =========================================================================

# Re-escape a string literal for Limbo source code
limbo_escape(s: string): string
{
    res := "";
    for(i := 0; i < len s; i++){
        case s[i] {
            '\n' => res += "\\n";
            '\t' => res += "\\t";
            '\"' => res += "\\\"";
            '\\' => res += "\\\\";
            * => res[len res] = s[i];
        }
    }
    return res;
}

# =========================================================================
# Graphics API transformation functions
# =========================================================================

# Find character position in string (returns -1 if not found)
strfind(s: string, c: int, start: int): int
{
    for (i := start; i < len s; i++) {
        if (s[i] == c)
            return i;
    }
    return -1;
}

# Check if expression is a Graphics method call (e.g., ctx.clear("#fff"))
# Returns (is_graphics_call, transformed_expression, color_declarations)
transform_graphics_call(expr: string): (int, string, string)
{
    if (expr == nil || len expr == 0)
        return (0, expr, "");

    # Use a simpler pattern matching approach
    # Look for ctx.method( pattern

    # Find "ctx." prefix
    ctx_pos := 0;
    found := 0;
    i := 0;
    for (i = 0; i < len expr - 4; i++) {
        if (expr[i] == 'c' && expr[i+1] == 't' && expr[i+2] == 'x' && expr[i+3] == '.') {
            ctx_pos = i;
            found = 1;
            break;
        }
    }

    if (!found)
        return (0, expr, "");

    # Find method name (characters after "ctx." until "(")
    method_start := ctx_pos + 4;
    paren_pos := strfind(expr, '(', method_start);
    if (paren_pos < 0)
        return (0, expr, "");

    method := expr[method_start:paren_pos];

    # Find matching closing parenthesis
    depth := 1;
    arg_start := paren_pos + 1;
    arg_end := -1;
    for (i = arg_start; i < len expr; i++) {
        if (expr[i] == '(')
            depth++;
        else if (expr[i] == ')') {
            depth--;
            if (depth == 0) {
                arg_end = i;
                break;
            }
        }
    }

    if (arg_end < 0)
        return (0, expr, "");

    args := expr[arg_start:arg_end];

    # Transform known Graphics methods
    color_decls := "";
    obj := "ctx";

    case method {
    "clear" =>
        # ctx.clear(color) -> graphics->clear(ctx, color)
        (args, color_decls) = transform_color_arg(args);
        return (1, sys->sprint("graphics->clear(%s, %s)", obj, args), color_decls);

    "fill" =>
        # ctx.fill(color) -> graphics->setfill(ctx, color)
        (args, color_decls) = transform_color_arg(args);
        return (1, sys->sprint("graphics->setfill(%s, %s)", obj, args), color_decls);

    "stroke" =>
        # ctx.stroke(color) -> graphics->setstroke(ctx, color)
        (args, color_decls) = transform_color_arg(args);
        return (1, sys->sprint("graphics->setstroke(%s, %s)", obj, args), color_decls);

    "rect" =>
        # ctx.rect(x, y, w, h) -> graphics->rect(ctx, x, y, w, h)
        return (1, sys->sprint("graphics->rect(%s, %s)", obj, args), "");

    "circle" =>
        # ctx.circle(x, y, r) -> graphics->circle(ctx, x, y, r)
        return (1, sys->sprint("graphics->circle(%s, %s)", obj, args), "");

    "ellipse" =>
        # ctx.ellipse(x, y, rx, ry) -> graphics->ellipse(ctx, x, y, rx, ry)
        return (1, sys->sprint("graphics->ellipse(%s, %s)", obj, args), "");

    "line" =>
        # ctx.line(x1, y1, x2, y2) -> graphics->line(ctx, x1, y1, x2, y2)
        return (1, sys->sprint("graphics->line(%s, %s)", obj, args), "");

    "text" =>
        # ctx.text(str, x, y) -> graphics->text(ctx, str, x, y)
        return (1, sys->sprint("graphics->text(%s, %s)", obj, args), "");

    "setlinewidth" =>
        # ctx.setlinewidth(w) -> graphics->setlinewidth(ctx, w)
        return (1, sys->sprint("graphics->setlinewidth(%s, %s)", obj, args), "");
    }

    return (0, expr, "");
}

# Transform Color expressions (e.g., Color.red, Color("#ff0000"), Color.rgb(255,0,0))
# Returns (transformed_arg, color_declarations)
transform_color_arg(arg: string): (string, string)
{
    if (arg == nil || len arg == 0)
        return (arg, "");

    # Trim whitespace
    start := 0;
    while (start < len arg && (arg[start] == ' ' || arg[start] == '\t'))
        start++;

    end := len arg;
    while (end > 0 && (arg[end-1] == ' ' || arg[end-1] == '\t' || arg[end-1] == '\n'))
        end--;

    if (start >= end)
        return (arg, "");

    trimmed := arg[start:end];

    # Check for Color.name pattern (e.g., Color.red)
    if (len trimmed > 6 && trimmed[0:6] == "Color.") {
        color_name := trimmed[6:];
        return (transform_color_name(color_name), "");
    }

    # Check for Color("#hex") pattern
    if (len trimmed > 8 && trimmed[0:6] == "Color" && trimmed[6] == '(') {
        inner := trimmed[7:len trimmed - 1];
        if (len inner > 0 && inner[0] == '"') {
            # Color("#ff0000") -> extract hex and call display.color
            hex_val := inner[1:len inner - 1];
            return (sys->sprint("graphics->hexcolor(display, \"%s\")", hex_val), "");
        }
    }

    # Check for Color.rgb(r,g,b) pattern
    if (len trimmed > 11 && trimmed[0:6] == "Color" && trimmed[6:9] == ".rgb" && trimmed[9] == '(') {
        args := trimmed[10:len trimmed - 1];
        # Color.rgb(255,0,0) -> display.rgb(255,0,0)
        return (sys->sprint("graphics->rgb(display, %s)", args), "");
    }

    return (arg, "");
}

# Transform color name to display.color call
transform_color_name(name: string): string
{
    # CSS color names mapping to Draw->Display constants
    case name {
    "black" =>
        return "display.black";
    "white" =>
        return "display.white";
    "red" =>
        return "display.red";
    "green" =>
        return "display.green";
    "blue" =>
        return "display.blue";
    "yellow" =>
        return "display.yellow";
    "purple" =>
        return "display.purple";
    "cyan" =>
        return "display.cyan";
    "magenta" =>
        return "display.magenta";
    "grey" or "gray" =>
        return "display.grey";
    "palegrey" or "palegray" =>
        return "display.palegrey";
    "darkgrey" or "darkgray" =>
        return "display.darkgrey";
    "paleyellow" =>
        return "display.paleyellow";
    "darkyellow" =>
        return "display.darkyellow";
    "darkgreen" =>
        return "display.darkgreen";
    "palegreen" =>
        return "display.palegreen";
    "darkblue" =>
        return "display.darkblue";
    "paleblue" =>
        return "display.palebluegreen";
    "darkred" =>
        return "display.darkred";
    "palered" or "pink" =>
        return "display.paleyellow";
    * =>
        # Unknown color - try to use as is (might be a user variable)
        return sys->sprint("display.%s", name);
    }
}

# Check if a string contains a Graphics method call
has_graphics_call(expr: string): int
{
    if (expr == nil || len expr == 0)
        return 0;

    # Look for pattern: ctx.method(
    i := 0;
    while (i < len expr - 5) {
        if (expr[i:i+3] == "ctx" && expr[i+3] == '.') {
            # Found ctx. - now check if followed by a method name
            j := i + 4;
            method := "";
            while (j < len expr && expr[j] != '(') {
                method[len method] = expr[j];
                j++;
            }
            # Check if it's a known Graphics method
            if (is_graphics_method(method))
                return 1;
        }
        i++;
    }

    return 0;
}

# Check if method name is a Graphics method
is_graphics_method(method: string): int
{
    if (method == nil || len method == 0)
        return 0;

    # Trim whitespace
    start := 0;
    while (start < len method && (method[start] == ' ' || method[start] == '\t'))
        start++;

    end := len method;
    while (end > 0 && (method[end-1] == ' ' || method[end-1] == '\t'))
        end--;

    trimmed := method[start:end];

    if (trimmed == "clear" || trimmed == "fill" || trimmed == "stroke" ||
        trimmed == "rect" || trimmed == "circle" || trimmed == "ellipse" ||
        trimmed == "line" || trimmed == "text" || trimmed == "setlinewidth")
        return 1;

    return 0;
}

# Convert Kryon var syntax to Limbo syntax
# Kryon: var name: type = expr  or  var name: type;
# Limbo: name := expr  or  name : type = expr;
convert_var_syntax(body: string): string
{
    if (body == nil || len body == 0)
        return body;

    result := "";
    i := 0;

    while (i < len body) {
        # Look for 'var' keyword
        if (i + 3 < len body && body[i] == 'v' && body[i+1] == 'a' && body[i+2] == 'r') {
            # Check if this is really 'var' keyword (not part of another word)
            is_var := 0;
            if (i == 0 || body[i-1] == ' ' || body[i-1] == '\t' || body[i-1] == '\n' || body[i-1] == ';' || body[i-1] == '{' || body[i-1] == '(') {
                is_var = 1;
            }

            if (is_var && (i + 3 >= len body || (body[i+3] == ' ' || body[i+3] == '\t' || body[i+3] == ':'))) {
                j := i + 3;

                # Skip whitespace after 'var'
                while (j < len body && (body[j] == ' ' || body[j] == '\t'))
                    j++;

                if (j >= len body)
                    break;

                # Find variable name (identifier)
                start_name := j;
                while (j < len body && ((body[j] >= 'a' && body[j] <= 'z') ||
                                       (body[j] >= 'A' && body[j] <= 'Z') ||
                                       (body[j] >= '0' && body[j] <= '9') ||
                                       body[j] == '_'))
                    j++;

                if (j > start_name) {
                    varname := body[start_name:j];

                    # Skip whitespace and look for ':'
                    while (j < len body && (body[j] == ' ' || body[j] == '\t'))
                        j++;

                    if (j < len body && body[j] == ':') {
                        # Found 'var name :' - skip the 'var' and ':'
                        j++;  # skip ':'

                        # Skip whitespace after ':'
                        while (j < len body && (body[j] == ' ' || body[j] == '\t'))
                            j++;

                        # Find type name
                        start_type := j;
                        while (j < len body && ((body[j] >= 'a' && body[j] <= 'z') ||
                                               (body[j] >= 'A' && body[j] <= 'Z') ||
                                               (body[j] >= '0' && body[j] <= '9') ||
                                               body[j] == '_' || body[j] == '-' || body[j] == '>'))
                            j++;

                        # Add variable name to result
                        result += varname;

                        # Skip whitespace and look for '=' or ';'
                        while (j < len body && (body[j] == ' ' || body[j] == '\t'))
                            j++;

                        if (j < len body && body[j] == '=') {
                            # 'var name: type = expr' -> 'name := expr'
                            result += " := ";
                            j++;  # skip '='

                            # Skip whitespace after '='
                            while (j < len body && (body[j] == ' ' || body[j] == '\t'))
                                j++;

                            # Copy the rest of the expression until ';'
                            while (j < len body && body[j] != ';' && body[j] != '\n') {
                                result[len result] = body[j];
                                j++;
                            }

                            # Skip the ';' if present
                            if (j < len body && body[j] == ';')
                                j++;

                            # Add semicolon and continue
                            result += ";\n";
                            i = j;
                            continue;
                        } else if (j < len body && body[j] == ';') {
                            # 'var name: type;' -> 'name : type;'
                            result += " : " + body[start_type:j] + ";\n";
                            j++;  # skip ';'
                            i = j;
                            continue;
                        }
                    }
                }
            }
        }

        # Copy character and continue
        result[len result] = body[i];
        i++;
    }

    return result;
}

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
    Ast->WIDGET_IMG =>
        return "label";
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
generate_widget(cg: ref Codegen, prog: ref Program, w: ref Widget, parent: string, is_root: int): string
{
    if (w == nil)
        return nil;

    # Skip wrapper widgets only (keep layout widgets!)
    if (w.is_wrapper) {
        return generate_widget_list(cg, prog, w.children, parent, is_root);
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
    if (is_root && prog.app != nil && prog.app.props != nil) {
        (w, ok) := get_number_prop(prog.app.props, "width");
        (h, ok2) := get_number_prop(prog.app.props, "height");
        if ((ok && w > 0) || (ok2 && h > 0)) {
            append_tk_cmd(cg, sys->sprint("%s configure -width %d -height %d", widget_path, w, h));
        }
    }

    # Process children FIRST (they need to be packed before this widget)
    if (w.children != nil) {
        err := generate_widget_list(cg, prog, w.children, widget_path, 0);
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
generate_widget_list(cg: ref Codegen, prog: ref Program, w: ref Widget, parent: string, is_root: int): string
{
    while (w != nil) {
        if (w.is_wrapper) {
            # Process children of wrapper with same parent
            child := w.children;
            while (child != nil) {
                if (child.is_wrapper) {
                    err := generate_widget_list(cg, prog, child.children, parent, is_root);
                    if (err != nil)
                        return err;
                } else {
                    err := generate_widget(cg, prog, child, parent, is_root);
                    if (err != nil)
                        return err;
                }
                child = child.next;
            }
        } else {
            # Generate widget normally (including layout widgets like Center/Column/Row)
            err := generate_widget(cg, prog, w, parent, is_root);
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

    return generate_widget_list(cg, prog, prog.app.body, ".", 1);
}

# Generate variable declarations
generate_const_decls(cg: ref Codegen, prog: ref Program): string
{
    cds := prog.consts;

    while (cds != nil) {
        # Generate: NAME: con value;
        sys->fprint(cg.output, "%s: con %s;\n", cds.name, cds.value);
        cds = cds.next;
    }

    if (prog.consts != nil)
        sys->fprint(cg.output, "\n");
    return nil;
}

generate_var_decls(cg: ref Codegen, prog: ref Program): string
{
    vds := prog.vars;

    while (vds != nil) {
        var_type := vds.typ;
        if (var_type == nil || var_type == "")
            var_type = "string";  # default fallback

        # Check if there's an initialization value
        if (vds.init_value != nil) {
            pick init_val := vds.init_value {
            String =>
                init_expr := sys->sprint("\"%s\"", init_val.string_val);
                sys->fprint(cg.output, "%s: %s = %s;\n", vds.name, var_type, init_expr);
            Number =>
                sys->fprint(cg.output, "%s: %s = %bd;\n", vds.name, var_type, init_val.number_val);
            Real =>
                sys->fprint(cg.output, "%s: %s = %g;\n", vds.name, var_type, init_val.real_val);
            Identifier =>
                sys->fprint(cg.output, "%s: %s = %s;\n", vds.name, var_type, init_val.ident_val);
            Color =>
                sys->fprint(cg.output, "%s: %s = %s;\n", vds.name, var_type, init_val.color_val);
            * =>
                # Array, FnCall - use init_expr string
                if (vds.init_expr != nil && len vds.init_expr > 0)
                    sys->fprint(cg.output, "%s: %s = %s;\n", vds.name, var_type, vds.init_expr);
                else
                    sys->fprint(cg.output, "%s: %s;\n", vds.name, var_type);
            }
        } else if (vds.init_expr != nil && len vds.init_expr > 0) {
            sys->fprint(cg.output, "%s: %s = %s;\n", vds.name, var_type, vds.init_expr);
        } else {
            sys->fprint(cg.output, "%s: %s;\n", vds.name, var_type);
        }
        vds = vds.next;
    }

    # Add display variable for Draw backend (needed for color access in user functions)
    if (cg.is_draw_backend) {
        sys->fprint(cg.output, "display: ref Draw->Display;\n");
    }

    sys->fprint(cg.output, "\n");
    return nil;
}

# Generate reactive function variables only (no functions)
generate_reactive_vars(cg: ref Codegen, prog: ref Program): string
{
    rfns := prog.reactive_fns;

    while (rfns != nil) {
        name := rfns.name;
        # Generate module variable for cached value
        sys->fprint(cg.output, "%s: string;\n", name);
        rfns = rfns.next;
    }

    # Add tpid variable for timer process tracking
    if (has_reactive_functions(prog)) {
        sys->fprint(cg.output, "tpid: int;\n");
    }

    sys->fprint(cg.output, "\n");
    return nil;
}

# Generate reactive update functions only (no variables)
generate_reactive_funcs(cg: ref Codegen, prog: ref Program): string
{
    rfns := prog.reactive_fns;

    while (rfns != nil) {
        name := rfns.name;
        expr := rfns.expression;

        if (rfns.interval > 0) {
            # Time-based: generate _update() function
            needs_t := 0;
            bindings := cg.reactive_bindings;
            while (bindings != nil) {
                (widget_path, prop_name, fn_name) := hd bindings;
                if (fn_name == name) {
                    needs_t = 1;
                    break;
                }
                bindings = tl bindings;
            }

            if (needs_t) {
                sys->fprint(cg.output, "%s_update(t: ref Tk->Toplevel)\n", name);
            } else {
                sys->fprint(cg.output, "%s_update()\n", name);
            }
            sys->fprint(cg.output, "{\n");
            sys->fprint(cg.output, "    %s = %s;\n", name, expr);

            # Generate widget updates
            all_bindings := cg.reactive_bindings;
            rev_bindings: list of (string, string, string) = nil;
            while (all_bindings != nil) {
                rev_bindings = hd all_bindings :: rev_bindings;
                all_bindings = tl all_bindings;
            }

            while (rev_bindings != nil) {
                (widget_path, prop_name, fn_name) := hd rev_bindings;
                if (fn_name == name) {
                    tk_prop := map_property_name(prop_name);
                    if (tk_prop != "") {
                        sys->fprint(cg.output, "    tk->cmd(t, \"%s configure -%s {\"+%s+\"};update\");\n",
                            widget_path, tk_prop, name);
                    }
                }
                rev_bindings = tl rev_bindings;
            }

            sys->fprint(cg.output, "}\n\n");
        } else {
            # Var-based: generate update function for each watched variable
            wv := rfns.watch_vars;
            while (wv != nil) {
                sys->fprint(cg.output, "%s_on_%s_change(t: ref Tk->Toplevel)\n", name, wv.name);
                sys->fprint(cg.output, "{\n");
                sys->fprint(cg.output, "    %s = %s;\n", name, expr);

                # Update widgets
                bindings := cg.reactive_bindings;
                while (bindings != nil) {
                    (widget_path, prop_name, fn_name) := hd bindings;
                    if (fn_name == name) {
                        tk_prop := map_property_name(prop_name);
                        if (tk_prop != "") {
                            sys->fprint(cg.output, "    tk->cmd(t, \"%s configure -%s {\"+%s+\"};update\");\n",
                                widget_path, tk_prop, name);
                        }
                    }
                    bindings = tl bindings;
                }

                sys->fprint(cg.output, "}\n\n");
                wv = wv.next;
            }
        }

        rfns = rfns.next;
    }

    # Also generate update functions for FunctionDecl with reactive_interval
    fd := prog.function_decls;
    while (fd != nil) {
        if (fd.reactive_interval > 0) {
            # Time-based: generate _update() function
            needs_t := 0;
            bindings := cg.reactive_bindings;
            while (bindings != nil) {
                (widget_path, prop_name, fn_name) := hd bindings;
                if (fn_name == fd.name) {
                    needs_t = 1;
                    break;
                }
                bindings = tl bindings;
            }

            if (needs_t) {
                sys->fprint(cg.output, "%s_update(t: ref Tk->Toplevel)\n", fd.name);
            } else {
                sys->fprint(cg.output, "%s_update()\n", fd.name);
            }
            sys->fprint(cg.output, "{\n");

            # Generate widget updates for FunctionDecl
            # For functions, we call the function directly in the widget update
            all_bindings := cg.reactive_bindings;
            rev_bindings: list of (string, string, string) = nil;
            while (all_bindings != nil) {
                rev_bindings = hd all_bindings :: rev_bindings;
                all_bindings = tl all_bindings;
            }

            while (rev_bindings != nil) {
                (widget_path, prop_name, fn_name) := hd rev_bindings;
                if (fn_name == fd.name) {
                    tk_prop := map_property_name(prop_name);
                    if (tk_prop != "") {
                        sys->fprint(cg.output, "    tk->cmd(t, \"%s configure -%s {\"+%s()+\"};update\");\n",
                            widget_path, tk_prop, fd.name);
                    }
                }
                rev_bindings = tl rev_bindings;
            }

            sys->fprint(cg.output, "}\n\n");
        }
        fd = fd.next;
    }

    return nil;
}

# Check if program has time-based reactive functions
has_time_based_reactive_functions(prog: ref Program): int
{
    rfns := prog.reactive_fns;
    while (rfns != nil) {
        if (rfns.interval > 0)
            return 1;
        rfns = rfns.next;
    }
    # Also check FunctionDecl for reactive_interval
    fd := prog.function_decls;
    while (fd != nil) {
        if (fd.reactive_interval > 0)
            return 1;
        fd = fd.next;
    }
    return 0;
}

# Generate reactive timer function
generate_reactive_timer(cg: ref Codegen, prog: ref Program): string
{
    # Find the minimum interval among time-based functions
    min_interval := 1000000;
    rfns := prog.reactive_fns;

    while (rfns != nil) {
        if (rfns.interval > 0 && rfns.interval < min_interval)
            min_interval = rfns.interval;
        rfns = rfns.next;
    }

    # Also check FunctionDecl for reactive_interval
    fd := prog.function_decls;
    while (fd != nil) {
        if (fd.reactive_interval > 0 && fd.reactive_interval < min_interval)
            min_interval = fd.reactive_interval;
        fd = fd.next;
    }

    if (min_interval >= 1000000)
        return nil;

    # Generate timer function
    sys->fprint(cg.output, "timer(c: chan of int)\n");
    sys->fprint(cg.output, "{\n");
    sys->fprint(cg.output, "    tpid = sys->pctl(0, nil);\n");
    sys->fprint(cg.output, "    for(;;) {\n");
    sys->fprint(cg.output, "        c <-= 1;\n");
    sys->fprint(cg.output, "        sys->sleep(%d);\n", min_interval);
    sys->fprint(cg.output, "    }\n");
    sys->fprint(cg.output, "}\n\n");

    return nil;
}

# Check if program has reactive functions
has_reactive_functions(prog: ref Program): int
{
    return has_time_based_reactive_functions(prog);
}

# Generate module load statements in init
generate_module_loads(cg: ref Codegen, prog: ref Program): string
{
    imports := prog.module_imports;

    while (imports != nil) {
        module_name := imports.module_name;
        alias := imports.alias;

        if (alias == nil || alias == "") {
            alias = module_name;
        }

        # Generate type name (capitalized)
        type_name := alias;
        if (len type_name > 0) {
            first := type_name[0];
            if (first >= 'a' && first <= 'z') {
                type_name = sys->sprint("%c", first - ('a' - 'A')) + type_name[1:];
            }
        }

        # Generate load statement
        # The load path uses the capitalized type name
        sys->fprint(cg.output, "    %s = load %s %s->PATH;\n",
            alias, type_name, type_name);

        imports = imports.next;
    }

    return nil;
}

# Check if module name is already in module list
module_list_contains(mods: list of ref Module, name: string): int
{
    while (mods != nil) {
        if ((hd mods).mod_file == name)
            return 1;
        mods = tl mods;
    }
    return 0;
}

# Check if program needs Graphics module (Canvas widgets or Graphics method calls)
needs_graphics_module(prog: ref Program): int
{
    if (prog == nil)
        return 0;

    # Check if there are Canvas widgets
    if (prog.app != nil && prog.app.body != nil) {
        if (has_canvas_widget(prog.app.body))
            return 1;
    }

    # Check function declarations for Graphics context parameters
    fd := prog.function_decls;
    while (fd != nil) {
        # Check if params contain Graphics type or ctx parameter
        if (fd.params != nil) {
            params := fd.params;
            # Simple check for "Graphics" or "ctx" in params
            if (params_contains_graphics(params))
                return 1;
        }

        # Check function body for Graphics method calls
        if (fd.body != nil && has_graphics_in_statement(fd.body))
            return 1;

        fd = fd.next;
    }

    return 0;
}

# Check if params string contains Graphics or ctx
params_contains_graphics(params: string): int
{
    if (params == nil || len params == 0)
        return 0;

    # Simple substring search for "Graphics" or "ctx"
    i := 0;

    # Check for Graphics type
    for (i = 0; i < len params - 7; i++) {
        if (params[i:i+8] == "Graphics")
            return 1;
    }

    # Check for ctx identifier
    for (i = 0; i < len params - 2; i++) {
        if (params[i:i+3] == "ctx")
            return 1;
    }

    return 0;
}

# Recursively check if widget tree contains Canvas
has_canvas_widget(w: ref Widget): int
{
    while (w != nil) {
        if (w.wtype == Ast->WIDGET_CANVAS)
            return 1;

        # Check children
        if (w.children != nil && has_canvas_widget(w.children))
            return 1;

        w = w.next;
    }
    return 0;
}

# Recursively check if statement contains Graphics method call
has_graphics_in_statement(stmt: ref Ast->Statement): int
{
    if (stmt == nil)
        return 0;

    pick s := stmt {
    Expr =>
        if (s.expression != nil && has_graphics_call(s.expression))
            return 1;
    Block =>
        sub := s.statements;
        while (sub != nil) {
            if (has_graphics_in_statement(sub))
                return 1;
            sub = sub.next;
        }
    If =>
        if (has_graphics_in_statement(s.then_stmt))
            return 1;
        if (s.else_stmt != nil && has_graphics_in_statement(s.else_stmt))
            return 1;
    For =>
        if (has_graphics_in_statement(s.init))
            return 1;
        if (s.body != nil && has_graphics_in_statement(s.body))
            return 1;
    While =>
        if (s.body != nil && has_graphics_in_statement(s.body))
            return 1;
    Return =>
        if (s.expression != nil && has_graphics_call(s.expression))
            return 1;
    * =>
        # Skip other types
    }

    # Check next in chain
    if (stmt.next != nil)
        return has_graphics_in_statement(stmt.next);

    return 0;
}

# Generate prologue
generate_prologue(cg: ref Codegen, prog: ref Program): string
{
    buf := "";

    buf += sys->sprint("implement %s;\n\n", cg.module_name);

    # Determine backend
    is_draw := 0;
    if (prog.window_type == 1)
        is_draw = 1;
    cg.is_draw_backend = is_draw;

    # Build list of all modules (required + user imports)
    modules: list of ref Module = nil;

    # Required modules - added in reverse order (after reversal, these come last)
    modules = ref Module("sys", "sys", "Sys") :: modules;
    modules = ref Module("draw", "draw", "Draw") :: modules;
    modules = ref Module("daytime", "daytime", "Daytime") :: modules;

    if (is_draw) {

        # Check if Graphics module is needed (Canvas widgets with onDraw)
        if (needs_graphics_module(prog)) {
            modules = ref Module("graphics", "graphics", "Graphics") :: modules;
        }

        # math module (for math functions)
        modules = ref Module("math", "math", "Math") :: modules;

        # tk must come before wmclient - add wmclient first (it goes to front)
        modules = ref Module("wmclient", "wmclient", "Wmclient") :: modules;
        modules = ref Module("tk", "tk", "Tk") :: modules;
    } else {
        # Check if Graphics is needed for Tk backend (Canvas widgets)
        if (needs_graphics_module(prog)) {
            modules = ref Module("graphics", "graphics", "Graphics") :: modules;
        }
        modules = ref Module("tkclient", "tkclient", "Tkclient") :: modules;
        modules = ref Module("tk", "tk", "Tk") :: modules;
    }

    # Add user imports, skip duplicates
    imports := prog.module_imports;
    while (imports != nil) {
        module_name := imports.module_name;
        if (!module_list_contains(modules, module_name)) {
            alias := imports.alias;
            if (alias == nil || alias == "")
                alias = module_name;

            type_name := alias;
            if (len type_name > 0) {
                first := type_name[0];
                if (first >= 'a' && first <= 'z') {
                    type_name = sys->sprint("%c", first - ('a' - 'A')) + type_name[1:];
                }
            }

            modules = ref Module(module_name, alias, type_name) :: modules;
        }
        imports = imports.next;
    }

    # Reverse to get original order
    rev_modules: list of ref Module = nil;
    while (modules != nil) {
        rev_modules = hd modules :: rev_modules;
        modules = tl modules;
    }

    # Output all modules with proper formatting
    mods := rev_modules;
    while (mods != nil) {
        m := hd mods;
        buf += sys->sprint("include \"%s.m\";\n", m.mod_file);
        buf += sys->sprint("\t%s: %s;\n", m.var_name, m.type_name);
        buf += "\n";
        mods = tl mods;
    }

    # Add Draw type imports for wmclient backend
    if (is_draw) {
        buf += "Display, Image, Point, Rect: import draw;\n";
        buf += "Window: import wmclient;\n";
        buf += "\n";
    }

    # Generate module declaration
    buf += sys->sprint("%s: module\n{\n", cg.module_name);
    buf += "    init:\tfn(ctxt: ref Draw->Context, argv: list of string);\n";

    # Add function signatures from function_decls
    fd := prog.function_decls;
    while (fd != nil) {
        transformed_params := transform_params_graphics(fd.params);
        if (fd.return_type != nil && fd.return_type != "")
            buf += sys->sprint("    %s: fn(%s): %s;\n", fd.name, transformed_params, fd.return_type);
        else
            buf += sys->sprint("    %s: fn(%s);\n", fd.name, transformed_params);
        fd = fd.next;
    }

    buf += "};\n";

    # Generate struct declarations (ADTs)
    sd := prog.struct_decls;
    while (sd != nil) {
        buf += sys->sprint("\n%s: adt {\n", sd.name);
        field := sd.fields;
        while (field != nil) {
            buf += sys->sprint("    %s: %s;\n", field.name, field.typename);
            field = field.next;
        }
        buf += "};\n";
        sd = sd.next;
    }

    # Write prologue
    sys->fprint(cg.output, "%s", buf);

    return nil;
}

# Get default value for a type (for type-only variable declarations)
get_default_value_for_type(typ: string): string
{
    if (typ == nil || typ == "")
        return "0";

    # Handle basic types
    if (typ == "int" || typ == "byte" || typ == "big")
        return "0";
    if (typ == "real")
        return "0.0";
    if (typ == "string")
        return "\"\"";
    if (typ == "bool")
        return "0";

    # Handle array types - return nil for arrays
    if (len typ > 6 && typ[0:6] == "array of")
        return "nil";

    # Handle chan types - return nil for channels
    if (len typ > 5 && typ[0:4] == "chan")
        return "nil";

    # For ref types (objects, modules), return nil
    if (len typ > 4 && typ[0:3] == "ref")
        return "nil";

    # For list types, return nil
    if (len typ > 5 && typ[0:9] == "list of")
        return "nil";

    # Default fallback
    return "nil";
}

# Generate code for a single statement without processing next chain
# Used when iterating through statement lists in Blocks
generate_statement_no_next(cg: ref Codegen, stmt: ref Ast->Statement, indent: int): string
{
    if (stmt == nil)
        return nil;

    # Build indent string
    indent_str := "";
    for (i := 0; i < indent; i++)
        indent_str += "    ";

    # Generate based on statement type (no next processing at end)
    pick s := stmt {
    VarDecl =>
        if (s.var_decl != nil) {
            if (s.var_decl.init_expr != nil && len s.var_decl.init_expr > 0) {
                # Check if type annotation is present
                if (s.var_decl.typ != nil && len s.var_decl.typ > 0)
                    # Preserve type annotation: name: type = value
                    sys->fprint(cg.output, "%s%s: %s = %s;\n", indent_str, s.var_decl.name, s.var_decl.typ, s.var_decl.init_expr);
                else
                    # Type-inferred: name := value
                    sys->fprint(cg.output, "%s%s := %s;\n", indent_str, s.var_decl.name, s.var_decl.init_expr);
            } else {
                # Type-only declaration - generate proper initialization
                # In Limbo, we must use := with a value, not "name : type;"
                default_val := get_default_value_for_type(s.var_decl.typ);
                sys->fprint(cg.output, "%s%s := %s;\n", indent_str, s.var_decl.name, default_val);
            }
        }
    Block =>
        sys->fprint(cg.output, "%s{\n", indent_str);
        sub_stmt := s.statements;
        while (sub_stmt != nil) {
            generate_statement_no_next(cg, sub_stmt, indent + 1);
            sub_stmt = sub_stmt.next;
        }
        sys->fprint(cg.output, "%s}\n", indent_str);
    If =>
        sys->fprint(cg.output, "%sif (%s) ", indent_str, s.condition);
        # Generate if body - unwrap if it's a Block to avoid double braces
        if (s.then_stmt != nil) {
            pick then_body := s.then_stmt {
            Block =>
                # For block statements, generate the opening brace, then contents directly
                sys->fprint(cg.output, "{\n");
                sub_stmt := then_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                # For single statements, wrap in braces
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.then_stmt, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        } else {
            sys->fprint(cg.output, "{}\n");
        }

        # Handle else clause similarly
        if (s.else_stmt != nil) {
            sys->fprint(cg.output, "%selse ", indent_str);
            pick else_body := s.else_stmt {
            Block =>
                sys->fprint(cg.output, "{\n");
                sub_stmt := else_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.else_stmt, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        }
    For =>
        sys->fprint(cg.output, "%sfor (", indent_str);
        if (s.init != nil) {
            pick i := s.init {
            VarDecl =>
                if (i.var_decl.init_expr != nil && len i.var_decl.init_expr > 0) {
                    # Check if type annotation is present
                    if (i.var_decl.typ != nil && len i.var_decl.typ > 0)
                        # Preserve type annotation: name: type = value
                        sys->fprint(cg.output, "%s: %s = %s", i.var_decl.name, i.var_decl.typ, i.var_decl.init_expr);
                    else
                        # Type-inferred: name := value
                        sys->fprint(cg.output, "%s := %s", i.var_decl.name, i.var_decl.init_expr);
                } else {
                    # Type-only in for loop init - use default value
                    default_val := get_default_value_for_type(i.var_decl.typ);
                    sys->fprint(cg.output, "%s := %s", i.var_decl.name, default_val);
                }
            Expr =>
                sys->fprint(cg.output, "%s", i.expression);
            * =>
                {}
            }
        }
        sys->fprint(cg.output, "; %s; %s) ", s.condition, s.increment);
        # Generate for body - unwrap if it's a Block to avoid double braces
        if (s.body != nil) {
            pick for_body := s.body {
            Block =>
                # For block statements, generate the opening brace, then contents directly
                sys->fprint(cg.output, "{\n");
                sub_stmt := for_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                # For single statements, wrap in braces
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.body, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        } else {
            sys->fprint(cg.output, "{}\n");
        }
    While =>
        sys->fprint(cg.output, "%swhile (%s) ", indent_str, s.condition);
        # Generate while body - unwrap if it's a Block to avoid double braces
        if (s.body != nil) {
            pick while_body := s.body {
            Block =>
                # For block statements, generate the opening brace, then contents directly
                sys->fprint(cg.output, "{\n");
                sub_stmt := while_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                # For single statements, wrap in braces
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.body, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        } else {
            sys->fprint(cg.output, "{}\n");
        }
    Return =>
        if (s.expression != nil && len s.expression > 0)
            sys->fprint(cg.output, "%sreturn %s;\n", indent_str, s.expression);
        else
            sys->fprint(cg.output, "%sreturn;\n", indent_str);
    Expr =>
        if (s.expression != nil && len s.expression > 0) {
            (is_graphics, transformed, color_decls) := transform_graphics_call(s.expression);
            if (is_graphics) {
                if (color_decls != nil && len color_decls > 0)
                    sys->fprint(cg.output, "%s%s\n", indent_str, color_decls);
                sys->fprint(cg.output, "%s%s;\n", indent_str, transformed);
            } else {
                (transformed, decls) := transform_color_arg(s.expression);
                if (decls != nil && len decls > 0)
                    sys->fprint(cg.output, "%s%s\n", indent_str, decls);
                sys->fprint(cg.output, "%s%s;\n", indent_str, transformed);
            }
        }
    * =>
        # Skip other types
    }

    return nil;
}

# Generate code for a single statement
generate_statement(cg: ref Codegen, stmt: ref Ast->Statement, indent: int): string
{
    if (stmt == nil)
        return nil;

    # Build indent string
    indent_str := "";
    for (i := 0; i < indent; i++)
        indent_str += "    ";

    # Generate based on statement type
    pick s := stmt {
    VarDecl =>
        # Local variable declaration
        if (s.var_decl != nil) {
            if (s.var_decl.init_expr != nil && len s.var_decl.init_expr > 0) {
                # var with initialization: name := value
                sys->fprint(cg.output, "%s%s := %s;\n", indent_str, s.var_decl.name, s.var_decl.init_expr);
            } else {
                # Type-only declaration - generate proper initialization
                default_val := get_default_value_for_type(s.var_decl.typ);
                sys->fprint(cg.output, "%s%s := %s;\n", indent_str, s.var_decl.name, default_val);
            }
        }

    Block =>
        sys->fprint(cg.output, "%s{\n", indent_str);
        sub_stmt := s.statements;
        while (sub_stmt != nil) {
            # Process sub-statement inline to avoid double-processing of next chain
            pick sub := sub_stmt {
            VarDecl =>
                if (sub.var_decl != nil) {
                    if (sub.var_decl.init_expr != nil && len sub.var_decl.init_expr > 0) {
                        # Check if type annotation is present
                        if (sub.var_decl.typ != nil && len sub.var_decl.typ > 0)
                            # Preserve type annotation: name: type = value
                            sys->fprint(cg.output, "%s%s: %s = %s;\n", indent_str + "    ", sub.var_decl.name, sub.var_decl.typ, sub.var_decl.init_expr);
                        else
                            # Type-inferred: name := value
                            sys->fprint(cg.output, "%s%s := %s;\n", indent_str + "    ", sub.var_decl.name, sub.var_decl.init_expr);
                    } else {
                        # Type-only declaration - generate proper initialization
                        # In Limbo, we must use := with a value, not "name : type;"
                        default_val := get_default_value_for_type(sub.var_decl.typ);
                        sys->fprint(cg.output, "%s%s := %s;\n", indent_str + "    ", sub.var_decl.name, default_val);
                    }
                }
            Expr =>
                if (sub.expression != nil && len sub.expression > 0) {
                    (is_g, trans, decls) := transform_graphics_call(sub.expression);
                    if (is_g) {
                        if (decls != nil && len decls > 0)
                            sys->fprint(cg.output, "%s%s\n", indent_str + "    ", decls);
                        sys->fprint(cg.output, "%s%s;\n", indent_str + "    ", trans);
                    } else {
                        (trans, d) := transform_color_arg(sub.expression);
                        if (d != nil && len d > 0)
                            sys->fprint(cg.output, "%s%s\n", indent_str + "    ", d);
                        sys->fprint(cg.output, "%s%s;\n", indent_str + "    ", trans);
                    }
                }
            Return =>
                if (sub.expression != nil && len sub.expression > 0)
                    sys->fprint(cg.output, "%sreturn %s;\n", indent_str + "    ", sub.expression);
                else
                    sys->fprint(cg.output, "%sreturn;\n", indent_str + "    ");
            * =>
                # For complex statements (If, For, While, Block), use generate_statement but don't process next
                generate_statement_no_next(cg, sub_stmt, indent + 1);
            }
            sub_stmt = sub_stmt.next;
        }
        sys->fprint(cg.output, "%s}\n", indent_str);

    If =>
        # if (condition) then_stmt [else else_stmt]
        sys->fprint(cg.output, "%sif (%s) ", indent_str, s.condition);
        # Generate if body - unwrap if it's a Block to avoid double braces
        if (s.then_stmt != nil) {
            pick then_body := s.then_stmt {
            Block =>
                sys->fprint(cg.output, "{\n");
                sub_stmt := then_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.then_stmt, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        } else {
            sys->fprint(cg.output, "{}\n");
        }

        # Handle else clause similarly
        if (s.else_stmt != nil) {
            sys->fprint(cg.output, "%selse ", indent_str);
            pick else_body := s.else_stmt {
            Block =>
                sys->fprint(cg.output, "{\n");
                sub_stmt := else_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.else_stmt, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        }

    For =>
        # for (init; condition; increment) body
        sys->fprint(cg.output, "%sfor (", indent_str);

        # Init
        if (s.init != nil) {
            pick i := s.init {
            VarDecl =>
                if (i.var_decl.init_expr != nil && len i.var_decl.init_expr > 0) {
                    # Check if type annotation is present
                    if (i.var_decl.typ != nil && len i.var_decl.typ > 0)
                        # Preserve type annotation: name: type = value
                        sys->fprint(cg.output, "%s: %s = %s", i.var_decl.name, i.var_decl.typ, i.var_decl.init_expr);
                    else
                        # Type-inferred: name := value
                        sys->fprint(cg.output, "%s := %s", i.var_decl.name, i.var_decl.init_expr);
                } else {
                    # Type-only in for loop init - use default value
                    default_val := get_default_value_for_type(i.var_decl.typ);
                    sys->fprint(cg.output, "%s := %s", i.var_decl.name, default_val);
                }
            Expr =>
                sys->fprint(cg.output, "%s", i.expression);
            * =>
                # Skip other statement types as init
            }
        }

        sys->fprint(cg.output, "; %s; %s) ", s.condition, s.increment);
        # Generate for body - unwrap if it's a Block to avoid double braces
        if (s.body != nil) {
            pick for_body := s.body {
            Block =>
                sys->fprint(cg.output, "{\n");
                sub_stmt := for_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.body, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        } else {
            sys->fprint(cg.output, "{}\n");
        }

    While =>
        # while (condition) body
        sys->fprint(cg.output, "%swhile (%s) ", indent_str, s.condition);
        # Generate while body - unwrap if it's a Block to avoid double braces
        if (s.body != nil) {
            pick while_body := s.body {
            Block =>
                sys->fprint(cg.output, "{\n");
                sub_stmt := while_body.statements;
                while (sub_stmt != nil) {
                    generate_statement_no_next(cg, sub_stmt, indent + 1);
                    sub_stmt = sub_stmt.next;
                }
                sys->fprint(cg.output, "%s}\n", indent_str);
            * =>
                sys->fprint(cg.output, "{\n");
                generate_statement_no_next(cg, s.body, indent + 1);
                sys->fprint(cg.output, "%s}\n", indent_str);
            }
        } else {
            sys->fprint(cg.output, "{}\n");
        }

    Return =>
        # return expression;
        if (s.expression != nil && len s.expression > 0)
            sys->fprint(cg.output, "%sreturn %s;\n", indent_str, s.expression);
        else
            sys->fprint(cg.output, "%sreturn;\n", indent_str);

    Expr =>
        # expression statement
        if (s.expression != nil && len s.expression > 0) {
            # Check if this is a Graphics method call that needs transformation
            (is_graphics, transformed, color_decls) := transform_graphics_call(s.expression);
            if (is_graphics) {
                # Output any color declarations first
                if (color_decls != nil && len color_decls > 0)
                    sys->fprint(cg.output, "%s%s\n", indent_str, color_decls);
                sys->fprint(cg.output, "%s%s;\n", indent_str, transformed);
            } else {
                # Check for Color expressions and transform them
                (transformed, decls) := transform_color_arg(s.expression);
                if (decls != nil && len decls > 0)
                    sys->fprint(cg.output, "%s%s\n", indent_str, decls);
                sys->fprint(cg.output, "%s%s;\n", indent_str, transformed);
            }
        }
    }

    # Process next statement in chain
    if (stmt.next != nil)
        generate_statement(cg, stmt.next, indent);

    return nil;
}

# Transform Graphics type in params string to ref Graphics->Context
transform_params_graphics(params: string): string
{
    if (params == nil || len params == 0)
        return params;

    # Look for ": Graphics" or ":Graphics" pattern and replace
    result := "";
    i := 0;

    while (i < len params) {
        # Check for "Graphics" as a type (after :)
        if (i + 8 <= len params && params[i:i+8] == "Graphics") {
            # Check if this is followed by non-identifier char (end or , or ))
            # Check if preceded by : or space+:
            valid := 0;
            if (i >= 1 && params[i-1] == ':')
                valid = 1;
            else if (i >= 2 && params[i-2] == ':' && params[i-1] == ' ')
                valid = 1;

            if (valid) {
                # Replace "Graphics" with "ref Graphics->Context"
                result += "ref Graphics->Context";
                i += 8;
                continue;
            }
        }

        result[len result] = params[i];
        i++;
    }

    return result;
}

# Generate code blocks (Limbo functions)
generate_code_blocks(cg: ref Codegen, prog: ref Program): string
{
    # Generate function bodies from function_decls
    fd := prog.function_decls;

    while (fd != nil) {
        # Transform Graphics types in params
        transformed_params := transform_params_graphics(fd.params);

        if (fd.return_type != nil && fd.return_type != "")
            sys->fprint(cg.output, "\n%s(%s): %s\n", fd.name, transformed_params, fd.return_type);
        else
            sys->fprint(cg.output, "\n%s(%s)\n", fd.name, transformed_params);
        sys->fprint(cg.output, "{\n");

        # Generate statements from the parsed AST
        # If the body is a Block statement, generate its contents directly
        # to avoid double braces (the function already opens with { and closes with })
        if (fd.body != nil) {
            # Check if body is a Block - if so, generate its statements directly
            pick b := fd.body {
            Block =>
                # Generate block contents directly without extra braces
                sub_stmt := b.statements;
                while (sub_stmt != nil) {
                    # Use generate_statement_no_next since we're iterating manually
                    generate_statement_no_next(cg, sub_stmt, 1);
                    sub_stmt = sub_stmt.next;
                }
            * =>
                # For non-block bodies (single statement), generate normally
                generate_statement_no_next(cg, fd.body, 1);
            }
        }

        sys->fprint(cg.output, "}\n");
        fd = fd.next;
    }

    return nil;
}

# Generate tkcmds array
generate_tkcmds_array(cg: ref Codegen, prog: ref Program): string
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

    # Only add pack propagate if width/height were explicitly set on the Window
    # This prevents the window from auto-sizing when dimensions are specified
    has_width := 0;
    has_height := 0;
    if (prog.app != nil && prog.app.props != nil) {
        (w, ok) := get_number_prop(prog.app.props, "width");
        if (ok && w > 0)
            has_width = 1;
        (h, ok2) := get_number_prop(prog.app.props, "height");
        if (ok2 && h > 0)
            has_height = 1;
    }

    if (has_width || has_height) {
        sys->fprint(cg.output, "    \"pack propagate . 0\",\n");
    }
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

# Check if widget has a specific property
has_property(props: ref Property, name: string): int
{
    while (props != nil) {
        if (props.name == name)
            return 1;
        props = props.next;
    }
    return 0;
}

# Parse reactive binding "fn_name@interval" -> (fn_name, interval)
parse_reactive_binding(ident: string): (string, int)
{
    if (ident == nil)
        return (nil, 0);

    for (i := 0; i < len ident; i++) {
        if (ident[i] == '@') {
            fn_name := ident[0:i];
            interval_str := ident[i+1:];
            interval := 0;
            if (interval_str != nil && len interval_str > 0) {
                for (j := 0; j < len interval_str; j++) {
                    c := interval_str[j];
                    if (c >= '0' && c <= '9') {
                        interval = interval * 10 + (c - '0');
                    }
                }
            }
            return (fn_name, interval);
        }
    }
    return (ident, 0);
}

# Check if program should use Draw backend
# Returns true if:
# 1. Window has onDraw property (old behavior)
# 2. Program contains Canvas widgets (new)
# 3. Program uses Graphics API (Graphics type params or ctx.method calls) (new)
should_use_draw_backend(prog: ref Program): int
{
    if (prog == nil || prog.app == nil)
        return 0;

    # Check for onDraw property on Window (old behavior)
    if (prog.app.props != nil && has_property(prog.app.props, "onDraw"))
        return 1;

    # Check for Canvas widgets
    if (prog.app.body != nil && has_canvas_widget(prog.app.body))
        return 1;

    # Check for Graphics API usage
    if (needs_graphics_module(prog))
        return 1;

    return 0;
}

# Find the onDraw property from the first Canvas widget
# Returns (function_name, interval)
find_canvas_ondraw(w: ref Widget): (string, int)
{
    while (w != nil) {
        if (w.wtype == Ast->WIDGET_CANVAS && w.props != nil) {
            p := w.props;
            while (p != nil) {
                if (p.name == "onDraw" && p.value != nil) {
                    if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                        return parse_reactive_binding(ast->value_get_ident(p.value));
                    }
                }
                p = p.next;
            }
        }

        # Check children recursively
        if (w.children != nil) {
            (fn_name, interval) := find_canvas_ondraw(w.children);
            if (fn_name != nil && fn_name != "")
                return (fn_name, interval);
        }

        w = w.next;
    }
    return ("", 0);
}

# Check if a function uses Graphics context (has Graphics or ctx in params)
function_uses_graphics(prog: ref Program, fn_name: string): int
{
    if (prog == nil || fn_name == nil)
        return 0;

    fd := prog.function_decls;
    while (fd != nil) {
        if (fd.name == fn_name) {
            # Check params for Graphics type
            return params_contains_graphics(fd.params);
        }
        fd = fd.next;
    }
    return 0;
}

# Generate Draw/wmclient backend init
generate_draw_init(cg: ref Codegen, prog: ref Program): string
{
    # Extract properties
    ondraw_fn := "";
    ondraw_interval := 0;
    oninit_fn := "";
    window_type := "Appl";
    onmousedown_fn := "";
    onmouseup_fn := "";
    onmousemove_fn := "";

    if (prog.app != nil && prog.app.props != nil) {
        p := prog.app.props;
        while (p != nil) {
            if (p.name == "onDraw" && p.value != nil) {
                if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                    (fname, interval) := parse_reactive_binding(ast->value_get_ident(p.value));
                    ondraw_fn = fname;
                    ondraw_interval = interval;
                }
            } else if (p.name == "onInit" && p.value != nil) {
                if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                    oninit_fn = ast->value_get_ident(p.value);
                }
            } else if (p.name == "type" && p.value != nil) {
                if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                    window_type = ast->value_get_ident(p.value);
                }
            } else if (p.name == "onMouseDown" && p.value != nil) {
                if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                    onmousedown_fn = ast->value_get_ident(p.value);
                }
            } else if (p.name == "onMouseUp" && p.value != nil) {
                if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                    onmouseup_fn = ast->value_get_ident(p.value);
                }
            } else if (p.name == "onMouseMove" && p.value != nil) {
                if (p.value.valtype == Ast->VALUE_IDENTIFIER) {
                    onmousemove_fn = ast->value_get_ident(p.value);
                }
            }
            p = p.next;
        }
    }

    # Also check Canvas widgets for onDraw property
    if (ondraw_fn == nil || ondraw_fn == "") {
        if (prog.app != nil && prog.app.body != nil) {
            (canvas_on_draw, canvas_interval) := find_canvas_ondraw(prog.app.body);
            if (canvas_on_draw != nil && canvas_on_draw != "") {
                ondraw_fn = canvas_on_draw;
                ondraw_interval = canvas_interval;
            }
        }
    }

    cg.ondraw_fn = ondraw_fn;
    cg.ondraw_interval = ondraw_interval;
    cg.oninit_fn = oninit_fn;

    # Get window props
    title := "Application";
    width := 100;
    height := 100;

    if (prog.app != nil && prog.app.props != nil) {
        t := get_string_prop(prog.app.props, "title");
        if (t != nil)
            title = t;
        (w, ok) := get_number_prop(prog.app.props, "width");
        if (ok)
            width = w;
        (h, ok2) := get_number_prop(prog.app.props, "height");
        if (ok2)
            height = h;
    }

    # ZP constant
    sys->fprint(cg.output, "ZP := Point(0, 0);\n\n");

    # timer function
    sys->fprint(cg.output, "timer(c: chan of int, ms: int)\n");
    sys->fprint(cg.output, "{\n");
    sys->fprint(cg.output, "    for(;;){\n");
    sys->fprint(cg.output, "        sys->sleep(ms);\n");
    sys->fprint(cg.output, "        c <-= 1;\n");
    sys->fprint(cg.output, "    }\n");
    sys->fprint(cg.output, "}\n\n");

    sys->fprint(cg.output, "init(ctxt: ref Draw->Context, nil: list of string)\n");
    sys->fprint(cg.output, "{\n");
    sys->fprint(cg.output, "    sys = load Sys Sys->PATH;\n");
    sys->fprint(cg.output, "    draw = load Draw Draw->PATH;\n");
    # Only load Graphics module if it's actually needed (Canvas with onDraw, or Graphics context params)
    if (needs_graphics_module(prog)) {
        sys->fprint(cg.output, "    graphics = load Graphics Graphics->PATH;\n");
    }
    sys->fprint(cg.output, "    daytime = load Daytime Daytime->PATH;\n");
    sys->fprint(cg.output, "    math = load Math Math->PATH;\n");
    sys->fprint(cg.output, "    wmclient = load Wmclient Wmclient->PATH;\n");

    # Load user modules (skip built-in ones: sys, draw, math, wmclient)
    imports := prog.module_imports;
    while (imports != nil) {
        module_name := imports.module_name;
        # Skip built-in modules that are already loaded
        if (module_name != "sys" && module_name != "draw" &&
            module_name != "math" && module_name != "wmclient" &&
            module_name != "tk" && module_name != "tkclient") {
            alias := imports.alias;
            if (alias == nil || alias == "")
                alias = module_name;

            type_name := alias;
            if (len type_name > 0) {
                first := type_name[0];
                if (first >= 'a' && first <= 'z') {
                    type_name = sys->sprint("%c", first - ('a' - 'A')) + type_name[1:];
                }
            }

            sys->fprint(cg.output, "    %s = load %s %s->PATH;\n", alias, type_name, type_name);
        }
        imports = imports.next;
    }

    sys->fprint(cg.output, "\n");
    sys->fprint(cg.output, "    sys->pctl(Sys->NEWPGRP, nil);\n");
    sys->fprint(cg.output, "    wmclient->init();\n");
    sys->fprint(cg.output, "\n");
    sys->fprint(cg.output, "    if(ctxt == nil)\n");
    sys->fprint(cg.output, "        ctxt = wmclient->makedrawcontext();\n");
    sys->fprint(cg.output, "\n");
    sys->fprint(cg.output, "    w := wmclient->window(ctxt, \"%s\", Wmclient->%s);\n", title, window_type);
    sys->fprint(cg.output, "    display = w.display;\n");
    sys->fprint(cg.output, "\n");

    if (oninit_fn != nil && oninit_fn != "") {
        sys->fprint(cg.output, "    # Initialize colors\n");
        sys->fprint(cg.output, "    %s(display);\n", oninit_fn);
        sys->fprint(cg.output, "\n");
    }

    sys->fprint(cg.output, "    w.reshape(Rect((0, 0), (%d, %d)));\n", width, height);
    sys->fprint(cg.output, "    w.onscreen(\"place\");\n");
    sys->fprint(cg.output, "    w.startinput(\"ptr\" :: nil);\n");
    sys->fprint(cg.output, "\n");

    if (ondraw_fn != nil && ondraw_fn != "") {
        uses_graphics := function_uses_graphics(prog, ondraw_fn);
        if (uses_graphics) {
            sys->fprint(cg.output, "    now := daytime->now();\n");
            sys->fprint(cg.output, "    gctx := graphics->create(w.image, display);\n");
            sys->fprint(cg.output, "    %s(gctx, now);\n", ondraw_fn);
            sys->fprint(cg.output, "\n");
            sys->fprint(cg.output, "    ticks := chan of int;\n");
            sys->fprint(cg.output, "    spawn timer(ticks, %d);\n", ondraw_interval);
        } else {
            sys->fprint(cg.output, "    now := daytime->now();\n");
            sys->fprint(cg.output, "    %s(w.image, now);\n", ondraw_fn);
            sys->fprint(cg.output, "\n");
            sys->fprint(cg.output, "    ticks := chan of int;\n");
            sys->fprint(cg.output, "    spawn timer(ticks, %d);\n", ondraw_interval);
        }
    }

    # Event loop
    # Declare oldbuttons before loop if using mouse events
    if (onmousedown_fn != nil && onmousedown_fn != "" ||
        onmouseup_fn != nil && onmouseup_fn != "" ||
        onmousemove_fn != nil && onmousemove_fn != "") {
        sys->fprint(cg.output, "    oldbuttons := 0;\n");
    }
    sys->fprint(cg.output, "    for(;;){\n");
    sys->fprint(cg.output, "        alt{\n");
    sys->fprint(cg.output, "        ctl := <-w.ctl or\n");
    sys->fprint(cg.output, "        ctl = <-w.ctxt.ctl =>\n");
    sys->fprint(cg.output, "            w.wmctl(ctl);\n");
    sys->fprint(cg.output, "            if(ctl != nil && ctl[0] == '!')\n");
    if (ondraw_fn != nil && ondraw_fn != "") {
        uses_graphics := function_uses_graphics(prog, ondraw_fn);
        if (uses_graphics) {
            sys->fprint(cg.output, "                gctx := graphics->create(w.image, display);\n");
            sys->fprint(cg.output, "                %s(gctx, now);\n", ondraw_fn);
        } else {
            sys->fprint(cg.output, "                %s(w.image, now);\n", ondraw_fn);
        }
    } else {
        sys->fprint(cg.output, "                ;\n");
    }
    sys->fprint(cg.output, "\n");

    # Mouse events - use w.ctxt.ptr which is chan of ref Pointer
    if (onmousedown_fn != nil && onmousedown_fn != "" ||
        onmouseup_fn != nil && onmouseup_fn != "" ||
        onmousemove_fn != nil && onmousemove_fn != "") {
        sys->fprint(cg.output, "        p := <-w.ctxt.ptr =>\n");
        sys->fprint(cg.output, "            w.pointer(*p);\n");
        sys->fprint(cg.output, "            if(p != nil){\n");
        if (onmousedown_fn != nil && onmousedown_fn != "") {
            sys->fprint(cg.output, "                if(p.buttons != 0 && oldbuttons == 0)\n");
            sys->fprint(cg.output, "                    %s(p.xy.x, p.xy.y, p.buttons);\n", onmousedown_fn);
        }
        if (onmouseup_fn != nil && onmouseup_fn != "") {
            sys->fprint(cg.output, "                if(p.buttons == 0 && oldbuttons != 0)\n");
            sys->fprint(cg.output, "                    %s(p.xy.x, p.xy.y, oldbuttons);\n", onmouseup_fn);
        }
        if (onmousemove_fn != nil && onmousemove_fn != "") {
            sys->fprint(cg.output, "                if(p.buttons != 0)\n");
            sys->fprint(cg.output, "                    %s(p.xy.x, p.xy.y);\n", onmousemove_fn);
        }
        sys->fprint(cg.output, "                oldbuttons = p.buttons;\n");
        sys->fprint(cg.output, "            }\n");
        sys->fprint(cg.output, "\n");
    } else {
        sys->fprint(cg.output, "        p := <-w.ctxt.ptr =>\n");
        sys->fprint(cg.output, "            w.pointer(*p);\n");
        sys->fprint(cg.output, "\n");
    }

    if (ondraw_fn != nil && ondraw_fn != "") {
        uses_graphics := function_uses_graphics(prog, ondraw_fn);
        sys->fprint(cg.output, "        <-ticks =>\n");
        sys->fprint(cg.output, "            t := daytime->now();\n");
        sys->fprint(cg.output, "            if(t != now){\n");
        sys->fprint(cg.output, "                now = t;\n");
        if (uses_graphics) {
            sys->fprint(cg.output, "                gctx := graphics->create(w.image, display);\n");
            sys->fprint(cg.output, "                %s(gctx, now);\n", ondraw_fn);
        } else {
            sys->fprint(cg.output, "                %s(w.image, now);\n", ondraw_fn);
        }
        sys->fprint(cg.output, "            }\n");
    }

    sys->fprint(cg.output, "        }\n");
    sys->fprint(cg.output, "    }\n");
    sys->fprint(cg.output, "}\n");

    return nil;
}

# Generate init function
generate_init(cg: ref Codegen, prog: ref Program): string
{
    if (cg.is_draw_backend)
        return generate_draw_init(cg, prog);

    sys->fprint(cg.output, "init(ctxt: ref Draw->Context, argv: list of string)\n");
    sys->fprint(cg.output, "{\n");

    sys->fprint(cg.output, "    sys = load Sys Sys->PATH;\n");
    sys->fprint(cg.output, "    draw = load Draw Draw->PATH;\n");
    sys->fprint(cg.output, "    tk = load Tk Tk->PATH;\n");
    sys->fprint(cg.output, "    tkclient = load Tkclient Tkclient->PATH;\n");

    # Load modules from use statements
    err := generate_module_loads(cg, prog);
    if (err != nil) {
        return err;
    }

    sys->fprint(cg.output, "\n");
    sys->fprint(cg.output, "    sys->pctl(Sys->NEWPGRP, nil);\n");
    sys->fprint(cg.output, "    tkclient->init();\n\n");

    # Get app properties
    title := "Application";
    width := 0;
    height := 0;
    bg := "";

    if (prog.app != nil && prog.app.props != nil) {
        t := get_string_prop(prog.app.props, "title");
        if (t != nil)
            title = t;

        bg = get_string_prop(prog.app.props, "background");
        if (bg == nil)
            bg = get_string_prop(prog.app.props, "backgroundColor");

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

    sys->fprint(cg.output, "    (t, wmctl) := tkclient->toplevel(ctxt, \"\", \"%s\", 0);\n", title);
    if (width > 0 || height > 0) {
        sys->fprint(cg.output, "    tk->cmd(t, \"wm geometry . %dx%d\");\n", width, height);
    }
    if (bg != nil && bg != "") {
        sys->fprint(cg.output, "    tk->cmd(t, \"configure -background %s\");\n", bg);
    }
    sys->fprint(cg.output, "\n");

    # Initialize var declarations
    vds := prog.vars;
    while (vds != nil) {
        if (vds.init_expr != nil)
            sys->fprint(cg.output, "    %s = %s;\n", vds.name, vds.init_expr);
        vds = vds.next;
    }

    # Create command channel if we have callbacks
    has_callbacks := (cg.callbacks != nil);

    if (has_callbacks) {
        sys->fprint(cg.output, "    cmd := chan of string;\n");
        sys->fprint(cg.output, "    tk->namechan(t, cmd, \"cmd\");\n\n");
    }

    # Execute tk commands
    sys->fprint(cg.output, "    for (i := 0; i < len tkcmds; i++)\n");
    sys->fprint(cg.output, "        tk->cmd(t, tkcmds[i]);\n\n");

    # Setup reactive timer if we have reactive functions
    has_reactive := has_reactive_functions(prog);
    if (has_reactive) {
        sys->fprint(cg.output, "    tick := chan of int;\n");
        sys->fprint(cg.output, "    spawn timer(tick);\n\n");

        # Call initial reactive update
        rfns := prog.reactive_fns;
        while (rfns != nil) {
            # Only initialize time-based reactive functions
            if (rfns.interval > 0) {
                # Check if this function has widget bindings
                has_bindings := 0;
                bindings := cg.reactive_bindings;
                while (bindings != nil) {
                    (widget_path, prop_name, fn_name) := hd bindings;
                    if (fn_name == rfns.name) {
                        has_bindings = 1;
                        break;
                    }
                    bindings = tl bindings;
                }

                if (has_bindings) {
                    sys->fprint(cg.output, "    %s_update(t);\n", rfns.name);
                } else {
                    sys->fprint(cg.output, "    %s_update();\n", rfns.name);
                }
            }
            rfns = rfns.next;
        }

        # Also call initial update for FunctionDecl with reactive_interval
        fd := prog.function_decls;
        while (fd != nil) {
            if (fd.reactive_interval > 0) {
                # Check if this function has widget bindings
                has_bindings := 0;
                bindings := cg.reactive_bindings;
                while (bindings != nil) {
                    (widget_path, prop_name, fn_name) := hd bindings;
                    if (fn_name == fd.name) {
                        has_bindings = 1;
                        break;
                    }
                    bindings = tl bindings;
                }

                if (has_bindings) {
                    sys->fprint(cg.output, "    %s_update(t);\n", fd.name);
                } else {
                    sys->fprint(cg.output, "    %s_update();\n", fd.name);
                }
            }
            fd = fd.next;
        }
        sys->fprint(cg.output, "\n");
    }

    # Show window
    sys->fprint(cg.output, "    tkclient->onscreen(t, nil);\n");
    sys->fprint(cg.output, "    tkclient->startinput(t, \"kbd\"::\"ptr\"::nil);\n\n");

    if (has_callbacks) {
        sys->fprint(cg.output, "    for(;;) {\n");
        sys->fprint(cg.output, "        alt {\n");
        sys->fprint(cg.output, "        s := <-t.ctxt.kbd =>\n");
        sys->fprint(cg.output, "            tk->keyboard(t, s);\n");
        sys->fprint(cg.output, "        s := <-t.ctxt.ptr =>\n");
        sys->fprint(cg.output, "            tk->pointer(t, *s);\n");
        sys->fprint(cg.output, "        s := <-t.ctxt.ctl or\n");
        sys->fprint(cg.output, "        s = <-t.wreq or\n");
        sys->fprint(cg.output, "        s = <-wmctl =>\n");
        sys->fprint(cg.output, "            tkclient->wmctl(t, s);\n");
        sys->fprint(cg.output, "        s := <-cmd =>\n");

        # Generate callback cases
        cbs := cg.callbacks;
        while (cbs != nil) {
            (name, event) := hd cbs;
            sys->fprint(cg.output, "            if(s == \"%s\")\n", name);
            sys->fprint(cg.output, "                %s();\n", name);
            cbs = tl cbs;
        }

        # Add tick case for time-based reactive functions
        if (has_reactive) {
            sys->fprint(cg.output, "        <-tick =>\n");
            rfns := prog.reactive_fns;
            while (rfns != nil) {
                # Only call time-based reactive functions
                if (rfns.interval > 0) {
                    # Check if this function has widget bindings
                    has_bindings := 0;
                    bindings := cg.reactive_bindings;
                    while (bindings != nil) {
                        (widget_path, prop_name, fn_name) := hd bindings;
                        if (fn_name == rfns.name) {
                            has_bindings = 1;
                            break;
                        }
                        bindings = tl bindings;
                    }

                    if (has_bindings) {
                        sys->fprint(cg.output, "            %s_update(t);\n", rfns.name);
                    } else {
                        sys->fprint(cg.output, "            %s_update();\n", rfns.name);
                    }
                }
                rfns = rfns.next;
            }

            # Also call update for FunctionDecl with reactive_interval
            fd := prog.function_decls;
            while (fd != nil) {
                if (fd.reactive_interval > 0) {
                    # Check if this function has widget bindings
                    has_bindings := 0;
                    bindings := cg.reactive_bindings;
                    while (bindings != nil) {
                        (widget_path, prop_name, fn_name) := hd bindings;
                        if (fn_name == fd.name) {
                            has_bindings = 1;
                            break;
                        }
                        bindings = tl bindings;
                    }

                    if (has_bindings) {
                        sys->fprint(cg.output, "            %s_update(t);\n", fd.name);
                    } else {
                        sys->fprint(cg.output, "            %s_update();\n", fd.name);
                    }
                }
                fd = fd.next;
            }
        }

        sys->fprint(cg.output, "        }\n");
        sys->fprint(cg.output, "    }\n");
    } else {
        sys->fprint(cg.output, "    for(;;) {\n");
        sys->fprint(cg.output, "        alt {\n");
        sys->fprint(cg.output, "        s := <-t.ctxt.kbd =>\n");
        sys->fprint(cg.output, "            tk->keyboard(t, s);\n");
        sys->fprint(cg.output, "        s := <-t.ctxt.ptr =>\n");
        sys->fprint(cg.output, "            tk->pointer(t, *s);\n");
        sys->fprint(cg.output, "        s := <-t.ctxt.ctl or\n");
        sys->fprint(cg.output, "        s = <-t.wreq or\n");
        sys->fprint(cg.output, "        s = <-wmctl =>\n");
        sys->fprint(cg.output, "            tkclient->wmctl(t, s);\n");

        # Add tick case for time-based reactive functions
        if (has_reactive) {
            sys->fprint(cg.output, "        <-tick =>\n");
            rfns := prog.reactive_fns;
            while (rfns != nil) {
                # Only call time-based reactive functions
                if (rfns.interval > 0) {
                    # Check if this function has widget bindings
                    has_bindings := 0;
                    bindings := cg.reactive_bindings;
                    while (bindings != nil) {
                        (widget_path, prop_name, fn_name) := hd bindings;
                        if (fn_name == rfns.name) {
                            has_bindings = 1;
                            break;
                        }
                        bindings = tl bindings;
                    }

                    if (has_bindings) {
                        sys->fprint(cg.output, "            %s_update(t);\n", rfns.name);
                    } else {
                        sys->fprint(cg.output, "            %s_update();\n", rfns.name);
                    }
                }
                rfns = rfns.next;
            }

            # Also call update for FunctionDecl with reactive_interval
            fd := prog.function_decls;
            while (fd != nil) {
                if (fd.reactive_interval > 0) {
                    # Check if this function has widget bindings
                    has_bindings := 0;
                    bindings := cg.reactive_bindings;
                    while (bindings != nil) {
                        (widget_path, prop_name, fn_name) := hd bindings;
                        if (fn_name == fd.name) {
                            has_bindings = 1;
                            break;
                        }
                        bindings = tl bindings;
                    }

                    if (has_bindings) {
                        sys->fprint(cg.output, "            %s_update(t);\n", fd.name);
                    } else {
                        sys->fprint(cg.output, "            %s_update();\n", fd.name);
                    }
                }
                fd = fd.next;
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
    cg.is_draw_backend = should_use_draw_backend(prog);

    # Generate code in correct order:
    # 1. Prologue (includes, module declaration)
    # 2. Module variables (time, tpid)
    # 3. Collect widget commands (populates reactive_bindings)
    # 4. Generate tkcmds array
    # 5. Init function
    # 6. Reactive update functions
    # 7. Timer function
    # 8. User code blocks

    err := generate_prologue(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    # Generate module variables (time, tpid) after module declaration
    err = generate_const_decls(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    err = generate_var_decls(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    # Only for Tk backend
    if (!cg.is_draw_backend) {
        err = generate_reactive_vars(cg, prog);
        if (err != nil) {
            fd = nil;
            return err;
        }

        # Collect widget commands to populate reactive_bindings
        err = collect_widget_commands(cg, prog);
        if (err != nil) {
            fd = nil;
            return err;
        }

        err = generate_tkcmds_array(cg, prog);
        if (err != nil) {
            fd = nil;
            return err;
        }
    }

    err = generate_init(cg, prog);
    if (err != nil) {
        fd = nil;
        return err;
    }

    # Only for Tk backend
    if (!cg.is_draw_backend) {
        # Generate reactive update functions after init
        err = generate_reactive_funcs(cg, prog);
        if (err != nil) {
            fd = nil;
            return err;
        }

        # Generate timer function
        err = generate_reactive_timer(cg, prog);
        if (err != nil) {
            fd = nil;
            return err;
        }
    }

    # Generate user code blocks last
    err = generate_code_blocks(cg, prog);
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
