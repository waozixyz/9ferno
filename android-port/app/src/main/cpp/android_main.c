/*
 * Android NativeActivity entry point for TaijiOS
 * Integrates OpenGL ES graphics, touch input, and the Dis VM
 */

#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <android/looper.h>
#include <android/input.h>
#include <EGL/egl.h>
#include <android_native_app_glue.h>

#include "dat.h"
#include "fns.h"
#include "error.h"

#define LOG_TAG "TaijiOS"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/*
 * Forward declarations
 */
extern int win_init(struct android_app* app);
extern void win_cleanup(void);
extern void win_resize(int width, int height);
extern void win_swap(void);
extern int32_t android_handle_input_event(struct android_app* app, AInputEvent* event);
extern void libinit(char* imod);
extern void android_fs_init(const char* internal_path, const char* external_path);
extern void audio_init(void);
extern void audio_close(void);

/*
 * Android app state
 */
struct android_app* g_app = nil;
static int g_running = 0;
static int g_surface_ready = 0;

/*
 * Command handler from Android
 */
static void
android_handle_cmd(struct android_app* app, int32_t cmd)
{
	switch(cmd) {
	case APP_CMD_SAVE_STATE:
		LOGI("APP_CMD_SAVE_STATE");
		break;

	case APP_CMD_INIT_WINDOW:
		LOGI("APP_CMD_INIT_WINDOW");
		if(app->window != nil) {
			if(win_init(app) == 0) {
				g_surface_ready = 1;
				g_running = 1;
			}
		}
		break;

	case APP_CMD_TERM_WINDOW:
		LOGI("APP_CMD_TERM_WINDOW");
		g_surface_ready = 0;
		win_cleanup();
		break;

	case APP_CMD_GAINED_FOCUS:
		LOGI("APP_CMD_GAINED_FOCUS");
		g_running = 1;
		break;

	case APP_CMD_LOST_FOCUS:
		LOGI("APP_CMD_LOST_FOCUS");
		g_running = 0;
		break;

	case APP_CMD_CONFIG_CHANGED:
		LOGI("APP_CMD_CONFIG_CHANGED");
		if(app->window != nil && g_surface_ready) {
			int32_t width = ANativeWindow_getWidth(app->window);
			int32_t height = ANativeWindow_getHeight(app->window);
			win_resize(width, height);
		}
		break;

	case APP_CMD_LOW_MEMORY:
		LOGI("APP_CMD_LOW_MEMORY");
		/* TODO: Tell Inferno to free memory */
		break;

	case APP_CMD_START:
		LOGI("APP_CMD_START");
		break;

	case APP_CMD_RESUME:
		LOGI("APP_CMD_RESUME");
		break;

	case APP_CMD_PAUSE:
		LOGI("APP_CMD_PAUSE");
		g_running = 0;
		break;

	case APP_CMD_STOP:
		LOGI("APP_CMD_STOP");
		break;

	case APP_CMD_DESTROY:
		LOGI("APP_CMD_DESTROY");
		g_running = 0;
		break;

	default:
		LOGI("Unhandled command: %d", cmd);
		break;
	}
}

/*
 * Main entry point
 */
void
android_main(struct android_app* state)
{
	int events;
	struct android_poll_source* source;

	g_app = state;

	/* Set up the app's state */
	state->userData = nil;
	state->onAppCmd = android_handle_cmd;
	state->onInputEvent = android_handle_input_event;

	LOGI("TaijiOS Android port starting...");

	/* Wait for window to be ready */
	while(!g_surface_ready) {
		if(ALooper_pollOnce(-1, nil, &events, (void**)&source) >= 0) {
			if(source != nil)
				source->process(state, source);
		}
	}

	LOGI("Window ready, initializing file system...");

	/* Initialize file system paths */
	jobject activity = state->activity->clazz;
	JNIEnv* env;
	(*state->activity->vm)->GetEnv(state->activity->vm, (void**)&env, JNI_VERSION_1_6);

	if(env != nil) {
		/* Get internal storage path */
		jclass clazz = (*env)->GetObjectClass(env, activity);
		jmethodID method = (*env)->GetMethodID(env, clazz, "getFilesDir", "()Ljava/io/File;");
		jobject file = (*env)->CallObjectMethod(env, activity, method);
		if(file != nil) {
			jmethodID getPath = (*env)->GetMethodID(env, (*env)->GetObjectClass(env, file), "getPath", "()Ljava/lang/String;");
			jstring path = (*env)->CallObjectMethod(env, file, getPath);
			const char* pathStr = (*env)->GetStringUTFChars(env, path, nil);
			android_fs_init(pathStr, "/sdcard/TaijiOS");
			(*env)->ReleaseStringUTFChars(env, path, pathStr);
		}
	}

	LOGI("Initializing audio...");
	audio_init();

	LOGI("Initializing Inferno...");

	/*
	 * Initialize the Inferno emu
	 * Use a simple initial module for testing
	 */
	libinit("emu-g");

	LOGI("Inferno initialized, entering main loop...");

	/* Main event loop */
	while(g_running) {
		/* Read all pending events */
		int ident = ALooper_pollAll(0, nil, &events, (void**)&source);

		if(ident >= 0 && source != nil) {
			source->process(state, source);
		}

		/* Check if we're exiting */
		if(state->destroyRequested != 0) {
			LOGI("Destroy requested, exiting...");
			g_running = 0;
			break;
		}

			/* Render a frame */
		if(g_surface_ready) {
			/* vmachine now runs in its own pthread, spawned from libinit */
			/* The event loop only handles Android events and rendering */
			win_swap();
		}
	}

	LOGI("TaijiOS shutting down...");
	audio_close();
	win_cleanup();
}
