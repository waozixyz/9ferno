implement Simpletk;

# Simple Tk app that doesn't use tkclient
# Runs directly in emu's X11 window

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Screen, Image, Rect, Point: import draw;
include "tk.m";
	tk: Tk;

Simpletk: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;

	if(ctxt == nil || ctxt.display == nil) {
		sys->fprint(sys->fildes(2), "simpletk: no display\n");
		raise "fail:display";
	}

	sys->fprint(sys->fildes(2), "Simpletk: Starting...\n");

	# Create a toplevel window directly using Tk
	# This doesn't require tkclient or WM
	top := tk->toplevel(ctxt.display, "");
	if(top == nil) {
		sys->fprint(sys->fildes(2), "simpletk: cannot create toplevel: %r\n");
		raise "fail:window";
	}

	sys->fprint(sys->fildes(2), "Simpletk: Window created\n");

	# Create a simple UI
	tk->cmd(top, "label .l -text {Hello from TaijiOS!}");
	tk->cmd(top, "button .b -text {Exit} -command {send cmd exit}");
	tk->cmd(top, "pack .l .b");

	# Make window visible
	tk->cmd(top, "update");

	# Wait for exit command
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");

	sys->fprint(sys->fildes(2), "Simpletk: Running...\n");

	for(;;) alt {
		s := <-cmdch =>
			if(s == "exit") {
				sys->fprint(sys->fildes(2), "Simpletk: Exiting...\n");
				exit;
			}
	}
}
