/*
 * Android Window Manager Context Implementation
 *
 * This file implements the Wmcontext layer that bridges Android input
 * events to the Tk widget system through channels (Queues).
 *
 * Channel Layout:
 * - kbd:   Android keyboard -> Tk widgets (keycodes)
 * - ptr:   Android touch -> Tk widgets (Pointer events)
 * - ctl:   WM -> Application (reshape, focus, etc.)
 * - wctl:  Application -> WM (reshape requests, etc.)
 * - images: Image exchange (for window content sharing)
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include <cursor.h>

#include <android/log.h>
#define LOG_TAG "TaijiOS-WM"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#include "wm.h"

/*
 * Global active wmcontext
 * Set when a window gains focus
 */
Wmcontext* g_active_wmcontext = nil;

/*
 * Forward declarations
 */
static void wmcontext_freeclose(Wmcontext* wm);

/*
 * Get current timestamp in milliseconds
 * Used for Pointer events
 */
int
wmcontext_msec(void)
{
	/* TODO: Use Android's clock_gettime(CLOCK_MONOTONIC) */
	/* For now, return 0 */
	return 0;
}

/*
 * Create a new wmcontext
 * Called from Dis VM when creating Draw->Wmcontext
 */
Wmcontext*
wmcontext_create(void* drawctxt)
{
	Wmcontext* wm;

	wm = mallocz(sizeof(Wmcontext), 1);
	if(wm == nil) {
		LOGE("wmcontext_create: malloc failed");
		return nil;
	}

	/* Initialize reference counting */
	wm->r.ref = 1;
	wm->refcount = 1;
	wm->closed = 0;
	wm->active = 0;
	wm->drawctxt = drawctxt;

	/* Create channels (Queues) */
	/* Queue size: 256 events should be sufficient */
	/* Qmsg for message queue, nil for notify and aux */
	wm->kbd = qopen(256, Qmsg, nil, nil);
	if(wm->kbd == nil)
		goto error;

	wm->ptr = qopen(256, Qmsg, nil, nil);
	if(wm->ptr == nil)
		goto error;

	wm->ctl = qopen(256, Qmsg, nil, nil);
	if(wm->ctl == nil)
		goto error;

	wm->wctl = qopen(256, Qmsg, nil, nil);
	if(wm->wctl == nil)
		goto error;

	wm->images = qopen(64, Qmsg, nil, nil);
	if(wm->images == nil)
		goto error;

	LOGI("wmcontext_create: Created wmcontext %p", wm);
	return wm;

error:
	LOGE("wmcontext_create: Failed to allocate queues");
	wmcontext_freeclose(wm);
	free(wm);
	return nil;
}

/*
 * Close and free all resources
 * Called when reference count reaches zero
 */
static void
wmcontext_freeclose(Wmcontext* wm)
{
	if(wm == nil)
		return;

	LOGI("wmcontext_freeclose: Closing wmcontext %p", wm);

	if(wm->kbd != nil) {
		qclose(wm->kbd);
		wm->kbd = nil;
	}
	if(wm->ptr != nil) {
		qclose(wm->ptr);
		wm->ptr = nil;
	}
	if(wm->ctl != nil) {
		qclose(wm->ctl);
		wm->ctl = nil;
	}
	if(wm->wctl != nil) {
		qclose(wm->wctl);
		wm->wctl = nil;
	}
	if(wm->images != nil) {
		qclose(wm->images);
		wm->images = nil;
	}

	wm->closed = 1;
}

/*
 * Increment reference count
 */
void
wmcontext_ref(Wmcontext* wm)
{
	if(wm == nil)
		return;
	lock(&wm->lk);
	wm->refcount++;
	unlock(&wm->lk);
}

/*
 * Decrement reference count, free if reaches zero
 */
void
wmcontext_unref(Wmcontext* wm)
{
	int ref;

	if(wm == nil)
		return;

	lock(&wm->lk);
	ref = --wm->refcount;
	unlock(&wm->lk);

	if(ref <= 0) {
		LOGI("wmcontext_unref: Freeing wmcontext %p", wm);
		wmcontext_freeclose(wm);
		/* If this was active, clear it */
		if(g_active_wmcontext == wm) {
			g_active_wmcontext = nil;
		}
		free(wm);
	}
}

/*
 * Close all channels and mark as closed
 */
void
wmcontext_close(Wmcontext* wm)
{
	if(wm == nil)
		return;

	lock(&wm->lk);
	if(!wm->closed) {
		wm->closed = 1;
		/* Wake up any readers by sending nil */
		qwrite(wm->kbd, nil, 0);
		qwrite(wm->ptr, nil, 0);
		qwrite(wm->ctl, nil, 0);
		qwrite(wm->wctl, nil, 0);
		qwrite(wm->images, nil, 0);
	}
	unlock(&wm->lk);
}

/*
 * Send keyboard event to kbd channel
 * Called from input thread (deveia.c)
 */
void
wmcontext_send_kbd(Wmcontext* wm, int key)
{
	if(wm == nil || wm->closed)
		return;

	if(wm->kbd != nil) {
		qwrite(wm->kbd, (char*)&key, sizeof(key));
	}
}

/*
 * Send pointer event to ptr channel
 * Called from input thread (deveia.c)
 */
void
wmcontext_send_ptr(Wmcontext* wm, int buttons, int x, int y)
{
	WmPointer ptr;

	if(wm == nil || wm->closed)
		return;

	ptr.buttons = buttons;
	ptr.x = x;
	ptr.y = y;
	ptr.msec = wmcontext_msec();

	if(wm->ptr != nil) {
		qwrite(wm->ptr, (char*)&ptr, sizeof(ptr));
	}
}

/*
 * Send control message to ctl channel (WM -> app)
 */
void
wmcontext_send_ctl(Wmcontext* wm, const char* msg)
{
	int len;

	if(wm == nil || wm->closed || msg == nil)
		return;

	len = strlen(msg) + 1;
	if(wm->ctl != nil) {
		qwrite(wm->ctl, msg, len);
	}
}

/*
 * Receive keyboard event from kbd channel
 * Returns 1 if event received, 0 if queue empty/closed
 */
int
wmcontext_recv_kbd(Wmcontext* wm, int* key_out)
{
	int n;

	if(wm == nil || wm->closed || key_out == nil)
		return 0;

	if(wm->kbd == nil)
		return 0;

	n = qread(wm->kbd, (char*)key_out, sizeof(int));
	if(n != sizeof(int))
		return 0;

	return 1;
}

/*
 * Receive pointer event from ptr channel
 * Returns allocated WmPointer* or nil if queue empty/closed
 * Caller must free the returned pointer
 */
WmPointer*
wmcontext_recv_ptr(Wmcontext* wm)
{
	WmPointer* ptr;
	int n;

	if(wm == nil || wm->closed)
		return nil;

	if(wm->ptr == nil)
		return nil;

	ptr = mallocz(sizeof(WmPointer), 1);
	if(ptr == nil)
		return nil;

	n = qread(wm->ptr, (char*)ptr, sizeof(WmPointer));
	if(n != sizeof(WmPointer)) {
		free(ptr);
		return nil;
	}

	return ptr;
}

/*
 * Receive control message from ctl channel
 * Returns allocated string or nil if queue empty/closed
 * Caller must free the returned string
 */
char*
wmcontext_recv_ctl(Wmcontext* wm)
{
	char buf[256];
	int n;

	if(wm == nil || wm->closed)
		return nil;

	if(wm->ctl == nil)
		return nil;

	n = qread(wm->ctl, buf, sizeof(buf) - 1);
	if(n <= 0)
		return nil;

	buf[n] = '\0';
	return strdup(buf);
}

/*
 * Send wctl request (app -> WM)
 */
void
wmcontext_send_wctl(Wmcontext* wm, const char* request)
{
	int len;

	if(wm == nil || wm->closed || request == nil)
		return;

	len = strlen(request) + 1;
	if(wm->wctl != nil) {
		qwrite(wm->wctl, request, len);
	}
}

/*
 * Receive wctl response (WM -> app)
 * Returns allocated string or nil if queue empty
 */
char*
wmcontext_recv_wctl(Wmcontext* wm)
{
	char buf[256];
	int n;

	if(wm == nil || wm->closed)
		return nil;

	if(wm->wctl == nil)
		return nil;

	n = qread(wm->wctl, buf, sizeof(buf) - 1);
	if(n <= 0)
		return nil;

	buf[n] = '\0';
	return strdup(buf);
}

/*
 * Process wctl request and send response via ctl channel
 * This is called by the WM thread to handle reshape, move, etc.
 *
 * For Android, we act as both WM and app, so this is simpler
 */
void
wmcontext_process_wctl(Wmcontext* wm)
{
	char* request;
	char response[256];

	if(wm == nil || wm->closed)
		return;

	/* Read request from wctl channel */
	request = wmcontext_recv_wctl(wm);
	if(request == nil)
		return;

	LOGI("wmcontext_process_wctl: Request: %s", request);

	/* Parse request and send response via ctl */
	/* Common requests:
	 * - "reshape name x y w h"
	 * - "move name x y"
	 * - "size name w h"
	 */

	/* For now, just acknowledge */
	snprint(response, sizeof(response), "ok");
	wmcontext_send_ctl(wm, response);

	free(request);
}

/*
 * Set as active context (receives input events)
 */
void
wmcontext_set_active(Wmcontext* wm)
{
	if(g_active_wmcontext == wm)
		return;

	LOGI("wmcontext_set_active: Setting %p as active", wm);
	g_active_wmcontext = wm;
}

/*
 * Get active context
 */
Wmcontext*
wmcontext_get_active(void)
{
	return g_active_wmcontext;
}

/*
 * Clear active context
 */
void
wmcontext_clear_active(void)
{
	LOGI("wmcontext_clear_active: Clearing active context");
	g_active_wmcontext = nil;
}

/*
 * Check if context is valid
 */
int
wmcontext_is_valid(Wmcontext* wm)
{
	return (wm != nil && !wm->closed);
}

/*
 * Initialize WM subsystem (called at startup)
 * Creates a default wmcontext for Android so that /dev/wmctx-* devices work
 */
void
wm_init(void)
{
	Wmcontext* wm;

	LOGI("wm_init: Initializing Window Manager subsystem");

	/* Create a default wmcontext for Android */
	wm = wmcontext_create(nil);
	if(wm == nil) {
		LOGE("wm_init: Failed to create default wmcontext");
		return;
	}

	/* Set it as active so input events are routed to it */
	wmcontext_set_active(wm);

	LOGI("wm_init: Default wmcontext %p created and set as active", wm);
}

/*
 * Cleanup WM subsystem (called at shutdown)
 */
void
wm_shutdown(void)
{
	LOGI("wm_shutdown: Window Manager subsystem shutting down");
	g_active_wmcontext = nil;
}

/*
 * Process and display images from wmcontext
 * This should be called regularly from the main event loop
 * Returns 1 if an image was displayed, 0 otherwise
 */
int
wmcontext_update_display(Wmcontext* wm)
{
	Image* img;
	int display_updated = 0;

	if(wm == nil || wm->closed || wm->images == nil)
		return 0;

	/* Try to read an image from the queue without blocking */
	while(qcanread(wm->images)) {
		Image* img_ptr;
		long n = qread(wm->images, (char*)&img_ptr, sizeof(Image*));
		if(n == sizeof(Image*) && img_ptr != nil) {
			LOGI("wmcontext_update_display: Received image %p", img_ptr);
			LOGI("  Image rect: (%d,%d)-(%d,%d)",
			     img_ptr->r.min.x, img_ptr->r.min.y,
			     img_ptr->r.max.x, img_ptr->r.max.y);
			LOGI("  Image depth=%d, chan=0x%x", img_ptr->depth, img_ptr->chan);

			/* TODO: Copy image data to screen buffer */
			/* Image data is stored in Screen->screenimage->data */
			/* Need to access through the draw device layer */

			display_updated = 1;
		}
	}

	return display_updated;
}

/*
 * Update display from active wmcontext
 * Convenience function to call from main loop
 */
int
wm_update_active_display(void)
{
	if(g_active_wmcontext != nil) {
		return wmcontext_update_display(g_active_wmcontext);
	}
	return 0;
}
