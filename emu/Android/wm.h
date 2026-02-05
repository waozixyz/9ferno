/*
 * Android Window Manager Context
 * Provides communication channels between Android input and Tk widgets
 *
 * This layer bridges Android input events to the Tk widget system
 * through Wmcontext channels (kbd, ptr, ctl, wctl, images).
 */

#ifndef WM_H
#define WM_H

#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

/*
 * Wmcontext - Window Manager Context
 *
 * Corresponds to Draw->Wmcontext ADT in draw.m
 * Channels are implemented as Queues for thread-safe communication
 */
typedef struct Wmcontext Wmcontext;

struct Wmcontext {
	Ref		r;			/* Reference counting */
	Lock		lk;			/* Lock for thread safety */

	/* Channels (implemented as Queues) */
	Queue*	kbd;			/* Keyboard events -> int (keycode) */
	Queue*	ptr;			/* Pointer events -> Pointer* */
	Queue*	ctl;			/* Control commands from WM -> string */
	Queue*	wctl;			/* WM control commands to WM -> string */
	Queue*	images;			/* Image exchange -> Image* */

	/* Associated draw context */
	void*	drawctxt;		/* Draw_Context pointer (opaque) */

	/* State */
	int		refcount;		/* Reference count */
	int		closed;			/* Whether context is closed */
	int		active;			/* Whether this is the active context */
};

/*
 * Pointer data structure for mouse/touch events
 * Matches Draw->Pointer ADT in draw.m
 */
typedef struct WmPointer WmPointer;

struct WmPointer {
	int		buttons;		/* Button state (1=left, 2=middle, 4=right) */
	int		x;				/* X coordinate */
	int		y;				/* Y coordinate */
	int		msec;			/* Timestamp in milliseconds */
};

/*
 * Global active wmcontext
 * Set when a window gains focus, used to route input events
 */
extern Wmcontext*	g_active_wmcontext;

/*
 * Wmcontext Creation and Destruction
 */

/* Create a new wmcontext */
Wmcontext*	wmcontext_create(void* drawctxt);

/* Increment reference count */
void		wmcontext_ref(Wmcontext* wm);

/* Decrement reference count, free if zero */
void		wmcontext_unref(Wmcontext* wm);

/* Close all channels and mark as closed */
void		wmcontext_close(Wmcontext* wm);

/*
 * Event Sending
 * These are called from input thread (deveia.c)
 */

/* Send keyboard event to kbd channel */
void		wmcontext_send_kbd(Wmcontext* wm, int key);

/* Send pointer event to ptr channel */
void		wmcontext_send_ptr(Wmcontext* wm, int buttons, int x, int y);

/* Send control message to ctl channel (WM -> app) */
void		wmcontext_send_ctl(Wmcontext* wm, const char* msg);

/*
 * Event Receiving
 * These are called from Dis VM / Tk thread
 */

/* Receive keyboard event from kbd channel */
/* Returns 1 if event received, 0 if queue empty/closed */
int		wmcontext_recv_kbd(Wmcontext* wm, int* key_out);

/* Receive pointer event from ptr channel */
/* Returns allocated WmPointer* or nil if queue empty/closed */
WmPointer*	wmcontext_recv_ptr(Wmcontext* wm);

/* Receive control message from ctl channel */
/* Returns allocated string or nil if queue empty/closed */
char*		wmcontext_recv_ctl(Wmcontext* wm);

/*
 * WM Control Protocol
 * Bidirectional communication between app and window manager
 */

/* Send wctl request (app -> WM) */
void		wmcontext_send_wctl(Wmcontext* wm, const char* request);

/* Receive wctl response (WM -> app) */
/* Returns allocated string or nil if queue empty */
char*		wmcontext_recv_wctl(Wmcontext* wm);

/* Process wctl request and send response via ctl channel */
/* Called by WM thread to handle reshape, move, etc. */
void		wmcontext_process_wctl(Wmcontext* wm);

/*
 * Active Context Management
 */

/* Set as active context (receives input events) */
void		wmcontext_set_active(Wmcontext* wm);

/* Get active context */
Wmcontext*	wmcontext_get_active(void);

/* Clear active context (set to nil) */
void		wmcontext_clear_active(void);

/*
 * Utility Functions
 */

/* Check if context is valid (not nil, not closed) */
int		wmcontext_is_valid(Wmcontext* wm);

/* Get current timestamp in milliseconds */
int		wmcontext_msec(void);

/* Initialize WM subsystem (called at startup) */
void		wm_init(void);

/* Cleanup WM subsystem (called at shutdown) */
void		wm_shutdown(void);

/*
 * Display Update Functions
 * Process images from wmcontext and update screen
 */

/* Update display from wmcontext images queue */
/* Returns 1 if image was processed, 0 otherwise */
int		wmcontext_update_display(Wmcontext* wm);

/* Update display from active wmcontext */
/* Convenience function for main loop */
int		wm_update_active_display(void);

#endif /* WM_H */
