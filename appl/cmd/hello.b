implement Hello;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;

Hello: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	sys->print("Hello from TaijiOS isolated instance!\n");

	# Print arguments
	sys->print("Arguments:\n");
	for(i := 0; argv != nil; argv = tl argv)
		sys->print("  [%d] %s\n", i++, hd argv);

	# Check display context
	if(ctxt != nil) {
		sys->print("Display context is available\n");
		if(ctxt.display != nil)
			sys->print("Display is initialized\n");
	}

	# Keep process alive briefly
	sys->sleep(1000);
	sys->print("Goodbye!\n");
}
