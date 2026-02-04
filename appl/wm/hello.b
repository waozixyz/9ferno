implement Hello;

include "sys.m";
include "draw.m";
include "tk.m";
include "tkclient.m";

sys: Sys;
draw: Draw;
tk: Tk;
tkclient: Tkclient;

Hello: module
{
    init: fn(ctxt: ref Draw->Context, nil: list of string);
    handleClick: fn();
};


handleClick()
{
sys->print("Hello from Kryon!\n");
}


init(ctxt: ref Draw->Context, nil: list of string)
{
    if (ctxt == nil) {
        sys->fprint(sys->fildes(2), "app: no window context\n");
        raise "fail:bad context";
    }

    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;
    tk = load Tk Tk->PATH;
    tkclient = load Tkclient Tkclient->PATH;

    tkclient->init();

    (toplevel, menubut) := tkclient->toplevel(ctxt, "", "Hello World", 0);

    tk->cmd(toplevel, ". configure -width 400 -height 300");

    # Build UI
    tk->cmd(toplevel, ".w0 button -text {Click Me} -fg white -bg #404080 -command {send cmd handleClick}");
    tk->cmd(toplevel, "pack .w0");
    cmd := chan of string;
    tk->namechan(toplevel, cmd, "cmd");


    tk->cmd(toplevel, "update");
    tkclient->onscreen(toplevel, nil);
    tkclient->startinput(toplevel, "kbd"::"ptr"::nil);

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
