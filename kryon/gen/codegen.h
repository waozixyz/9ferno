#ifndef KRYON_CODEGEN_H
#define KRYON_CODEGEN_H

#include "../parse/ast.h"

#define MAX_CALLBACKS 32
#define MAX_TK_CMDS 256

typedef struct Callback {
    char *name;
    char *event;  /* e.g., "onClick" */
    struct Callback *next;
} Callback;

typedef struct TkCmd {
    char *command;
    struct TkCmd *next;
} TkCmd;

typedef struct CodeGen {
    FILE *out;
    const char *module_name;
    int widget_counter;
    int handler_counter;
    int has_tcl;
    int has_lua;
    Callback *callbacks;  /* List of callbacks collected during codegen */
    int has_callbacks;    /* Flag: 1 if any callbacks exist */
    TkCmd *tk_commands;   /* List of Tk commands to execute */
    int tk_cmd_count;     /* Number of tk commands collected */
} CodeGen;

int codegen_generate(FILE *out, Program *prog, const char *module_name);
char *escape_tk_string(const char *s);

#endif /* KRYON_CODEGEN_H */
