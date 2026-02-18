/*
 *	devtheme.c - /dev/theme device driver for TaijiOS theming (emu/Linux)
 *
 *	Provides a Plan 9-style interface to global UI theme colors.
 *
 *	Usage:
 *		cat /lib/theme/ctl       - read current theme info
 *		echo 'dark' > /lib/theme/theme  - load a theme (name only)
 *		cat /lib/theme/1         - read background color
 *		echo '#FF0000FF' > /lib/theme/1  - set background color
 */
#include "dat.h"
#include "fns.h"
#include "error.h"
#include <string.h>
#include <stdio.h>
#include <dirent.h>

/* Forward declaration from devdraw.c */
extern void drawwakeall(void);

#define NTHEMECOLORS  36

/* QID path values for theme files */
enum {
	Qdir,
	Qctl,
	Qtheme,
	Qlist,
	Qevent,
	Qcolor0,   /* TkCforegnd */
	Qcolor1,   /* TkCbackgnd */
	Qcolor2,   /* TkCbackgndlght */
	Qcolor3,   /* TkCbackgnddark */
	Qcolor4,   /* TkCselect */
	Qcolor5,   /* TkCselectbgnd */
	Qcolor6,   /* TkCselectbgndlght */
	Qcolor7,   /* TkCselectbgnddark */
	Qcolor8,   /* TkCselectfgnd */
	Qcolor9,   /* TkCactivebgnd */
	Qcolor10,  /* TkCactivebgndlght */
	Qcolor11,  /* TkCactivebgnddark */
	Qcolor12,  /* TkCactivefgnd */
	Qcolor13,  /* TkCdisablefgnd */
	Qcolor14,  /* TkChighlightfgnd */
	Qcolor15,  /* TkCfill */
	Qcolor16,  /* TkCtransparent */
	Qcolor17,  /* TkCtitlebgnd */
	Qcolor18,  /* TkCtitlebginactive */
	Qcolor19,  /* TkCtitlefgnd */
	Qcolor20,  /* TkCtitleborder */
	Qcolor21,  /* TkCtitlebutton */
	Qcolor22,  /* TkCtoolbarbgnd */
	Qcolor23,  /* TkCtoolbarfgnd */
	Qcolor24,  /* TkCtoolbarbutton */
	Qcolor25,  /* TkCtoolbarbuttonactive */
	Qcolor26,  /* TkCshelltext */
	Qcolor27,  /* TkCshellbackground */
	Qcolor28,  /* TkCtoolbarbghover */
	Qcolor29,  /* TkCtoolbarbtnhover */
	Qcolor30,  /* TkCtoolbarbtndisabled */
	Qcolor31,  /* TkCtoolbarborder */
	Qcolor32,  /* TkCtoolbarmenubg */
	Qcolor33,  /* TkCtoolbarmenufg */
	Qcolor34,  /* TkCtoolbarmenuselect */
	Qcolor35,  /* TkCtoolbarfgndhover */
};

/* Theme color state */
typedef struct ThemeColor {
	char *name;
	ulong value;
	int vers;
} ThemeColor;

typedef struct ThemeState {
	Lock l;
	ThemeColor colors[NTHEMECOLORS];
	char current_theme[64];
	uvlong version;
	Rendez eventq;	/* For blocking reads on Qevent */
} ThemeState;

static ThemeState themestate;

/* Dirtab for static files - include all color entries to avoid dynamic generation */
static Dirtab themedirtab[] = {
	".",          {Qdir, 0, QTDIR}, 0,      DMDIR|0555,
	"ctl",        {Qctl}, 0, 0666,
	"theme",      {Qtheme}, 0, 0666,
	"list",       {Qlist}, 0, 0444,
	"event",      {Qevent}, 0, 0444,
	"0",          {Qcolor0}, 0, 0666,
	"1",          {Qcolor1}, 0, 0666,
	"2",          {Qcolor2}, 0, 0666,
	"3",          {Qcolor3}, 0, 0666,
	"4",          {Qcolor4}, 0, 0666,
	"5",          {Qcolor5}, 0, 0666,
	"6",          {Qcolor6}, 0, 0666,
	"7",          {Qcolor7}, 0, 0666,
	"8",          {Qcolor8}, 0, 0666,
	"9",          {Qcolor9}, 0, 0666,
	"10",         {Qcolor10}, 0, 0666,
	"11",         {Qcolor11}, 0, 0666,
	"12",         {Qcolor12}, 0, 0666,
	"13",         {Qcolor13}, 0, 0666,
	"14",         {Qcolor14}, 0, 0666,
	"15",         {Qcolor15}, 0, 0666,
	"16",         {Qcolor16}, 0, 0666,
	"17",         {Qcolor17}, 0, 0666,
	"18",         {Qcolor18}, 0, 0666,
	"19",         {Qcolor19}, 0, 0666,
	"20",         {Qcolor20}, 0, 0666,
	"21",         {Qcolor21}, 0, 0666,
	"22",         {Qcolor22}, 0, 0666,
	"23",         {Qcolor23}, 0, 0666,
	"24",         {Qcolor24}, 0, 0666,
	"25",         {Qcolor25}, 0, 0666,
	"26",         {Qcolor26}, 0, 0666,
	"27",         {Qcolor27}, 0, 0666,
	"28",         {Qcolor28}, 0, 0666,
	"29",         {Qcolor29}, 0, 0666,
	"30",         {Qcolor30}, 0, 0666,
	"31",         {Qcolor31}, 0, 0666,
	"32",         {Qcolor32}, 0, 0666,
	"33",         {Qcolor33}, 0, 0666,
	"34",         {Qcolor34}, 0, 0666,
	"35",         {Qcolor35}, 0, 0666,
};

/* Color names matching TkC indices */
static char* colornames[NTHEMECOLORS] = {
	"foreground",           /* TkCforegnd */
	"background",           /* TkCbackgnd */
	"background_light",     /* TkCbackgndlght */
	"background_dark",      /* TkCbackgnddark */
	"select",               /* TkCselect */
	"select_background",    /* TkCselectbgnd */
	"select_background_light", /* TkCselectbgndlght */
	"select_background_dark",  /* TkCselectbgnddark */
	"select_foreground",    /* TkCselectfgnd */
	"active_background",    /* TkCactivebgnd */
	"active_background_light", /* TkCactivebgndlght */
	"active_background_dark",  /* TkCactivebgnddark */
	"active_foreground",    /* TkCactivefgnd */
	"disabled_foreground",  /* TkCdisablefgnd */
	"highlight_foreground", /* TkChighlightfgnd */
	"fill",                 /* TkCfill */
	"transparent",          /* TkCtransparent */
	"title_background",     /* TkCtitlebgnd */
	"title_inactive",       /* TkCtitlebginactive */
	"title_foreground",     /* TkCtitlefgnd */
	"title_border",         /* TkCtitleborder */
	"title_button",         /* TkCtitlebutton */
	"toolbar_background",   /* TkCtoolbarbgnd */
	"toolbar_foreground",   /* TkCtoolbarfgnd */
	"toolbar_button",       /* TkCtoolbarbutton */
	"toolbar_button_active", /* TkCtoolbarbuttonactive */
	"shell_text",           /* TkCshelltext */
	"shell_background",     /* TkCshellbackground */
	"toolbar_hover",        /* TkCtoolbarbghover */
	"toolbar_btn_hover",    /* TkCtoolbarbtnhover */
	"toolbar_btn_disabled", /* TkCtoolbarbtndisabled */
	"toolbar_border",       /* TkCtoolbarborder */
	"toolbar_menu_bg",      /* TkCtoolbarmenubg */
	"toolbar_menu_fg",      /* TkCtoolbarmenufg */
	"toolbar_menu_select",  /* TkCtoolbarmenuselect */
	"toolbar_fg_hover",     /* TkCtoolbarfgndhover */
};

static int load_theme_by_name(char *name);

/*
 * Default colors MUST match libtk/colrs.c coltab[] values exactly.
 * These are the colors used when no theme is loaded.
 */
static ulong defaultcolors[NTHEMECOLORS] = {
	0x000000FF, /* foreground (TkCforegnd) */
	0xDDDDDDFF, /* background (TkCbackgnd) */
	0xEEEEEEFF, /* background_light */
	0xC8C8C8FF, /* background_dark */
	0xB03060FF, /* select (TkCselect) */
	0x404040FF, /* select_background (TkCselectbgnd) */
	0x505050FF, /* select_background_light */
	0x303030FF, /* select_background_dark */
	0xFFFFFFFF, /* select_foreground (TkCselectfgnd) */
	0xEDEDEDFF, /* active_background (TkCactivebgnd) */
	0xFEFEFEFF, /* active_background_light */
	0xD8D8D8FF, /* active_background_dark */
	0x000000FF, /* active_foreground (TkCactivefgnd) */
	0x888888FF, /* disabled_foreground (TkCdisablefgnd) */
	0x000000FF, /* highlight_foreground (TkChighlightfgnd) */
	0xDDDDDDFF, /* fill (TkCfill) */
	0x00000000, /* transparent (TkCtransparent) */
	0x4169E1FF, /* title_background (TkCtitlebgnd) - Royal blue */
	0xD3D3D3FF, /* title_inactive (TkCtitlebginactive) - Light gray */
	0xFFFFFFFF, /* title_foreground (TkCtitlefgnd) - White */
	0x303030FF, /* title_border (TkCtitleborder) - Dark gray */
	0xF0F0F0FF, /* title_button (TkCtitlebutton) - Light gray */
	0xDDDDDDFF, /* toolbar_background (TkCtoolbarbgnd) */
	0x000000FF, /* toolbar_foreground (TkCtoolbarfgnd) */
	0xE0E0E0FF, /* toolbar_button (TkCtoolbarbutton) */
	0xC0C0C0FF, /* toolbar_button_active (TkCtoolbarbuttonactive) */
	0x000000FF, /* shell_text (TkCshelltext) - Black (matches classic theme) */
	0xFFFFFFFF, /* shell_background (TkCshellbackground) - White (matches classic theme) */
	0xE8E8E8FF, /* toolbar_hover (TkCtoolbarbghover) */
	0xEEEEEEFF, /* toolbar_btn_hover (TkCtoolbarbtnhover) */
	0xBBBBBBFF, /* toolbar_btn_disabled (TkCtoolbarbtndisabled) */
	0xAAAAAAFF, /* toolbar_border (TkCtoolbarborder) */
	0xFFFFFFFF, /* toolbar_menu_bg (TkCtoolbarmenubg) */
	0x000000FF, /* toolbar_menu_fg (TkCtoolbarmenufg) */
	0x4169E1FF, /* toolbar_menu_select (TkCtoolbarmenuselect) */
	0x000000FF, /* toolbar_fg_hover (TkCtoolbarfgndhover) */
};

static void
themeinit(void)
{
	int i;

	memset(&themestate, 0, sizeof(ThemeState));

	for(i = 0; i < NTHEMECOLORS; i++) {
		themestate.colors[i].name = colornames[i];
		themestate.colors[i].value = defaultcolors[i];
		themestate.colors[i].vers = 0;
	}

	strcpy(themestate.current_theme, "default");
	themestate.version = 0;
	/* themestate.eventq.l is automatically zero-initialized via memset above */

	/* DON'T load theme here - filesystem not ready yet */
	/* Theme will be loaded lazily on first access by applications */
}

/* Load theme from /lib/theme/{name}.theme file */
static int
load_theme_by_name(char *name)
{
	int fd;
	char path[128];
	char *line, *p, *kp, *key, *val;
	int i, n;
	ulong color;
	char buf[1024];

	if(name == nil || strlen(name) == 0)
		return -1;

	/* Try /usr/theme first, then /lib/theme */
	snprint(path, sizeof(path), "/usr/theme/%s.theme", name);
	fd = kopen(path, OREAD);
	if(fd < 0) {
		snprint(path, sizeof(path), "/lib/theme/%s.theme", name);
		fd = kopen(path, OREAD);
	}
	if(fd < 0)
		return -1;

	lock(&themestate.l);

	/* Read and parse theme file */
	while((n = kread(fd, buf, sizeof(buf)-1)) > 0) {
		buf[n] = 0;
		line = buf;

		while((p = strchr(line, '\n')) != nil) {
			*p++ = 0;

			/* Skip comments and empty lines */
			while(*line == ' ' || *line == '\t') line++;
			if(*line == '#' || *line == 0) {
				line = p;
				continue;
			}

			/* Parse key = value */
			key = line;
			val = strchr(line, '=');
			if(val != nil) {
				*val++ = 0;
				/* Strip trailing spaces from key */
				kp = val - 2;  /* Point before the = */
				while(kp >= key && (*kp == ' ' || *kp == '\t'))
					*kp-- = 0;
				while(*val == ' ' || *val == '\t') val++;

				/* Parse color */
				if(*val == '#') {
					color = strtoul(val+1, nil, 16);
					for(i = 0; i < NTHEMECOLORS; i++) {
						if(strcmp(themestate.colors[i].name, key) == 0) {
							themestate.colors[i].value = color;
							themestate.colors[i].vers++;
							break;
						}
					}
				}
			}
			line = p;
		}
	}

	kclose(fd);

	strncpy(themestate.current_theme, name, sizeof(themestate.current_theme)-1);
	themestate.current_theme[sizeof(themestate.current_theme)-1] = 0;
	themestate.version++;

	Wakeup(&themestate.eventq);  /* Wake any blocked readers on Qevent */

	/* Notify all draw clients across all processes to check for theme changes */
	drawwakeall();

	unlock(&themestate.l);

	return 0;
}

/* Scan theme directories and build theme list using Inferno kernel ops */
static int
scandir_themes(char *buf, int n)
{
	int fd;
	char path[128];
	char *p = buf;
	int left = n;
	int len;
	int found = 0;
	Dir *dh;
	long ndir;
	int i, j;

	/* Track seen themes to deduplicate */
	static char seen[32][64];
	static int nseen = 0;
	int is_dup;

	/* Reset state on each call to prevent stale data from previous calls */
	nseen = 0;
	memset(seen, 0, sizeof(seen));

	/* Scan /usr/theme first (user themes), then /lib/theme (system themes) */
	char *dirs[] = {"/usr/theme", "/lib/theme"};
	int dir_idx;

	for(dir_idx = 0; dir_idx < 2; dir_idx++) {
		snprint(path, sizeof(path), "%s", dirs[dir_idx]);
		fd = kopen(path, OREAD);
		if(fd >= 0) {
			/* Read all directory entries */
			while((ndir = kdirread(fd, &dh)) > 0) {
				for(i = 0; i < ndir; i++) {
					/* Check if it's a .theme file */
					len = strlen(dh[i].name);
					if(len >= 6 && strcmp(&dh[i].name[len-6], ".theme") == 0) {
						/* Check for duplicate */
						is_dup = 0;
						for(j = 0; j < nseen; j++) {
							if(strcmp(seen[j], dh[i].name) == 0) {
								is_dup = 1;
								break;
							}
						}
						if(!is_dup && nseen < 32) {
							/* Store name without .theme suffix */
							strncpy(seen[nseen], dh[i].name, len-6);
							seen[nseen][len-6] = 0;
							nseen++;
						}
					}
				}
				free(dh);
			}
			kclose(fd);
		}
	}

	/* Build output buffer */
	for(i = 0; i < nseen; i++) {
		len = strlen(seen[i]);
		if(left >= len + 2) {  /* name + \n + null */
			strcpy(p, seen[i]);
			p[len] = '\n';
			p += len + 1;
			left -= len + 1;
			found = 1;
		}
	}

	if(!found) {
		/* Fallback if no themes found */
		strcpy(buf, "default\ndark\n");
		return strlen(buf);
	}

	*p = 0;
	return p - buf;
}

static Chan*
themeattach(char *spec)
{
	return devattach('w', spec);
}

static Walkqid*
themewalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, themedirtab, nelem(themedirtab), devgen);
}

static int
themestat(Chan *c, uchar *dp, int n)
{
	return devstat(c, dp, n, themedirtab, nelem(themedirtab), devgen);
}

static Chan*
themeopen(Chan *c, int omode)
{
	return devopen(c, omode, themedirtab, nelem(themedirtab), devgen);
}

static void
themeclose(Chan *c)
{
	USED(c);
}

/* Helper function for Sleep - returns true when theme version changes */
static int
themewait(void *v)
{
	uvlong *orig = v;
	return themestate.version != *orig;
}

static long
themeread(Chan *c, void *buf, long n, vlong off)
{
	char tmp[128];
	ulong path = c->qid.path;

	switch(path) {
	case Qdir:
		return devdirread(c, buf, n, themedirtab, nelem(themedirtab), devgen);

	case Qctl:
	case Qtheme:
		return readstr(off, buf, n, themestate.current_theme);

	case Qlist:
		if(off == 0)
			return scandir_themes(buf, n);
		return 0;

	case Qevent:
	{
		uvlong origversion;
		char tmp[128];

		lock(&themestate.l);
		origversion = themestate.version;
		unlock(&themestate.l);

		/* Block until theme version changes */
		Sleep(&themestate.eventq, themewait, &origversion);

		/* Return new version info */
		lock(&themestate.l);
		snprint(tmp, sizeof(tmp), "%lld %s\n",
			themestate.version, themestate.current_theme);
		unlock(&themestate.l);
		return readstr(off, buf, n, tmp);
	}

	default:
		/* Read color value */
		if(path >= Qcolor0 && path <= Qcolor0 + NTHEMECOLORS - 1) {
			int idx = path - Qcolor0;
			snprint(tmp, sizeof(tmp), "#%08ulX\n", themestate.colors[idx].value);
			return readstr(off, buf, n, tmp);
		}
	}

	return 0;
}

static long
themewrite(Chan *c, void *buf, long n, vlong off)
{
	char str[128];
	ulong path = c->qid.path;
	ulong color;
	char *p;

	USED(off);

	if(n >= sizeof(str))
		n = sizeof(str) - 1;
	memmove(str, buf, n);
	str[n] = 0;

	switch(path) {
	case Qctl:
	case Qtheme:
		/* Load theme by name */
		p = str;
		while(*p == ' ' || *p == '\t' || *p == '\n') p++;
		if(strlen(p) > 0 && p[strlen(p)-1] == '\n')
			p[strlen(p)-1] = 0;
		if(load_theme_by_name(p) < 0)
			return -1;  /* Error loading theme */
		return n;  /* Success - return bytes written */

	default:
		/* Write color value */
		if(path >= Qcolor0 && path <= Qcolor0 + NTHEMECOLORS - 1) {
			int idx = path - Qcolor0;

			p = str;
			while(*p == ' ' || *p == '\t') p++;
			if(*p == '#') {
				color = strtoul(p+1, nil, 16);

				lock(&themestate.l);
				themestate.colors[idx].value = color;
				themestate.colors[idx].vers++;
				themestate.version++;
				Wakeup(&themestate.eventq);  /* Wake any blocked readers on Qevent */

				unlock(&themestate.l);
				return n;
			}
		}
	}

	return -1;
}

Dev themedevtab = {
	'w',
	"theme",

	themeinit,
	themeattach,
	themewalk,
	themestat,
	themeopen,
	devcreate,
	themeclose,
	themeread,
	devbread,
	themewrite,
	devbwrite,
	devremove,
	devwstat
};
