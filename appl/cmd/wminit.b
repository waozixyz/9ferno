implement Wminit;

# Universal app launcher for running apps without a full WM
# Starts a minimal WM context so tkclient apps work
# Each app runs in its own emu instance with its own X11 window

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Context: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "sh.m";

Wminit: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;

	if(tkclient == nil) {
		sys->fprint(sys->fildes(2), "wminit: cannot load %s: %r\n", Tkclient->PATH);
		raise "fail:bad module";
	}
	tkclient->init();

	if(argv == nil || len argv < 2) {
		sys->fprint(sys->fildes(2), "Usage: wminit app.dis [args...]\n");
		raise "fail:usage";
	}

	# Skip argv[0] (the program name), get app from argv[1]
	argv = tl argv;
	appdis := hd argv;
	appargs := tl argv;

	sys->fprint(sys->fildes(2), "wminit: starting %s...\n", appdis);

	# Initialize display and start minimal WM
	if(ctxt == nil) {
		display := Display.allocate(nil);
		if(display == nil) {
			sys->fprint(sys->fildes(2), "wminit: cannot open display: %r\n");
			raise "fail:display";
		}

		# Create context with NO WM channel - let tkclient handle it
		# When ctxt.wm == nil, tkclient->toplevel() creates a standalone window
		# that doesn't need /chan/wmctl or /chan/wmrect
		ctxt = ref Context(display, nil, nil);
	}

	# Create new process group for isolation
	sys->pctl(Sys->NEWPGRP, nil);

	# Load and run the app
	appmod := load Command "/dis/" + appdis;
	if(appmod == nil) {
		sys->fprint(sys->fildes(2), "wminit: cannot load %s: %r\n", appdis);
		raise "fail:load";
	}

	# Run the app with our display context
	appmod->init(ctxt, appargs);
}
