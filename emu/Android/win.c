/*
 * Android window/graphics implementation for TaijiOS
 * Uses OpenGL ES for rendering
 *
 * STATUS: Placeholder for Phase 2
 * Need to properly integrate:
 * - libinterp/draw.c (Limbo bindings)
 * - libdraw (drawing functions)
 * - libmemdraw (memory drawing)
 * - libtk (toolkit)
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "keyboard.h"

#include <android/log.h>

#define LOG_TAG "TaijiOS-Win"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/*
 * attachscreen - Create the screen buffer
 * Called by devdraw.c to initialize the screen
 * Returns pointer to Memdata, or nil on failure
 */
Memdata*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	LOGI("attachscreen: Placeholder - not yet implemented");
	(void)r;
	(void)chan;
	(void)d;
	(void)width;
	(void)softscreen;
	return nil;
}

/*
 * flushmemscreen - Flush screen rectangle to display
 * Called by devdraw.c when screen content changes
 */
void
flushmemscreen(Rectangle r)
{
	(void)r;
}

/*
 * drawcursor - Draw cursor on screen (stub for Android)
 */
void
drawcursor(Drawcursor *c)
{
	(void)c;
}
