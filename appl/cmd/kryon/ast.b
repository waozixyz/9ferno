implement Ast;

include "sys.m";
    sys: Sys;
include "ast.m";

# AST construction functions

program_create(): ref Program
{
    return ref Program (nil, nil, nil, nil, nil);
}

var_decl_create(name: string, typ: string, init: ref Value): ref VarDecl
{
    return ref VarDecl (name, typ, init, nil);
}

code_block_create(typ: int, code: string): ref CodeBlock
{
    return ref CodeBlock (typ, code, nil);
}

component_create(name: string): ref ComponentDef
{
    return ref ComponentDef (name, nil, nil, nil, nil, nil);
}

app_decl_create(): ref AppDecl
{
    return ref AppDecl ("", nil, nil);
}

widget_create(typ: int): ref Widget
{
    return ref Widget (typ, "", nil, nil, nil, 0);
}

property_create(name: string): ref Property
{
    return ref Property (name, nil, nil);
}

value_create_string(s: string): ref Value
{
    return ref Value.String (Ast->VALUE_STRING, s);
}

value_create_number(n: big): ref Value
{
    return ref Value.Number (Ast->VALUE_NUMBER, n);
}

value_create_color(c: string): ref Value
{
    return ref Value.Color (Ast->VALUE_COLOR, c);
}

value_create_ident(id: string): ref Value
{
    return ref Value.Identifier (Ast->VALUE_IDENTIFIER, id);
}

value_create_array(items: array of ref Value): ref Value
{
    return ref Value.Array (Ast->VALUE_ARRAY, items);
}

param_create(name: string, typ: string, default_val: string): ref Param
{
    return ref Param (name, typ, default_val, nil);
}

# Widget linking functions

widget_add_child(parent: ref Widget, child: ref Widget)
{
    if (parent == nil || child == nil)
        return;

    if (parent.children == nil) {
        parent.children = child;
    } else {
        w := parent.children;
        while (w.next != nil)
            w = w.next;
        w.next = child;
    }
}

widget_add_property(w: ref Widget, prop: ref Property)
{
    if (w == nil || prop == nil)
        return;

    if (w.props == nil) {
        w.props = prop;
    } else {
        p := w.props;
        while (p.next != nil)
            p = p.next;
        p.next = prop;
    }
}

program_add_var(prog: ref Program, var: ref VarDecl)
{
    if (prog == nil || var == nil)
        return;

    if (prog.vars == nil) {
        prog.vars = var;
    } else {
        v := prog.vars;
        while (v.next != nil)
            v = v.next;
        v.next = var;
    }
}

program_add_code_block(prog: ref Program, code: ref CodeBlock)
{
    if (prog == nil || code == nil)
        return;

    if (prog.code_blocks == nil) {
        prog.code_blocks = code;
    } else {
        cb := prog.code_blocks;
        while (cb.next != nil)
            cb = cb.next;
        cb.next = code;
    }
}

program_add_component(prog: ref Program, comp: ref ComponentDef)
{
    if (prog == nil || comp == nil)
        return;

    if (prog.components == nil) {
        prog.components = comp;
    } else {
        c := prog.components;
        while (c.next != nil)
            c = c.next;
        c.next = comp;
    }
}

program_set_app(prog: ref Program, app: ref AppDecl)
{
    prog.app = app;
}

program_add_reactive_fn(prog: ref Program, rfn: ref ReactiveFunction)
{
    if (prog == nil || rfn == nil)
        return;

    if (prog.reactive_fns == nil) {
        prog.reactive_fns = rfn;
    } else {
        r := prog.reactive_fns;
        while (r.next != nil)
            r = r.next;
        r.next = rfn;
    }
}

# List building functions

property_list_add(listhd: ref Property, item: ref Property): ref Property
{
    if (listhd == nil)
        return item;

    p := listhd;
    while (p.next != nil)
        p = p.next;
    p.next = item;
    return listhd;
}

widget_list_add(listhd: ref Widget, item: ref Widget): ref Widget
{
    if (listhd == nil)
        return item;

    w := listhd;
    while (w.next != nil)
        w = w.next;
    w.next = item;
    return listhd;
}

var_list_add(listhd: ref VarDecl, item: ref VarDecl): ref VarDecl
{
    if (listhd == nil)
        return item;

    v := listhd;
    while (v.next != nil)
        v = v.next;
    v.next = item;
    return listhd;
}

code_block_list_add(listhd: ref CodeBlock, item: ref CodeBlock): ref CodeBlock
{
    if (listhd == nil)
        return item;

    cb := listhd;
    while (cb.next != nil)
        cb = cb.next;
    cb.next = item;
    return listhd;
}

component_list_add(listhd: ref ComponentDef, item: ref ComponentDef): ref ComponentDef
{
    if (listhd == nil)
        return item;

    c := listhd;
    while (c.next != nil)
        c = c.next;
    c.next = item;
    return listhd;
}

param_list_add(listhd: ref Param, item: ref Param): ref Param
{
    if (listhd == nil)
        return item;

    p := listhd;
    while (p.next != nil)
        p = p.next;
    p.next = item;
    return listhd;
}

# Value helper functions - safe field access for pick ADT

value_get_string(v: ref Value): string
{
    if (v == nil || v.valtype != VALUE_STRING)
        return "";
    pick sv := v {
    String => return sv.string_val;
    * => return "";
    }
}

value_get_number(v: ref Value): big
{
    if (v == nil || v.valtype != VALUE_NUMBER)
        return big 0;
    pick nv := v {
    Number => return nv.number_val;
    * => return big 0;
    }
}

value_get_color(v: ref Value): string
{
    if (v == nil || v.valtype != VALUE_COLOR)
        return "";
    pick cv := v {
    Color => return cv.color_val;
    * => return "";
    }
}

value_get_ident(v: ref Value): string
{
    if (v == nil || v.valtype != VALUE_IDENTIFIER)
        return "";
    pick iv := v {
    Identifier => return iv.ident_val;
    * => return "";
    }
}

value_create_fn_call(fn_name: string): ref Value
{
    return ref Value.FnCall (Ast->VALUE_FN_CALL, fn_name);
}

# Reactive function helper functions

reactivefn_create(name: string, expr: string, interval: int): ref ReactiveFunction
{
    return ref ReactiveFunction (name, expr, interval, nil);
}

reactivefn_list_add(head: ref ReactiveFunction, rfn: ref ReactiveFunction): ref ReactiveFunction
{
    if (head == nil)
        return rfn;

    r := head;
    while (r.next != nil)
        r = r.next;
    r.next = rfn;
    return head;
}

reactivebinding_create(widget_path: string, property_name: string, fn_name: string): ref ReactiveBinding
{
    return ref ReactiveBinding (widget_path, property_name, fn_name, nil);
}

reactivebinding_list_add(head: ref ReactiveBinding, binding: ref ReactiveBinding): ref ReactiveBinding
{
    if (head == nil)
        return binding;

    r := head;
    while (r.next != nil)
        r = r.next;
    r.next = binding;
    return head;
}
