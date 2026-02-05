# Lexer module for Kryon compiler

Lexer: module
{
    # Token type constants
    TOKEN_ENDINPUT: con 0;
    TOKEN_STRING: con 1;
    TOKEN_NUMBER: con 2;
    TOKEN_COLOR: con 3;
    TOKEN_IDENTIFIER: con 4;
    TOKEN_LIMBO: con 5;
    TOKEN_TCL: con 6;
    TOKEN_LUA: con 7;
    TOKEN_WINDOW: con 8;
    TOKEN_FRAME: con 9;
    TOKEN_BUTTON: con 10;
    TOKEN_LABEL: con 11;
    TOKEN_ENTRY: con 12;
    TOKEN_CHECKBUTTON: con 13;
    TOKEN_RADIOBUTTON: con 14;
    TOKEN_LISTBOX: con 15;
    TOKEN_CANVAS: con 16;
    TOKEN_SCALE: con 17;
    TOKEN_MENUBUTTON: con 18;
    TOKEN_MESSAGE: con 19;
    TOKEN_COLUMN: con 20;
    TOKEN_ROW: con 21;
    TOKEN_CENTER: con 22;
    TOKEN_END: con 23;
    TOKEN_EVERY: con 24;

    # Token ADT - users need to access this
    Token: adt {
        toktype: int;
        string_val: string;
        number_val: big;
        lineno: int;
    };

    # Lexer ADT - internal structure
    LexerObj: adt {
        src: string;
        src_data: string;
        pos: int;
        lineno: int;
        column: int;
        in_code_block: int;
        code_type: int;
    };

    # Public interface - module-level functions
    create: fn(src: string, data: string): ref LexerObj;
    lex: fn(l: ref LexerObj): ref Token;
    peek_token: fn(l: ref LexerObj): ref Token;
    get_lineno: fn(l: ref LexerObj): int;
    get_column: fn(l: ref LexerObj): int;
};
