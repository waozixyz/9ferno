/*
 * Android touch input driver for TaijiOS
 * Maps Android touch events to mouse events for compatibility
 *
 * Phase 1: Now also routes input to active Wmcontext for Tk widgets
 */

#include <android/input.h>
#include <android/keycodes.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_activity.h>
#include <android_native_app_glue.h>

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "wm.h"

#define LOG_TAG "TaijiOS-EIA"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/*
 * Touch state tracking
 */
typedef struct {
	int active;
	int buttons;
	int x;
	int y;
	int last_x;
	int last_y;
} TouchState;

static TouchState touchscreen = {
	.active = 0,
	.buttons = 0,
	.x = 0,
	.y = 0,
	.last_x = 0,
	.last_y = 0
};

/*
 * External references from graphics system
 */
extern Queue* gkbdq;
extern Queue* gkscanq;

/*
 * Active Wmcontext for Tk widget input routing
 * Set when a window gains focus via wmcontext_set_active()
 */
extern Wmcontext* g_active_wmcontext;

/*
 * Convert Android keycode to Plan 9/Inferno keysym
 */
static int
android_to_p9key(int keycode)
{
	switch(keycode) {
	case AKEYCODE_BACK:		/* Kbs|Kb|0x78 - Android back */
		return 0x10000;	/* Special: Back button */
	case AKEYCODE_MENU:
		return 0x10001;	/* Special: Menu button */
	case AKEYCODE_HOME:
		return 0x10002;	/* Special: Home button */
	case AKEYCODE_ENTER:
	case AKEYCODE_NUMPAD_ENTER:
		return '\n';
	case AKEYCODE_TAB:
		return '\t';
	case AKEYCODE_SPACE:
		return ' ';
	case AKEYCODE_DEL:
		return 0x08;	/* Backspace */
	case AKEYCODE_FORWARD_DEL:
		return 0x7F;	/* Delete */
	case AKEYCODE_ESCAPE:
		return 0x1B;
	/* Arrow keys */
	case AKEYCODE_DPAD_UP:
		return 0xF80E;	/* Kup */
	case AKEYCODE_DPAD_DOWN:
		return 0xF800;	/* Kdown */
	case AKEYCODE_DPAD_LEFT:
		return 0xF802;	/* Kleft */
	case AKEYCODE_DPAD_RIGHT:
		return 0xF801;	/* Kright */
	/* Function keys */
	case AKEYCODE_F1:
		return 0xF800 + 1;
	case AKEYCODE_F2:
		return 0xF800 + 2;
	case AKEYCODE_F3:
		return 0xF800 + 3;
	case AKEYCODE_F4:
		return 0xF800 + 4;
	case AKEYCODE_F5:
		return 0xF800 + 5;
	case AKEYCODE_F6:
		return 0xF800 + 6;
	case AKEYCODE_F7:
		return 0xF800 + 7;
	case AKEYCODE_F8:
		return 0xF800 + 8;
	case AKEYCODE_F9:
		return 0xF800 + 9;
	case AKEYCODE_F10:
		return 0xF800 + 10;
	case AKEYCODE_F11:
		return 0xF800 + 11;
	case AKEYCODE_F12:
		return 0xF800 + 12;
	default:
		/* For alphanumeric keys, Android uses the same ASCII codes */
		if(keycode >= AKEYCODE_A && keycode <= AKEYCODE_Z)
			return 'a' + (keycode - AKEYCODE_A);
		if(keycode >= AKEYCODE_0 && keycode <= AKEYCODE_9)
			return '0' + (keycode - AKEYCODE_0);
		return 0;
	}
}

/*
 * Handle touch events from Android
 * Called from the Android main event loop
 */
int32_t
android_handle_input_event(struct android_app* app, AInputEvent* event)
{
	int type = AInputEvent_getType(event);

	if(type == AINPUT_EVENT_TYPE_MOTION) {
		int action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;
		float x = AMotionEvent_getX(event, 0);
		float y = AMotionEvent_getY(event, 0);
		int mouse_buttons = 0;

		switch(action) {
		case AMOTION_EVENT_ACTION_DOWN:
			touchscreen.active = 1;
			touchscreen.buttons = 1;	/* Left button */
			touchscreen.x = (int)x;
			touchscreen.y = (int)y;
			mouse_buttons = 1;
			LOGI("Touch DOWN: x=%d y=%d", touchscreen.x, touchscreen.y);
			break;

		case AMOTION_EVENT_ACTION_UP:
			touchscreen.active = 0;
			touchscreen.buttons = 0;
			touchscreen.last_x = (int)x;
			touchscreen.last_y = (int)y;
			mouse_buttons = 0;
			LOGI("Touch UP: x=%d y=%d", touchscreen.last_x, touchscreen.last_y);
			break;

		case AMOTION_EVENT_ACTION_MOVE:
			touchscreen.last_x = touchscreen.x;
			touchscreen.last_y = touchscreen.y;
			touchscreen.x = (int)x;
			touchscreen.y = (int)y;
			mouse_buttons = touchscreen.buttons;
			/* LOGI("Touch MOVE: x=%d y=%d", touchscreen.x, touchscreen.y); */
			break;

		case AMOTION_EVENT_ACTION_CANCEL:
			touchscreen.active = 0;
			touchscreen.buttons = 0;
			LOGI("Touch CANCEL");
			break;

		default:
			return 0;
		}

		/* Send mouse event to graphics queue (legacy) */
		if(gkbdq != nil) {
			/* Format: buttons | (x << 8) | (y << 20) */
			int mev = mouse_buttons | (touchscreen.x << 8) | (touchscreen.y << 20);
			qproduce(gkbdq, (char*)&mev, sizeof(mev));
		}

		/* Also send to active wmcontext for Tk widgets */
		if(g_active_wmcontext != nil) {
			wmcontext_send_ptr(g_active_wmcontext, mouse_buttons,
							  touchscreen.x, touchscreen.y);
		}

		return 1;
	}
	else if(type == AINPUT_EVENT_TYPE_KEY) {
		int keycode = AKeyEvent_getKeyCode(event);
		int action = AKeyEvent_getAction(event);
		int p9key;

		if(action == AKEY_EVENT_ACTION_UP) {
			/* Key release */
			p9key = android_to_p9key(keycode);
			if(p9key != 0 && gkscanq != nil) {
				int kev = p9key | 0x80000000;	/* Release flag */
				qproduce(gkscanq, (char*)&kev, sizeof(kev));
			}
			/* Also send to active wmcontext for Tk widgets */
			if(g_active_wmcontext != nil && p9key != 0) {
				/* For Tk, send release with high bit set */
				wmcontext_send_kbd(g_active_wmcontext, p9key | 0x80000000);
			}
			return 1;
		}
		else if(action == AKEY_EVENT_ACTION_DOWN) {
			/* Key press */
			p9key = android_to_p9key(keycode);
			if(p9key != 0) {
				if(gkscanq != nil) {
					qproduce(gkscanq, (char*)&p9key, sizeof(p9key));
				}
				/* Also send to active wmcontext for Tk widgets */
				if(g_active_wmcontext != nil) {
					wmcontext_send_kbd(g_active_wmcontext, p9key);
				}
				LOGI("Key DOWN: p9key=0x%x", p9key);
			}
			return 1;
		}
	}

	return 0;
}

/*
 * Show/hide virtual keyboard
 * Note: This function is simplified for modern NDK
 */
void
android_show_keyboard(struct android_app* app, int show)
{
	JNIEnv* env;
	JavaVM* vm = app->activity->vm;
	jobject activity = app->activity->clazz;

	(*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6);
	if(env == nil)
		return;

	/* Get the class loader approach for modern NDK */
	jclass activity_class = (*env)->FindClass(env, "android/app/NativeActivity");
	if(activity_class == nil)
		return;

	/* Get InputMethodManager using the activity's context */
	jmethodID get_system_service = (*env)->GetMethodID(env, activity_class,
		"getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
	if(get_system_service == nil)
		return;

	jstring service_name = (*env)->NewStringUTF(env, "input_method");
	jobject inputMethodManager = (*env)->CallObjectMethod(env, activity, get_system_service, service_name);

	if(inputMethodManager == nil)
		return;

	jclass imm_class = (*env)->FindClass(env, "android/view/inputmethod/InputMethodManager");
	if(imm_class == nil)
		return;

	if(show) {
		/* Show soft input */
		jmethodID show_soft_input = (*env)->GetMethodID(env, imm_class,
			"showSoftInput", "(Landroid/view/View;I)Z");
		if(show_soft_input == nil)
			return;

		/* Get the window decor view */
		jmethodID get_window = (*env)->GetMethodID(env, activity_class,
			"getWindow", "()Landroid/view/Window;");
		jobject window = (*env)->CallObjectMethod(env, activity, get_window);

		jclass window_class = (*env)->FindClass(env, "android/view/Window");
		jmethodID get_decor_view = (*env)->GetMethodID(env, window_class,
			"getDecorView", "()Landroid/view/View;");
		jobject decor_view = (*env)->CallObjectMethod(env, window, get_decor_view);

		(*env)->CallBooleanMethod(env, inputMethodManager, show_soft_input, decor_view, 0);
	} else {
		/* Hide soft input - requires window token */
		/* Simplified - just toggle the input method */
		jmethodID hide_soft_input = (*env)->GetMethodID(env, imm_class,
			"toggleSoftInput", "(II)Z");
		if(hide_soft_input != nil)
			(*env)->CallBooleanMethod(env, inputMethodManager, hide_soft_input, 0, 0);
	}
}
