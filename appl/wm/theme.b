implement Theme;

#
# Theme Switcher for TaijiOS
# Allows switching between system themes via /dev/theme
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;

Theme: module {
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

badmodule(p: string)
{
	sys->fprint(sys->fildes(2), "theme: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

THEMEDIR := "/lib/theme/";
DEVTHEME := "#w/";

display: ref Display;
top: ref Tk->Toplevel;
themes: list of string;

tkcfg := array[] of {
	"frame .f",
	"label .title -text {TaijiOS Theme Switcher}",
	"pack .title -pady 10",
	# Taller listbox with scrollbar - fill available space
	"frame .listframe -relief sunken -borderwidth 1",
	"listbox .listframe.lst -width 40 -yscrollcommand {.listframe.sb set}",
	"scrollbar .listframe.sb -command {.listframe.lst yview}",
	"pack .listframe.sb -side right -fill y",
	"pack .listframe.lst -side left -fill both -expand 1",
	"pack .listframe -fill both -expand 1 -padx 20 -pady 10",
	"bind .listframe.lst <Double-Button-1> {send cmd apply}",
	"frame .btns",
	"button .btns.apply -text Apply -command {send cmd apply}",
	"button .btns.reload -text Reload -command {send cmd reload}",
	"button .btns.close -text Close -command {send cmd exit}",
	"pack .btns.apply .btns.reload .btns.close -side left -padx 5 -pady 10",
	"pack .btns",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		badmodule(Tkclient->PATH);

	sys->pctl(Sys->NEWPGRP, nil);

	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	# Load available themes
	themes = find_themes();

	# Create window
	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "Theme", Tkclient->Appl);

	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");

	for(i := 0; i < len tkcfg; i++)
		cmd(top, tkcfg[i]);

	# Populate theme list
	populate_themes();

	tk->cmd(top, "update");
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd"::"ptr"::nil);

	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	c := <-top.ctxt.ctl or
	c = <-top.wreq or
	c = <-menubut =>
		if(c == "exit")
			return;
		tkclient->wmctl(top, c);

	cmd := <-cmdch =>
		case cmd {
		"exit" =>
			return;
		"apply" =>
			apply_theme();
		"reload" =>
			reload_themes();
		}
	}
}

find_themes(): list of string
{
	fd := sys->open(THEMEDIR, Sys->OREAD);
	if(fd == nil)
		return nil;

	all: list of string = nil;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < len dirs; i++) {
			if(len dirs[i].name > 6 && dirs[i].name[len dirs[i].name-6:] == ".theme")
				all = dirs[i].name :: all;
		}
	}
	return all;
}

populate_themes()
{
	# Clear existing
	cmd(top, ".listframe.lst delete 0 end");

	# Add themes
	for(t := themes; t != nil; t = tl t)
		cmd(top, sys->sprint(".listframe.lst insert end {%s}", hd t));

	# Get current theme
	cur := current_theme();
	if(cur != nil) {
		# Update title to show current theme
		cmd(top, sys->sprint(".title configure -text {Theme: %s}", cur));

		# Try to select current theme
		i := 0;
		for(t := themes; t != nil; t = tl t) {
			if(hd t == cur) {
				cmd(top, sys->sprint(".listframe.lst selection clear 0 end"));
				cmd(top, sys->sprint(".listframe.lst selection set %d", i));
				cmd(top, sys->sprint(".listframe.lst see %d", i));
				break;
			}
			i++;
		}
	} else {
		cmd(top, ".title configure -text {Theme: default}");
	}
}

current_theme(): string
{
	fd := sys->open(DEVTHEME + "theme", Sys->OREAD);
	if(fd == nil)
		return nil;

	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;

	return string buf[0:n];
}

get_selected(): string
{
	sel := cmd(top, ".listframe.lst curselection");
	if(sel == nil || sel == "")
		return nil;

	# Parse index
	i := int sel;
	if(i < 0 || i >= len themes)
		return nil;

	# Get theme name
	t := themes;
	while(i > 0 && t != nil) {
		t = tl t;
		i--;
	}
	if(t == nil)
		return nil;

	name := hd t;
	# Strip .theme suffix
	if(len name > 6 && name[len name-6:] == ".theme")
		name = name[0:len name-6];

	return name;
}

apply_theme()
{
	theme := get_selected();
	if(theme == nil) {
		cmd(top, ".title configure -text {No theme selected!}");
		return;
	}

	# Write to #w/theme (kernel device path)
	fd := sys->open("#w/theme", Sys->OWRITE);
	if(fd == nil) {
		cmd(top, ".title configure -text {Cannot open #w/theme!}");
		return;
	}

	if(sys->write(fd, array of byte theme, len theme) != len theme) {
		cmd(top, ".title configure -text {Failed to write theme!}");
		return;
	}

	# Device file closed automatically

	# Force immediate refresh of current window's theme
	# This ensures the theme switcher itself updates with the new colors
	tk->refreshallenvs();

	# Update our title text
	cmd(top, sys->sprint(".title configure -text {Theme: %s}", theme));

	# DONE! Kernel handles everything else automatically:
	# - Theme loaded into #w/0-25 color files
	# - drawwakeall() notifies all processes
	# - Each process's next event triggers tkrefreshallthemes()
	# - All widgets update automatically
}

reload_themes()
{
	themes = find_themes();
	populate_themes();
	cmd(top, ".title configure -text {Theme list reloaded}");
}

cmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		sys->print("theme: tk error '%s': %s\n", s, e);
	return e;
}
