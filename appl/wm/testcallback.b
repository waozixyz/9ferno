implement Testcallback;

include "sys.m";
include "draw.m";
include "tk.m";
include "tkclient.m";

sys: Sys;
draw: Draw;
tk: Tk;
tkclient: Tkclient;

Testcallback: module
{
    init: fn(ctxt: ref Draw->Context, nil: list of string);
    handleClick: fn();
};

handleClick()
{
    sys->print("Clicked!\n");
}

tkcmds := array[] of {
    "button .b -text TestButton -bg #404080 -fg white -command {send cmd handleClick}",
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

    (toplevel, menubut) := tkclient->toplevel(ctxt, "", "Test Callback", 0);

    cmd := chan of string;
    tk->namechan(toplevel, cmd, "cmd");

    for (i := 0; i < len tkcmds; i++)
        tk->cmd(toplevel, tkcmds[i]);

    tkclient->onscreen(toplevel, nil);
    tkclient->startinput(toplevel, "ptr"::nil);

    stop := chan of int;
    spawn tkclient->handler(toplevel, stop);
    for(;;) {
        alt {
        msg := <-menubut =>
            if(msg == "exit")
                break;
            tkclient->wmctl(toplevel, msg);
        s := <-cmd =>
            if(s == "handleClick")
                handleClick();
        }
    }
    stop <-= 1;
}
