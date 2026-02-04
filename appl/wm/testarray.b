implement Testarray;

include "sys.m";
include "draw.m";
include "tk.m";
include "tkclient.m";

sys: Sys;
draw: Draw;
tk: Tk;
tkclient: Tkclient;

Testarray: module
{
    init: fn(ctxt: ref Draw->Context, nil: list of string);
};

tkcmds := array[] of {
    "button .b -text TestButton -bg #404080 -fg white",
    "pack .b",
    "pack propagate . 0",
    "update"
};

init(ctxt: ref Draw->Context, nil: list of string)
{
    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;
    tk = load Tk Tk->PATH;
    tkclient = load Tkclient Tkclient->PATH;

    tkclient->init();

    (toplevel, menubut) := tkclient->toplevel(ctxt, "", "Test Array", 0);

    for (i := 0; i < len tkcmds; i++)
        tk->cmd(toplevel, tkcmds[i]);

    tkclient->onscreen(toplevel, nil);
    tkclient->startinput(toplevel, "ptr"::nil);

    stop := chan of int;
    spawn tkclient->handler(toplevel, stop);
    while((msg := <-menubut) != "exit")
        tkclient->wmctl(toplevel, msg);
    stop <-= 1;
}
