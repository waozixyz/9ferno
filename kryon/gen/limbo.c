#include "codegen.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

char *escape_tk_string(const char *s) {
    if (!s) return strdup("{}");

    size_t len = strlen(s);

    /* Check if string needs braces (contains spaces, braces, or special chars) */
    int needs_braces = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == ' ' || s[i] == '{' || s[i] == '}' || s[i] == '\\' || s[i] == '$' || s[i] == '[' || s[i] == ']') {
            needs_braces = 1;
            break;
        }
    }

    /* For simple alphanumeric strings, return as-is without braces */
    if (!needs_braces) {
        return strdup(s);
    }

    /* Allocate for {value} plus potential escapes */
    char *result = malloc(len + 10);
    if (!result) return NULL;

    /* Use TCL brace notation for complex strings */
    size_t j = 0;
    result[j++] = '{';
    for (size_t i = 0; i < len; i++) {
        /* Escape closing braces and backslashes in TCL */
        if (s[i] == '}' || s[i] == '\\') {
            result[j++] = '\\';
        }
        result[j++] = s[i];
    }
    result[j++] = '}';
    result[j] = '\0';
    return result;
}

/* Map Kryon property names to Tk property names */
static const char *map_property_name(const char *prop_name) {
    if (strcmp(prop_name, "color") == 0 || strcmp(prop_name, "textColor") == 0) {
        return "fg";
    }
    if (strcmp(prop_name, "backgroundColor") == 0) {
        return "bg";
    }
    return prop_name;  /* Default: use as-is */
}

static const char *widget_type_to_tk(WidgetType type) {
    switch (type) {
        case WIDGET_BUTTON: return "button";
        case WIDGET_TEXT: return "label";
        case WIDGET_INPUT: return "entry";
        case WIDGET_WINDOW: return "toplevel";
        case WIDGET_CENTER:
        case WIDGET_COLUMN:
        case WIDGET_ROW:
        case WIDGET_CONTAINER: return "frame";
        default: return "frame";
    }
}

static const char *widget_type_to_name(WidgetType type) {
    switch (type) {
        case WIDGET_APP: return "App";
        case WIDGET_WINDOW: return "Window";
        case WIDGET_CONTAINER: return "Container";
        case WIDGET_BUTTON: return "Button";
        case WIDGET_TEXT: return "Text";
        case WIDGET_INPUT: return "Input";
        case WIDGET_COLUMN: return "Column";
        case WIDGET_ROW: return "Row";
        case WIDGET_CENTER: return "Center";
        default: return "Widget";
    }
}

/* Add a callback to the callback list */
static void add_callback(CodeGen *cg, const char *name, const char *event) {
    Callback *cb = calloc(1, sizeof(Callback));
    if (!cb) return;
    cb->name = strdup(name);
    cb->event = strdup(event);
    cb->next = cg->callbacks;
    cg->callbacks = cb;
    cg->has_callbacks = 1;
}

/* Check if a property is a callback (returns callback name or NULL) */
static const char *is_callback_property(const char *prop_name) {
    if (strncmp(prop_name, "on", 2) == 0) {
        return prop_name;  /* It's a callback property */
    }
    return NULL;
}

/* Free callback list */
static void free_callbacks(Callback *cb) {
    while (cb) {
        Callback *next = cb->next;
        free(cb->name);
        free(cb->event);
        free(cb);
        cb = next;
    }
}

static void process_widget_list(CodeGen *cg, Widget *w, const char *parent, int is_root);

/* Helper: append a tk command to the commands array */
static void append_tk_cmd(CodeGen *cg, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char cmd_buf[512];
    vsnprintf(cmd_buf, sizeof(cmd_buf), fmt, args);
    va_end(args);

    TkCmd *cmd = calloc(1, sizeof(TkCmd));
    if (cmd) {
        cmd->command = strdup(cmd_buf);
        cmd->next = cg->tk_commands;
        cg->tk_commands = cmd;
        cg->tk_cmd_count++;
    }
}

/* Generate code for a single widget - collects commands instead of outputting */
static void codegen_widget(CodeGen *cg, Widget *w, const char *parent, int is_root) {
    if (!w) return;

    /* Skip wrapper widgets and layout helpers (Center, Column, Row are virtual containers) */
    if (w->is_wrapper || w->type == WIDGET_CENTER || w->type == WIDGET_COLUMN || w->type == WIDGET_ROW) {
        process_widget_list(cg, w->children, parent, is_root);
        return;
    }

    char widget_path[256];
    /* All widgets get a numbered path (even root-level widgets) */
    if (is_root) {
        /* Root-level widgets get paths like .w0, .w1, etc. */
        snprintf(widget_path, sizeof(widget_path), ".w%d", cg->widget_counter);
        cg->widget_counter++;
    } else {
        snprintf(widget_path, sizeof(widget_path), "%s.w%d", parent, cg->widget_counter);
        cg->widget_counter++;
    }

    /* Build widget creation command - Tk syntax: "widget-type path options" */
    char cmd_buf[1024] = {0};
    const char *tk_type = widget_type_to_tk(w->type);
    snprintf(cmd_buf, sizeof(cmd_buf), "%s %s", tk_type, widget_path);

    /* Generate properties */
    Property *prop = w->props;
    char *callback_name = NULL;  /* Track if this widget has a callback */

    while (prop) {
        if (prop->value) {
            /* Check if this is a callback property */
            const char *cb_event = is_callback_property(prop->name);

            if (cb_event && prop->value->type == VALUE_IDENTIFIER) {
                /* This is a callback - save it and add to callback list */
                callback_name = prop->value->v.ident_val;
                add_callback(cg, callback_name, prop->name);
            } else {
                /* Regular property - generate Tk property */
                const char *tk_prop = map_property_name(prop->name);
                switch (prop->value->type) {
                    case VALUE_STRING: {
                        char *escaped = escape_tk_string(prop->value->v.string_val);
                        strcat(cmd_buf, " -");
                        strcat(cmd_buf, tk_prop);
                        strcat(cmd_buf, " ");
                        strcat(cmd_buf, escaped);
                        free(escaped);
                        break;
                    }
                    case VALUE_NUMBER: {
                        char num_buf[32];
                        snprintf(num_buf, sizeof(num_buf), " -%s %ld", tk_prop, prop->value->v.number_val);
                        strcat(cmd_buf, num_buf);
                        break;
                    }
                    case VALUE_COLOR: {
                        char *escaped = escape_tk_string(prop->value->v.color_val);
                        strcat(cmd_buf, " -");
                        strcat(cmd_buf, tk_prop);
                        strcat(cmd_buf, " ");
                        strcat(cmd_buf, escaped);
                        free(escaped);
                        break;
                    }
                    case VALUE_IDENTIFIER:
                        strcat(cmd_buf, " -");
                        strcat(cmd_buf, tk_prop);
                        strcat(cmd_buf, " ");
                        strcat(cmd_buf, prop->value->v.ident_val);
                        break;
                    default:
                        break;
                }
            }
        }
        prop = prop->next;
    }

    /* Add -command property if this widget has a callback */
    if (callback_name) {
        strcat(cmd_buf, " -command {send cmd ");
        strcat(cmd_buf, callback_name);
        strcat(cmd_buf, "}");
    }

    /* Append the widget creation command */
    append_tk_cmd(cg, "%s", cmd_buf);

    /* Process children FIRST (they need to be packed before this widget) */
    if (w->children) {
        process_widget_list(cg, w->children, widget_path, 0);
    }

    /* Pack widget into parent AFTER children are packed (for proper Tk layout) */
    append_tk_cmd(cg, "pack %s", widget_path);
}

/* Process widget list, flattening wrappers */
static void process_widget_list(CodeGen *cg, Widget *w, const char *parent, int is_root) {
    while (w) {
        if (w->is_wrapper) {
            /* Process children of wrapper with same parent */
            Widget *child = w->children;
            while (child) {
                if (child->is_wrapper) {
                    /* Nested wrapper - recurse */
                    process_widget_list(cg, child->children, parent, is_root);
                } else {
                    codegen_widget(cg, child, parent, is_root);
                }
                child = child->next;
            }
        } else {
            codegen_widget(cg, w, parent, is_root);
        }
        w = w->next;
    }
}

/* Generate prologue */
static void codegen_prologue(CodeGen *cg, Program *prog) {
    fprintf(cg->out, "implement %s;\n\n", cg->module_name);

    fprintf(cg->out, "include \"sys.m\";\n");
    fprintf(cg->out, "include \"draw.m\";\n");
    fprintf(cg->out, "include \"tk.m\";\n");
    fprintf(cg->out, "include \"tkclient.m\";\n\n");

    fprintf(cg->out, "sys: Sys;\n");
    fprintf(cg->out, "draw: Draw;\n");
    fprintf(cg->out, "tk: Tk;\n");
    fprintf(cg->out, "tkclient: Tkclient;\n\n");

    /* Generate module declaration */
    fprintf(cg->out, "%s: module\n{\n", cg->module_name);
    fprintf(cg->out, "    init: fn(ctxt: ref Draw->Context, nil: list of string);\n");

    /* Add any function signatures from code blocks */
    /* For Tk callbacks, we always use fn() with no parameters */
    CodeBlock *cb = prog->code_blocks;
    while (cb) {
        if (cb->type == CODE_LIMBO && cb->code) {
            /* Try to extract function name from code like "funcName: fn(...) {" */
            char *code = cb->code;
            char *colon = strchr(code, ':');
            if (colon && strncmp(colon, ": fn(", 5) == 0) {
                /* Find the start of the function name */
                char *start = code;
                while (start < colon && (*start == '\n' || isspace((unsigned char)*start))) start++;
                fprintf(cg->out, "    %.*s: fn();\n", (int)(colon - start), start);
            }
        }
        cb = cb->next;
    }

    fprintf(cg->out, "};\n");
}

/* Generate code blocks (Limbo functions) */
static void codegen_code_blocks(CodeGen *cg, Program *prog) {
    CodeBlock *cb = prog->code_blocks;
    while (cb) {
        if (cb->type == CODE_LIMBO && cb->code) {
            char *code = cb->code;
            char *current = code;

            /* Process each function in the code block */
            while (*current) {
                /* Skip leading whitespace and newlines */
                while (*current && (*current == '\n' || isspace((unsigned char)*current))) current++;
                if (!*current) break;

                /* Find function name (ends with ':') */
                char *colon = strchr(current, ':');
                if (!colon) break;

                /* Find the opening brace */
                char *lbrace = strchr(colon, '{');
                if (!lbrace) break;

                /* Find the matching closing brace by counting braces */
                char *rbrace = lbrace;
                int brace_count = 1;
                while (*rbrace && brace_count > 0) {
                    rbrace++;
                    if (*rbrace == '{') brace_count++;
                    else if (*rbrace == '}') brace_count--;
                }

                if (brace_count != 0) break;

                /* Find the start of the function name */
                char *name_start = current;
                while (name_start < colon && (*name_start == '\n' || isspace((unsigned char)*name_start))) name_start++;

                /* Extract function name */
                int name_len = (int)(colon - name_start);

                /* Output: name() { (Tk callbacks have no parameters) */
                fprintf(cg->out, "\n%.*s()\n", name_len, name_start);

                /* Find and output the function body */
                char *body_start = lbrace + 1;
                while (*body_start && (*body_start == '\n' || isspace((unsigned char)*body_start))) body_start++;

                if (rbrace > body_start) {
                    /* Trim trailing whitespace from body */
                    char *body_end = rbrace - 1;
                    while (body_end > body_start && (*body_end == '\n' || isspace((unsigned char)*body_end))) body_end--;
                    fprintf(cg->out, "{\n    %.*s\n}\n", (int)(body_end - body_start + 1), body_start);
                }

                /* Move to next function */
                current = rbrace + 1;

                /* Skip semicolon if present */
                while (*current && (*current == ';' || *current == '\n' || isspace((unsigned char)*current))) current++;
            }
        }
        cb = cb->next;
    }
}

/* Collect widget commands - must run before outputting init */
static void collect_widget_commands(CodeGen *cg, Program *prog) {
    cg->widget_counter = 0;
    if (prog->app && prog->app->body) {
        process_widget_list(cg, prog->app->body, ".", 1);
    }
}

/* Output tkcmds array at module scope (between functions and init) */
static void codegen_tkcmds_array(CodeGen *cg) {
    fprintf(cg->out, "\ntkcmds := array[] of {\n");
    int cmd_count = cg->tk_cmd_count;
    if (cmd_count > 0) {
        TkCmd **cmds = calloc(cmd_count, sizeof(TkCmd*));
        TkCmd *cmd = cg->tk_commands;
        int idx = cmd_count - 1;
        while (cmd && idx >= 0) {
            cmds[idx--] = cmd;
            cmd = cmd->next;
        }
        for (int i = 0; i < cmd_count; i++) {
            fprintf(cg->out, "    \"%s\",\n", cmds[i]->command);
        }
        free(cmds);
        fprintf(cg->out, "    \"pack propagate . 0\",\n");
    } else {
        fprintf(cg->out, "    \"pack propagate . 0\",\n");
    }
    fprintf(cg->out, "    \"update\"\n");
    fprintf(cg->out, "};\n\n");
}

/* Generate init function */
static void codegen_init(CodeGen *cg, Program *prog) {
    fprintf(cg->out, "init(ctxt: ref Draw->Context, nil: list of string)\n");
    fprintf(cg->out, "{\n");

    fprintf(cg->out, "    sys = load Sys Sys->PATH;\n");
    fprintf(cg->out, "    draw = load Draw Draw->PATH;\n");
    fprintf(cg->out, "    tk = load Tk Tk->PATH;\n");
    fprintf(cg->out, "    tkclient = load Tkclient Tkclient->PATH;\n\n");
    fprintf(cg->out, "    tkclient->init();\n\n");

    /* Get app properties */
    const char *title = "Application";
    int width = 400;
    int height = 300;
    const char *bg = "#191919";
    int has_width = 0;
    int has_height = 0;
    int has_bg = 0;

    if (prog->app && prog->app->props) {
        Property *prop = prog->app->props;
        while (prop) {
            if (strcmp(prop->name, "title") == 0 && prop->value &&
                prop->value->type == VALUE_STRING) {
                title = prop->value->v.string_val;
            } else if (strcmp(prop->name, "width") == 0 && prop->value &&
                       prop->value->type == VALUE_NUMBER) {
                width = prop->value->v.number_val;
                has_width = 1;
            } else if (strcmp(prop->name, "height") == 0 && prop->value &&
                       prop->value->type == VALUE_NUMBER) {
                height = prop->value->v.number_val;
                has_height = 1;
            } else if (strcmp(prop->name, "background") == 0 && prop->value &&
                       prop->value->type == VALUE_COLOR) {
                bg = prop->value->v.color_val;
                has_bg = 1;
            } else if (strcmp(prop->name, "backgroundColor") == 0 && prop->value &&
                       prop->value->type == VALUE_COLOR) {
                bg = prop->value->v.color_val;
                has_bg = 1;
            }
            prop = prop->next;
        }
    }

    /* Create toplevel window - using correct API */
    fprintf(cg->out, "    (toplevel, menubut) := tkclient->toplevel(ctxt, \"\", \"%s\", 0);\n\n", title);

    /* Create command channel and register with Tk */
    if (cg->has_callbacks) {
        fprintf(cg->out, "    cmd := chan of string;\n");
        fprintf(cg->out, "    tk->namechan(toplevel, cmd, \"cmd\");\n\n");
    }

    /* Execute tk commands */
    fprintf(cg->out, "    for (i := 0; i < len tkcmds; i++)\n");
    fprintf(cg->out, "        tk->cmd(toplevel, tkcmds[i]);\n\n");

    /* Show window */
    fprintf(cg->out, "    tkclient->onscreen(toplevel, nil);\n");
    fprintf(cg->out, "    tkclient->startinput(toplevel, \"ptr\"::nil);\n\n");
    fprintf(cg->out, "    stop := chan of int;\n");
    fprintf(cg->out, "    spawn tkclient->handler(toplevel, stop);\n");

    if (cg->has_callbacks) {
        fprintf(cg->out, "    for(;;) {\n");
        fprintf(cg->out, "        alt {\n");
        fprintf(cg->out, "        msg := <-menubut =>\n");
        fprintf(cg->out, "            if(msg == \"exit\")\n");
        fprintf(cg->out, "                break;\n");
        fprintf(cg->out, "            tkclient->wmctl(toplevel, msg);\n");
        fprintf(cg->out, "        s := <-cmd =>\n");

        /* Generate callback cases */
        Callback *cb = cg->callbacks;
        while (cb) {
            fprintf(cg->out, "            if(s == \"%s\")\n", cb->name);
            fprintf(cg->out, "                %s();\n", cb->name);
            cb = cb->next;
        }

        fprintf(cg->out, "        }\n");
        fprintf(cg->out, "    }\n");
    } else {
        fprintf(cg->out, "    while((msg := <-menubut) != \"exit\")\n");
        fprintf(cg->out, "        tkclient->wmctl(toplevel, msg);\n");
    }

    fprintf(cg->out, "    stop <-= 1;\n");
    fprintf(cg->out, "}\n");
}
int codegen_generate(FILE *out, Program *prog, const char *module_name) {
    if (!out || !prog || !module_name) {
        return -1;
    }

    CodeGen cg;
    memset(&cg, 0, sizeof(CodeGen));
    cg.out = out;
    cg.module_name = module_name;
    cg.widget_counter = 0;
    cg.handler_counter = 0;

    /* Check for code block types */
    CodeBlock *cb = prog->code_blocks;
    while (cb) {
        if (cb->type == CODE_TCL) cg.has_tcl = 1;
        if (cb->type == CODE_LUA) cg.has_lua = 1;
        cb = cb->next;
    }

    /* Generate code */
    codegen_prologue(&cg, prog);
    codegen_code_blocks(&cg, prog);
    collect_widget_commands(&cg, prog);  /* Process widgets to collect tk commands */
    codegen_tkcmds_array(&cg);          /* Output tkcmds array at module scope */
    codegen_init(&cg, prog);            /* Generate init function */

    /* Cleanup */
    free_callbacks(cg.callbacks);

    return 0;
}
