#include "lib9.h"
#include "draw.h"
#include <kernel.h>
#include "tk.h"

#define RGB(R,G,B) ((R<<24)|(G<<16)|(B<<8)|(0xff))

enum
{
	tkBackR		= 0xdd,		/* Background base color */
	tkBackG 	= 0xdd,
	tkBackB 	= 0xdd,

	tkSelectR	= 0xb0,		/* Check box selected color */
	tkSelectG	= 0x30,
	tkSelectB	= 0x60,

	tkSelectbgndR	= 0x40,		/* Selected item background */
	tkSelectbgndG	= 0x40,
	tkSelectbgndB	= 0x40
};

typedef struct Coltab Coltab;
struct Coltab {
	int	c;
	ulong rgba;
	int shade;
};

static Coltab coltab[] =
{
	TkCbackgnd,
		RGB(tkBackR, tkBackG, tkBackB),
		TkSameshade,
	TkCbackgndlght,
		RGB(tkBackR, tkBackG, tkBackB),
		TkLightshade,
	TkCbackgnddark,
		RGB(tkBackR, tkBackG, tkBackB),
		TkDarkshade,
	TkCactivebgnd,
		RGB(tkBackR+0x10, tkBackG+0x10, tkBackB+0x10),
		TkSameshade,
	TkCactivebgndlght,
		RGB(tkBackR+0x10, tkBackG+0x10, tkBackB+0x10),
		TkLightshade,
	TkCactivebgnddark,
		RGB(tkBackR+0x10, tkBackG+0x10, tkBackB+0x10),
		TkDarkshade,
	TkCactivefgnd,
		RGB(0, 0, 0),
		TkSameshade,
	TkCforegnd,
		RGB(0, 0, 0),
		TkSameshade,
	TkCselect,
		RGB(tkSelectR, tkSelectG, tkSelectB),
		TkSameshade,
	TkCselectbgnd,
		RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),
		TkSameshade,
	TkCselectbgndlght,
		RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),
		TkLightshade,
	TkCselectbgnddark,
		RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),
		TkDarkshade,
	TkCselectfgnd,
		RGB(0xff, 0xff, 0xff),
		TkSameshade,
	TkCdisablefgnd,
		RGB(0x88, 0x88, 0x88),
		TkSameshade,
	TkChighlightfgnd,
		RGB(0, 0, 0),
		TkSameshade,
	TkCtransparent,
		DTransparent,
		TkSameshade,
	TkCtitlebgnd,
		RGB(0x41, 0x69, 0xE1),		/* Royal blue (active title bar) */
		TkSameshade,
	TkCtitlebginactive,
		RGB(0xD3, 0xD3, 0xD3),		/* Light gray (inactive title bar) */
		TkSameshade,
	TkCtitlefgnd,
		RGB(0xFF, 0xFF, 0xFF),		/* White (title text) */
		TkSameshade,
	TkCtitleborder,
		RGB(0x30, 0x30, 0x30),		/* Dark gray (title border) */
		TkSameshade,
	TkCtitlebutton,
		RGB(0xF0, 0xF0, 0xF0),		/* Light gray (title buttons) */
		TkSameshade,
	TkCtoolbarbgnd,
		RGB(0xDD, 0xDD, 0xDD),		/* Toolbar background */
		TkSameshade,
	TkCtoolbarfgnd,
		RGB(0x00, 0x00, 0x00),		/* Toolbar text/icon */
		TkSameshade,
	TkCtoolbarbutton,
		RGB(0xE0, 0xE0, 0xE0),		/* Toolbar button background */
		TkSameshade,
	TkCtoolbarbuttonactive,
		RGB(0xC0, 0xC0, 0xC0),		/* Toolbar button active */
		TkSameshade,
	TkCshelltext,
		RGB(0x00, 0x00, 0x00),		/* Shell text - black (matches classic theme) */
		TkSameshade,
	TkCshellbackground,
		RGB(0xFF, 0xFF, 0xFF),		/* Shell background - white (matches classic theme) */
		TkSameshade,
	-1,
};

void
tksetenvcolours(TkEnv *env)
{
	int fd, n;
	char buf[128];

	/*
	 * Don't read colors - just check version and mark invalid
	 * Colors will be loaded lazily when first accessed
	 */

	/* Track theme version for live updates */
	fd = kopen("#w/ctl", OREAD);
	if(fd >= 0) {
		n = kread(fd, buf, sizeof(buf)-1);
		kclose(fd);
		if(n > 0) {
			buf[n] = '\0';
			/* Parse version from "version N" */
			char *p = strstr(buf, "version ");
			if(p != nil) {
				env->themeversion = atoll(p + 8);
			}
		}
	} else {
		env->themeversion = 0;
	}

	env->colors_valid = 0;  /* Mark cache as invalid - colors loaded lazily */
}

/*
 * tkloadcolors - Lazy color loader
 * Loads colors from theme device on first access
 */
void
tkloadcolors(TkEnv *env)
{
	Coltab *c;
	int i, fd, n;
	char path[32];
	char buf[32];
	ulong color;

	/* Read colors from #w/{0..25} (theme device) */
	for(i = 0; i < TkNcolor; i++) {
		snprint(path, sizeof(path), "#w/%d", i);
		fd = kopen(path, OREAD);

		if(fd >= 0) {
			n = kread(fd, buf, sizeof(buf)-1);
			kclose(fd);

			if(n > 0) {
				buf[n] = '\0';
				/* Skip leading # if present */
				if(buf[0] == '#') {
					color = strtoul(buf+1, nil, 16);
					env->colors[i] = color;
					env->set |= (1<<i);
					continue;  /* Got this color, move to next */
				}
			}
		}

		/* Failed to read this color - mark as unset, will use default later */
		env->set &= ~(1<<i);
	}

	/*
	 * Fill in any missing colors from default coltab[]
	 * This allows partial theme overrides while keeping defaults for unset colors
	 */
	c = &coltab[0];
	while(c->c != -1) {
		if(!(env->set & (1<<c->c))) {
			env->colors[c->c] = tkrgbashade(c->rgba, c->shade);
			env->set |= (1<<c->c);
		}
		c++;
	}

	env->colors_valid = 1;  /* Cache is now valid */
}
