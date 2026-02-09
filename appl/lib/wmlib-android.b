implement Wmlib;

#
# Android Window Manager Library for TaijiOS
#
# This module provides wmlib functionality for Android by reading
# from /dev/wmctx-* devices that expose wmcontext Queues as files.
#
# Architecture:
#   Android Input -> deveia.c -> wmcontext Queues
#   -> devwmctx.c -> /dev/wmctx-* -> wmlib-android.b -> Limbo channels
#   -> tkclient.b -> Tk widgets
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Screen, Rect, Point, Pointer, Wmcontext, Context: import draw;
include "wmlib.m";

# Pointer event buffer size - matches wmlib.b
Ptrsize: con 1+4*12;	# 'm' plus 4 12-digit decimal integers

# Device paths
DEVWMCTX_KBD: con "/dev/wmctx-kbd";
DEVWMCTX_PTR: con "/dev/wmctx-ptr";
DEVWMCTX_CTL: con "/dev/wmctx-ctl";

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
}

# Create a Draw context with Android display
makedrawcontext(): ref Draw->Context
{
	sys->fprint(sys->fildes(2), "wmlib-android: makedrawcontext ENTRY - calling Display.allocate(nil)\n");
	display := Display.allocate(nil);
	if(display == nil){
		sys->fprint(sys->fildes(2), "wmlib-android: can't allocate Display: %r\n");
		raise "fail:no display";
	}
	sys->fprint(sys->fildes(2), "wmlib-android: makedrawcontext - Display allocated successfully\n");
	return ref Draw->Context(display, nil, nil);
}

# Import draw context from external WM - not used on Android
# This is a stub for compatibility with the wmlib module interface
importdrawcontext(devdraw, mntwm: string): (ref Draw->Context, string)
{
	if(mntwm == nil)
		mntwm = "/mnt/wm";

	# Android doesn't support external WM, just create a local context
	return (makedrawcontext(), nil);
}

# Connect to window manager - creates Wmcontext with reader processes
# For Android, this creates channels and spawns processes to read from /dev devices
connect(ctxt: ref Context): ref Wmcontext
{
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "wmlib-android: no draw context\n");
		raise "fail:error";
	}

	# Create channels
	wm := ref Wmcontext(
		chan of int,
		chan of ref Pointer,
		chan of string,
		nil,	# wctl - unused for standalone Android
		chan of ref Image,
		nil,	# connfd - not needed for direct device access
		ctxt
	);

	# Spawn reader processes to pull from /dev/wmctx-* devices and send to channels
	spawn kbdproc(wm.kbd);
	spawn ptrproc(wm.ptr);
	spawn ctlproc(wm.ctl);

	return wm;
}

# Start input devices - no-op for Android (devices are always available)
startinput(wm: ref Wmcontext, devs: list of string): string
{
	# Devices are already available via /dev/wmctx-*
	return nil;
}

# Reshape window - minimal implementation for fullscreen
reshape(wm: ref Wmcontext, name: string, r: Draw->Rect, i: ref Draw->Image, how: string): ref Draw->Image
{
	# For Android fullscreen, reshape is a no-op
	return i;
}

# Window manager control - handle commands like "exit", "reshape"
wmctl(wm: ref Wmcontext, request: string): (string, ref Image, string)
{
	sys->fprint(sys->fildes(2), "wmlib-android: wmctl ENTRY, request=%s\n", request);

	(w, e) := qword(request, 0);
	case w {
	"exit" =>
		sys->fprint(sys->fildes(2), "wmlib-android: exit\n");
		raise "exit";
	"reshape" =>
		# No-op for fullscreen
		sys->fprint(sys->fildes(2), "wmlib-android: reshape returning (nil, nil, nil)\n");
		return (nil, nil, nil);
	* =>
		# Return unhandled request
		sys->fprint(sys->fildes(2), "wmlib-android: unhandled request, returning %s\n", request);
		return (request, nil, nil);
	}
}

# Keyboard reader process
# Reads from /dev/wmctx-kbd and sends to kbd channel
kbdproc(kbd: chan of int)
{
	fd := sys->open(DEVWMCTX_KBD, Sys->OREAD);
	if(fd == nil) {
		sys->fprint(sys->fildes(2), "wmlib-android: cannot open %s: %r\n", DEVWMCTX_KBD);
		return;
	}

	# 4-byte buffer for int (little-endian)
	buf := array[4] of byte;

	while((n := sys->read(fd, buf, len buf)) > 0) {
		if(n != 4)
			continue;

		# Convert little-endian bytes to int
		key := int buf[0] |
		       (int buf[1] << 8) |
		       (int buf[2] << 16) |
		       (int buf[3] << 24);

		kbd <-= key;
	}
}

# Pointer reader process
# Reads from /dev/wmctx-ptr and sends to ptr channel
ptrproc(ptr: chan of ref Pointer)
{
	fd := sys->open(DEVWMCTX_PTR, Sys->OREAD);
	if(fd == nil) {
		sys->fprint(sys->fildes(2), "wmlib-android: cannot open %s: %r\n", DEVWMCTX_PTR);
		return;
	}

	buf := array[Ptrsize] of byte;

	while((n := sys->read(fd, buf, len buf)) > 0) {
		p := bytes2ptr(string buf[0:n]);
		if(p != nil)
			ptr <-= p;
	}
}

# Convert bytes to Pointer
# Format: "m x y buttons msec" (11+1+11+1+11+1+11+1 = 49 bytes)
bytes2ptr(s: string): ref Pointer
{
	if(len s < Ptrsize || s[0] != 'm')
		return nil;

	x := int string s[1:13];
	y := int string s[13:25];
	but := int string s[25:37];
	msec := int string s[37:49];

	return ref Pointer (but, (x, y), msec);
}

# Control reader process
# Reads from /dev/wmctx-ctl and sends to ctl channel
ctlproc(ctl: chan of string)
{
	fd := sys->open(DEVWMCTX_CTL, Sys->OREAD);
	if(fd == nil) {
		sys->fprint(sys->fildes(2), "wmlib-android: cannot open %s: %r\n", DEVWMCTX_CTL);
		return;
	}

	buf := array[256] of byte;

	while((n := sys->read(fd, buf, len buf)) > 0) {
		ctl <-= string buf[0:n];
	}
}

# Snarf (clipboard) get - stub implementation
snarfget(): string
{
	return "";
}

# Snarf (clipboard) put - stub implementation
snarfput(buf: string)
{
	# No clipboard support yet
}

# Utility functions - copied from wmlib.b

# return (qslice, end).
# the slice has a leading quote if the word is quoted; it does not include the terminating quote.
splitqword(s: string, start: int): ((int, int), int)
{
	for(; start < len s; start++)
		if(s[start] != ' ')
			break;
	if(start >= len s)
		return ((start, start), start);
	i := start;
	end := -1;
	if(s[i] == '\''){
		gotq := 0;
		for(i++; i < len s; i++){
			if(s[i] == '\''){
				if(i + 1 >= len s || s[i + 1] != '\''){
					end = i+1;
					break;
				}
				i++;
				gotq = 1;
			}
		}
		if(!gotq && i > start+1)
			start++;
		if(end == -1)
			end = i;
	} else {
		for(; i < len s; i++)
			if(s[i] == ' ')
				break;
		end = i;
	}
	return ((start, i), end);
}

# unquote a string slice as returned by sliceqword.
qslice(s: string, r: (int, int)): string
{
	if(r.t0 == r.t1)
		return nil;
	if(s[r.t0] != '\'')
		return s[r.t0:r.t1];
	t := "";
	for(i := r.t0 + 1; i < r.t1; i++){
		t[len t] = s[i];
		if(s[i] == '\'')
			i++;
	}
	return t;
}

qword(s: string, start: int): (string, int)
{
	(w, next) := splitqword(s, start);
	return (qslice(s, w), next);
}

# Send string to channel
sendreq(c: chan of string, s: string)
{
	c <-= s;
}

# Kill a process by PID
kill(pid: int, note: string): int
{
	fd := sys->open("#p/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil)		# dodgy failover
		fd = sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}

# Parse string to Rect - for reshape commands
s2r(s: string, e: int): (Rect, int)
{
	r: Rect;
	w: string;
	(w, e) = qword(s, e);
	r.min.x = int w;
	(w, e) = qword(s, e);
	r.min.y = int w;
	(w, e) = qword(s, e);
	r.max.x = int w;
	(w, e) = qword(s, e);
	r.max.y = int w;
	return (r, e);
}
