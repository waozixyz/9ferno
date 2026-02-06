implement Lexer;

include "sys.m";
    sys: Sys;
include "bufio.m";
    bufio: Bufio;
include "lexer.m";

# Token constructor functions (not methods, just helpers)
create_token(typ: int, lineno: int): ref Token
{
    return ref Token (typ, "", big 0, lineno);
}

create_string_token(typ: int, s: string, lineno: int): ref Token
{
    tok := ref Token (typ, s, big 0, lineno);
    return tok;
}

create_number_token(n: big, lineno: int): ref Token
{
    return ref Token (TOKEN_NUMBER, "", n, lineno);
}

# Public interface implementations

create(src: string, data: string): ref LexerObj
{
    return ref LexerObj (src, data, 0, 1, 0);
}

get_lineno(l: ref LexerObj): int
{
    return l.lineno;
}

get_column(l: ref LexerObj): int
{
    return l.column;
}

# Peek at current character without consuming
peek_char(l: ref LexerObj): int
{
    if (l.pos >= len l.src_data)
        return -1;  # EOF
    return l.src_data[l.pos];
}

# Consume and return current character
next_char(l: ref LexerObj): int
{
    if (l.pos >= len l.src_data)
        return -1;  # EOF

    c := l.src_data[l.pos];
    l.pos++;

    if (c == '\n') {
        l.lineno++;
        l.column = 0;
    } else {
        l.column++;
    }

    return c;
}

# Skip whitespace and // comments
skip_whitespace(l: ref LexerObj)
{
    while (l.pos < len l.src_data) {
        c := peek_char(l);

        # Check for // comments
        if (c == '/') {
            next_char(l);  # consume first /
            if (peek_char(l) == '/') {
                # Skip to end of line
                while (peek_char(l) != -1 && peek_char(l) != '\n')
                    next_char(l);
                continue;  # Restart loop to get next character
            } else {
                # Not a comment - the / will be handled by main lexer
                # Back up by not consuming
                l.pos--;
                l.column--;
                return;
            }
        }

        if (c == ' ' || c == '\t' || c == '\r') {
            next_char(l);
            continue;  # Restart loop to get next character
        } else if (c == '\n') {
            next_char(l);
            continue;  # Restart loop to get next character
        } else {
            break;
        }
    }
}

# Read a string literal
read_string_literal(l: ref LexerObj): (string, string)
{
    next_char(l);  # Skip opening quote

    buf := "";
    start_line := l.lineno;

    while (l.pos < len l.src_data) {
        c := peek_char(l);

        if (c == '"') {
            next_char(l);
            return (buf, nil);
        }

        if (c == '\\') {
            next_char(l);
            c = peek_char(l);
            if (c == 'n') {
                buf[len buf] = '\n';
            } else if (c == 't') {
                buf[len buf] = '\t';
            } else if (c == 'r') {
                buf[len buf] = '\r';
            } else {
                buf[len buf] = c;
            }
        } else {
            buf[len buf] = c;
        }
        next_char(l);
    }

    return (nil, sys->sprint("unterminated string at line %d", start_line));
}

# Read a number literal
read_number(l: ref LexerObj): big
{
    val := big 0;

    while (l.pos < len l.src_data) {
        c := peek_char(l);
        if (c < '0' || c > '9')
            break;

        val = val * big 10 + big (c - '0');
        next_char(l);
    }

    return val;
}

# Read an identifier
read_identifier(l: ref LexerObj): string
{
    id := "";
    c := peek_char(l);

    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'))
        return nil;

    while (l.pos < len l.src_data) {
        c := peek_char(l);
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_'))
            break;

        id[len id] = c;
        next_char(l);
    }

    return id;
}

# Read a color literal (#xxxx)
read_color_literal(l: ref LexerObj): string
{
    next_char(l);  # Skip #

    color := "";

    while (l.pos < len l.src_data) {
        c := peek_char(l);

        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F') || c == '#' || c == '(' ||
            c == ')' || c == ',' || c == '.' || c == '%' || c == ' ') {
            color[len color] = c;
            next_char(l);
        } else {
            break;
        }
    }

    return color;
}

# Check if identifier is a keyword
check_keyword(id: string): int
{
    # Keywords
    if (id == "var") return TOKEN_VAR;
    if (id == "fn") return TOKEN_FN;

    # Widget types
    if (id == "Window") return TOKEN_WINDOW;
    if (id == "Frame") return TOKEN_FRAME;
    if (id == "Button") return TOKEN_BUTTON;
    if (id == "Label") return TOKEN_LABEL;
    if (id == "Entry") return TOKEN_ENTRY;
    if (id == "Checkbutton") return TOKEN_CHECKBUTTON;
    if (id == "Radiobutton") return TOKEN_RADIOBUTTON;
    if (id == "Listbox") return TOKEN_LISTBOX;
    if (id == "Canvas") return TOKEN_CANVAS;
    if (id == "Scale") return TOKEN_SCALE;
    if (id == "Menubutton") return TOKEN_MENUBUTTON;
    if (id == "Message") return TOKEN_MESSAGE;
    if (id == "Column") return TOKEN_COLUMN;
    if (id == "Row") return TOKEN_ROW;
    if (id == "Center") return TOKEN_CENTER;

    return TOKEN_IDENTIFIER;
}

# Main lex function - returns next token
lex(l: ref LexerObj): ref Token
{
    skip_whitespace(l);

    lineno := l.lineno;
    c := peek_char(l);

    if (c == -1) {
        return create_token(TOKEN_ENDINPUT, lineno);
    }

    # @ symbol for reactive syntax
    if (c == '@') {
        next_char(l);  # consume @
        return create_token(TOKEN_AT, lineno);
    }

    # Arrow operator ->
    if (c == '-') {
        next_char(l);  # Consume the '-'
        if (peek_char(l) == '>') {
            next_char(l);  # Consume the '>'
            return create_token(TOKEN_ARROW, lineno);
        }
        # If it wasn't a '>', return the '-' as a single char token
        return create_token('-', lineno);
    }
    

    # String literal
    if (c == '"') {
        (s, err) := read_string_literal(l);
        if (err != nil) {
            tok := create_token(TOKEN_ENDINPUT, lineno);
            tok.string_val = err;
            return tok;
        }
        return create_string_token(TOKEN_STRING, s, lineno);
    }

    # Color literal
    if (c == '#') {
        color := read_color_literal(l);
        return create_string_token(TOKEN_COLOR, color, lineno);
    }

    # Number
    if (c >= '0' && c <= '9') {
        val := read_number(l);
        return create_number_token(val, lineno);
    }

    # Identifier or keyword
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
        id := read_identifier(l);
        if (id == nil) {
            return create_token(TOKEN_ENDINPUT, lineno);
        }

        typ := check_keyword(id);

        if (typ == TOKEN_IDENTIFIER) {
            return create_string_token(typ, id, lineno);
        }

        return create_token(typ, lineno);
    }

    # Single character tokens
    next_char(l);
    return create_token(c, lineno);
}

# Peek at next token without consuming
peek_token(l: ref LexerObj): ref Token
{
    # Save position
    saved_pos := l.pos;
    saved_lineno := l.lineno;
    saved_column := l.column;

    tok := lex(l);

    # Restore position
    l.pos = saved_pos;
    l.lineno = saved_lineno;
    l.column = saved_column;

    return tok;
}
