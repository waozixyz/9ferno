/*
 * Android Window Manager Context Device Driver
 * Exposes wmcontext Queues as /dev/wmctx-* files
 *
 * This device driver bridges C Queues (from wm.c) to Limbo code
 * by exposing them as character devices that can be read via sys->open()/sys->read()
 *
 * Device files:
 * - /dev/wmctx-kbd: Keyboard events (4-byte int)
 * - /dev/wmctx-ptr: Pointer events (49-byte string: "m x y buttons msec")
 * - /dev/wmctx-ctl: Control messages (variable string)
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "wm.h"

#include <android/log.h>
#define LOG_TAG "TaijiOS-devwmctx"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/*
 * QID mapping for device files
 */
enum {
	Qdir,
	Qkbd,		/* Keyboard events */
	Qptr,		/* Pointer events */
	Qctl,		/* Control messages */
};

/*
 * Device directory structure
 */
static Dirtab wmctxtab[] = {
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"wmctx-kbd",	{Qkbd},			0,	0444,
	"wmctx-ptr",	{Qptr},			0,	0444,
	"wmctx-ctl",	{Qctl},			0,	0444,
};

/*
 * Forward declarations
 */
static Chan*	wmctxattach(char* spec);
static Walkqid*	wmctxwalk(Chan *c, Chan *nc, char **name, int nname);
static int	wmctxstat(Chan* c, uchar *db, int n);
static Chan*	wmctxopen(Chan* c, int omode);
static void	wmctxclose(Chan* c);
static long	wmctxread(Chan* c, void* a, long n, vlong off);
static long	wmctxwrite(Chan* c, void* a, long n, vlong off);

/*
 * Auto-create wmcontext on first access
 * This ensures /dev/wmctx-* devices work even if wm_init() wasn't called
 */
static Wmcontext* ensure_wmcontext(void)
{
	Wmcontext* wm = wmcontext_get_active();
	if(wm == 0) {
		/* Create a default wmcontext */
		wm = wmcontext_create(0);
		if(wm != 0) {
			wmcontext_set_active(wm);
		}
	}
	return wm;
}

/*
 * Read keyboard event from active wmcontext
 * Blocks until data is available
 * Returns 4-byte int in little-endian format
 */
static long
wmctx_kbd_read(Chan* c, void* a, long n, vlong off)
{
	int key;
	int nbytes;
	Wmcontext* wm;

	USED(c);
	USED(off);

	/* Ensure wmcontext exists */
	wm = ensure_wmcontext();
	if(wm == nil) {
		return 0;
	}

	/* Read from queue (blocks until data available) */
	if(wmcontext_recv_kbd(wm, &key) == 0) {
		/* Queue closed or no data */
		return 0;
	}

	/* Return 4-byte int */
	nbytes = sizeof(int);
	if(n > nbytes)
		n = nbytes;

	/* Copy to user buffer in little-endian */
	uchar* buf = (uchar*)a;
	buf[0] = key & 0xFF;
	buf[1] = (key >> 8) & 0xFF;
	buf[2] = (key >> 16) & 0xFF;
	buf[3] = (key >> 24) & 0xFF;

	LOGI("wmctx_kbd_read: Read key 0x%x", key);
	return n;
}

/*
 * Read pointer event from active wmcontext
 * Blocks until data is available
 * Returns 49-byte string: "m x y buttons msec" (11+1+11+1+11+1+11+1+1 = 49)
 * Format matches wmlib's Ptrsize constant
 */
static long
wmctx_ptr_read(Chan* c, void* a, long n, vlong off)
{
	WmPointer* ptr;
	Wmcontext* wm;
	char buf[64];
	int len;

	USED(c);
	USED(off);

	/* Ensure wmcontext exists */
	wm = ensure_wmcontext();
	if(wm == 0) {
		return 0;
	}

	/* Read from queue (blocks until data available) */
	ptr = wmcontext_recv_ptr(wm);
	if(ptr == 0) {
		/* Queue closed or no data */
		return 0;
	}

	/* Format: "m%11d %11d %11d %11d " matches wmlib Ptrsize */
	/* 'm' + 11-digit x + space + 11-digit y + space + 11-digit buttons + space + 11-digit msec + space */
	len = snprint(buf, sizeof(buf), "m%11d %11d %11d %11d ",
	              ptr->x, ptr->y, ptr->buttons, ptr->msec);

	if(len > n)
		len = n;

	memmove(a, buf, len);

	LOGI("wmctx_ptr_read: Read ptr x=%d y=%d b=%d", ptr->x, ptr->y, ptr->buttons);
	free(ptr);
	return len;
}

/*
 * Read control message from active wmcontext
 * Blocks until data is available
 * Returns variable-length string (including null terminator)
 */
static long
wmctx_ctl_read(Chan* c, void* a, long n, vlong off)
{
	char* msg;
	Wmcontext* wm;
	int len;

	USED(c);
	USED(off);

	/* Ensure wmcontext exists */
	wm = ensure_wmcontext();
	if(wm == 0) {
		return 0;
	}

	/* Read from queue (blocks until data available) */
	msg = wmcontext_recv_ctl(wm);
	if(msg == 0) {
		/* Queue closed or no data */
		return 0;
	}

	len = strlen(msg) + 1;  /* Include null terminator */
	if(len > n)
		len = n;

	memmove(a, msg, len);

	LOGI("wmctx_ctl_read: Read ctl: %s", msg);
	free(msg);
	return len;
}

/*
 * Device read function - routes to specific read function based on QID
 */
static long
wmctxread(Chan* c, void* a, long n, vlong off)
{
	switch((ulong)c->qid.path) {
	case Qdir:
		/* Directory read */
		return devdirread(c, a, n, wmctxtab, nelem(wmctxtab), devgen);
	case Qkbd:
		return wmctx_kbd_read(c, a, n, off);
	case Qptr:
		return wmctx_ptr_read(c, a, n, off);
	case Qctl:
		return wmctx_ctl_read(c, a, n, off);
	default:
		error(Ebadusefd);
		return -1;
	}
}

/*
 * Device write function - not used for read-only devices
 */
static long
wmctxwrite(Chan* c, void* a, long n, vlong off)
{
	USED(c);
	USED(a);
	USED(n);
	USED(off);
	error(Ebadusefd);
	return -1;
}

/*
 * Attach to device
 */
static Chan*
wmctxattach(char* spec)
{
	USED(spec);
	return devattach('W', spec);
}

/*
 * Walk directory tree
 */
static Walkqid*
wmctxwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, wmctxtab, nelem(wmctxtab), devgen);
}

/*
 * Get file status
 */
static int
wmctxstat(Chan* c, uchar *db, int n)
{
	return devstat(c, db, n, wmctxtab, nelem(wmctxtab), devgen);
}

/*
 * Open device file
 */
static Chan*
wmctxopen(Chan* c, int omode)
{
	/* Only read-only access is supported */
	if(omode != OREAD)
		error(Eperm);

	return devopen(c, omode, wmctxtab, nelem(wmctxtab), devgen);
}

/*
 * Close device file
 */
static void
wmctxclose(Chan* c)
{
	USED(c);
	/* Nothing to clean up for read-only devices */
}

/*
 * Device driver table
 * This is the main structure that registers the device with the kernel
 */
Dev wmctxdevtab = {
	'W',			/* Device character */
	"wmctx",		/* Device name */

	devinit,		/* Init function (use default) */
	wmctxattach,		/* Attach function */
	wmctxwalk,		/* Walk function */
	wmctxstat,		/* Stat function */
	wmctxopen,		/* Open function */
	devcreate,		/* Create function (use default - not supported) */
	wmctxclose,		/* Close function */
	wmctxread,		/* Read function */
	devbread,		/* Block read (use default) */
	wmctxwrite,		/* Write function */
	devbwrite,		/* Block write (use default) */
	devremove,		/* Remove function (use default - not supported) */
	devwstat,		/* Wstat function (use default - not supported) */
};
