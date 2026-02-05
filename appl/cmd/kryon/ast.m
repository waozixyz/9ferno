# AST type definitions for Kryon compiler

Ast: module
{
    # Widget type constants
    WIDGET_APP: con 1;
    WIDGET_WINDOW: con 2;
    WIDGET_FRAME: con 3;
    WIDGET_BUTTON: con 4;
    WIDGET_LABEL: con 5;
    WIDGET_ENTRY: con 6;
    WIDGET_CHECKBUTTON: con 7;
    WIDGET_RADIOBUTTON: con 8;
    WIDGET_LISTBOX: con 9;
    WIDGET_CANVAS: con 10;
    WIDGET_SCALE: con 11;
    WIDGET_MENUBUTTON: con 12;
    WIDGET_MESSAGE: con 13;
    WIDGET_COLUMN: con 14;
    WIDGET_ROW: con 15;
    WIDGET_CENTER: con 16;

    # Value type constants
    VALUE_STRING: con 1;
    VALUE_NUMBER: con 2;
    VALUE_COLOR: con 3;
    VALUE_IDENTIFIER: con 4;
    VALUE_ARRAY: con 5;
    VALUE_FN_CALL: con 6;

    # Code block type constants
    CODE_LIMBO: con 1;
    CODE_TCL: con 2;
    CODE_LUA: con 3;

    # Value ADT - uses pick to handle different value types
    Value: adt {
        valtype: int;

        pick {
        String =>
            string_val: string;
        Number =>
            number_val: big;
        Color =>
            color_val: string;
        Identifier =>
            ident_val: string;
        Array =>
            array_val: array of ref Value;
        FnCall =>
            fn_name: string;
        }
    };

    # Property ADT
    Property: adt {
        name: string;
        value: ref Value;
        next: ref Property;
    };

    # Widget ADT
    Widget: adt {
        wtype: int;
        id: string;
        props: ref Property;
        children: ref Widget;
        next: ref Widget;
        is_wrapper: int;
    };

    # Code block ADT
    CodeBlock: adt {
        cbtype: int;
        code: string;
        next: ref CodeBlock;
    };

    # Variable declaration ADT
    VarDecl: adt {
        name: string;
        typ: string;
        init_value: ref Value;
        next: ref VarDecl;
    };

    # Parameter ADT
    Param: adt {
        name: string;
        typ: string;
        default_value: string;
        next: ref Param;
    };

    # Component definition ADT
    ComponentDef: adt {
        name: string;
        params: ref Param;
        vars: ref VarDecl;
        handlers: ref CodeBlock;
        body: ref Widget;
        next: ref ComponentDef;
    };

    # App declaration ADT
    AppDecl: adt {
        title: string;
        props: ref Property;
        body: ref Widget;
    };

    # Reactive function ADT
    ReactiveFunction: adt {
        name: string;
        expression: string;
        interval: int;
        next: ref ReactiveFunction;
    };

    # Reactive binding ADT (tracks widget -> reactive function relationships)
    ReactiveBinding: adt {
        widget_path: string;
        property_name: string;
        fn_name: string;
        next: ref ReactiveBinding;
    };

    # Module import ADT
    ModuleImport: adt {
        module_name: string;
        alias: string;
        next: ref ModuleImport;
    };

    # Program ADT (root node)
    Program: adt {
        vars: ref VarDecl;
        code_blocks: ref CodeBlock;
        components: ref ComponentDef;
        app: ref AppDecl;
        reactive_fns: ref ReactiveFunction;
        module_imports: ref ModuleImport;
    };

    # AST construction functions
    program_create: fn(): ref Program;
    var_decl_create: fn(name: string, typ: string, init: ref Value): ref VarDecl;
    code_block_create: fn(typ: int, code: string): ref CodeBlock;
    component_create: fn(name: string): ref ComponentDef;
    app_decl_create: fn(): ref AppDecl;
    widget_create: fn(typ: int): ref Widget;
    property_create: fn(name: string): ref Property;
    value_create_string: fn(s: string): ref Value;
    value_create_number: fn(n: big): ref Value;
    value_create_color: fn(c: string): ref Value;
    value_create_ident: fn(id: string): ref Value;
    value_create_array: fn(items: array of ref Value): ref Value;
    value_create_fn_call: fn(fn_name: string): ref Value;
    param_create: fn(name: string, typ: string, default_val: string): ref Param;

    # Module import functions
    moduleimport_create: fn(module_name: string, alias: string): ref ModuleImport;
    moduleimport_list_add: fn(head: ref ModuleImport, imp: ref ModuleImport): ref ModuleImport;

    # Reactive function functions
    reactivefn_create: fn(name: string, expr: string, interval: int): ref ReactiveFunction;
    reactivefn_list_add: fn(head: ref ReactiveFunction, rfn: ref ReactiveFunction): ref ReactiveFunction;
    reactivebinding_create: fn(widget_path: string, property_name: string, fn_name: string): ref ReactiveBinding;
    reactivebinding_list_add: fn(head: ref ReactiveBinding, binding: ref ReactiveBinding): ref ReactiveBinding;

    # Widget linking functions
    widget_add_child: fn(parent: ref Widget, child: ref Widget);
    widget_add_property: fn(w: ref Widget, prop: ref Property);
    program_add_var: fn(prog: ref Program, var: ref VarDecl);
    program_add_code_block: fn(prog: ref Program, code: ref CodeBlock);
    program_add_component: fn(prog: ref Program, comp: ref ComponentDef);
    program_set_app: fn(prog: ref Program, app: ref AppDecl);
    program_add_reactive_fn: fn(prog: ref Program, rfn: ref ReactiveFunction);
    program_add_module_import: fn(prog: ref Program, imp: ref ModuleImport);

    # List building functions
    property_list_add: fn(listhd: ref Property, item: ref Property): ref Property;
    widget_list_add: fn(listhd: ref Widget, item: ref Widget): ref Widget;
    var_list_add: fn(listhd: ref VarDecl, item: ref VarDecl): ref VarDecl;
    code_block_list_add: fn(listhd: ref CodeBlock, item: ref CodeBlock): ref CodeBlock;
    component_list_add: fn(listhd: ref ComponentDef, item: ref ComponentDef): ref ComponentDef;
    param_list_add: fn(listhd: ref Param, item: ref Param): ref Param;

    # Value helper functions - safe field access for pick ADT
    value_get_string: fn(v: ref Value): string;
    value_get_number: fn(v: ref Value): big;
    value_get_color: fn(v: ref Value): string;
    value_get_ident: fn(v: ref Value): string;
};
