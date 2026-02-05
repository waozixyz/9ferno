/*
 * TaijiOS Android Native Activity
 * Initializes and runs the TaijiOS emulator
 */

#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <android/input.h>
#include <android/looper.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>

/* Inferno headers - include dat.h first for all type definitions */
#include "dat.h"
#include "fns.h"
#include "error.h"
#include <draw.h>
#include <memdraw.h>
#include <android/asset_manager.h>

#define LOG_TAG "TaijiOS"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Global asset manager for loading Dis bytecode files */
AAssetManager* g_asset_manager = NULL;

/* Get the global asset manager (for use by devfs.c) */
AAssetManager* android_get_asset_manager(void) {
	return g_asset_manager;
}

/* Set the global asset manager (called from NativeActivity) */
void set_asset_manager(AAssetManager* manager) {
	g_asset_manager = manager;
	LOGI("set_asset_manager: Asset manager set to %p", manager);
}

/* Read Dis file from assets into memory */
uchar* load_dis_from_assets(const char* path, int* size_out) {
	if (!g_asset_manager) {
		LOGE("load_dis_from_assets: Asset manager not initialized!");
		return NULL;
	}

	AAsset* asset = AAssetManager_open(g_asset_manager, path, AASSET_MODE_BUFFER);
	if (!asset) {
		LOGE("load_dis_from_assets: Failed to open %s", path);
		return NULL;
	}

	off_t size = AAsset_getLength(asset);
	uchar* buffer = malloc(size + 1);  /* +1 for null terminator */
	if (!buffer) {
		LOGE("load_dis_from_assets: Failed to allocate %ld bytes", (long)size);
		AAsset_close(asset);
		return NULL;
	}

	int read_result = AAsset_read(asset, buffer, size);
	if (read_result != size) {
		LOGE("load_dis_from_assets: Only read %d of %ld bytes", read_result, (long)size);
		free(buffer);
		AAsset_close(asset);
		return NULL;
	}

	buffer[size] = '\0';  /* Null terminate for safety */
	AAsset_close(asset);

	*size_out = (int)size;
	LOGI("load_dis_from_assets: Loaded %s, %d bytes", path, (int)size);
	return buffer;
}

/* Forward declarations from emu/Android/os.c and emu/Android/win.c */
extern void libinit(char *imod);
extern void vmachine(void *arg);
extern int dflag;

/* Draw interface - from win.c */
extern Memdata* attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen);
extern void flushmemscreen(Rectangle r);

/* Forward declarations */
static int make_context_current(void);
static void draw_test_pattern(void);

/* Simple draw test */
static void draw_test_pattern(void) {
	LOGI("draw_test_pattern: Starting");

	/* Make EGL context current on this thread */
	if (!make_context_current()) {
		LOGE("draw_test_pattern: Failed to make context current");
		return;
	}

	Rectangle r;
	ulong chan;
	int depth, width, softscreen;

	/* Get the screen buffer */
	Memdata *md = attachscreen(&r, &chan, &depth, &width, &softscreen);
	if (md == nil) {
		LOGE("draw_test_pattern: attachscreen failed!");
		return;
	}

	LOGI("draw_test_pattern: Screen %dx%d, chan=%lux, depth=%d",
	     r.max.x - r.min.x, r.max.y - r.min.y, chan, depth);

	/* Draw a simple test pattern directly to the screen buffer */
	uchar *base = md->bdata;
	int swidth = r.max.x - r.min.x;
	int sheight = r.max.y - r.min.y;

	LOGI("draw_test_pattern: Drawing test pattern...");

	/* Clear to black */
	memset(base, 0, swidth * sheight * 4);

	/* Draw a red rectangle at the top */
	int y;
	for (y = 0; y < sheight / 4; y++) {
		int x;
		for (x = 0; x < swidth; x++) {
			int offset = (y * swidth + x) * 4;
			base[offset + 0] = 0;     /* B */
			base[offset + 1] = 0;     /* G */
			base[offset + 2] = 255;   /* R */
			base[offset + 3] = 255;   /* A */
		}
	}

	/* Draw a green rectangle in the middle */
	for (y = sheight / 4; y < sheight / 2; y++) {
		int x;
		for (x = 0; x < swidth; x++) {
			int offset = (y * swidth + x) * 4;
			base[offset + 0] = 0;     /* B */
			base[offset + 1] = 255;   /* G */
			base[offset + 2] = 0;     /* R */
			base[offset + 3] = 255;   /* A */
		}
	}

	/* Draw a blue rectangle at the bottom */
	for (y = sheight / 2; y < sheight * 3 / 4; y++) {
		int x;
		for (x = 0; x < swidth; x++) {
			int offset = (y * swidth + x) * 4;
			base[offset + 0] = 255;   /* B */
			base[offset + 1] = 0;     /* G */
			base[offset + 2] = 0;     /* R */
			base[offset + 3] = 255;   /* A */
		}
	}

	/* Draw a white rectangle at the bottom */
	for (y = sheight * 3 / 4; y < sheight; y++) {
		int x;
		for (x = 0; x < swidth; x++) {
			int offset = (y * swidth + x) * 4;
			base[offset + 0] = 255;   /* B */
			base[offset + 1] = 255;   /* G */
			base[offset + 2] = 255;   /* R */
			base[offset + 3] = 255;   /* A */
		}
	}

	LOGI("draw_test_pattern: Flushing screen...");
	flushmemscreen(r);
	LOGI("draw_test_pattern: Complete!");
}

/* EGL state - accessible by win.c */
EGLDisplay g_display = EGL_NO_DISPLAY;
EGLSurface g_surface = EGL_NO_SURFACE;
EGLContext g_context = EGL_NO_CONTEXT;
static ANativeActivity* g_activity = NULL;
static pthread_t g_emu_thread = 0;
static int g_emu_running = 0;

/* Helper to make EGL context current on this thread */
static int make_context_current(void) {
	if (g_display == EGL_NO_DISPLAY || g_surface == EGL_NO_SURFACE) {
		LOGE("make_context_current: EGL not initialized");
		return 0;
	}

	/* Check if context is already current */
	if (eglGetCurrentContext() == g_context) {
		return 1;  /* Already current */
	}

	/* Make it current on this thread */
	if (!eglMakeCurrent(g_display, g_surface, g_surface, g_context)) {
		LOGE("make_context_current: eglMakeCurrent failed: 0x%x", eglGetError());
		return 0;
	}
	return 1;
}

static void init_egl(ANativeWindow* window) {
	g_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (g_display == EGL_NO_DISPLAY) {
		LOGE("eglGetDisplay failed");
		return;
	}

	if (!eglInitialize(g_display, NULL, NULL)) {
		LOGE("eglInitialize failed");
		return;
	}

	EGLint config_attribs[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_BLUE_SIZE, 8,
		EGL_GREEN_SIZE, 8,
		EGL_RED_SIZE, 8,
		EGL_ALPHA_SIZE, 8,
		EGL_NONE
	};

	EGLConfig config;
	EGLint num_configs;
	if (!eglChooseConfig(g_display, config_attribs, &config, 1, &num_configs)) {
		LOGE("eglChooseConfig failed");
		return;
	}

	g_surface = eglCreateWindowSurface(g_display, config, window, NULL);
	if (g_surface == EGL_NO_SURFACE) {
		LOGE("eglCreateWindowSurface failed");
		return;
	}

	EGLint context_attribs[] = {
		EGL_CONTEXT_CLIENT_VERSION, 2,
		EGL_NONE
	};
	g_context = eglCreateContext(g_display, config, EGL_NO_CONTEXT, context_attribs);
	if (g_context == EGL_NO_CONTEXT) {
		LOGE("eglCreateContext failed");
		return;
	}

	if (!eglMakeCurrent(g_display, g_surface, g_surface, g_context)) {
		LOGE("eglMakeCurrent failed");
		return;
	}

	LOGI("EGL initialized successfully");
}

static void draw_frame() {
	if (g_display != EGL_NO_DISPLAY && g_surface != EGL_NO_SURFACE) {
		glClearColor(0.1f, 0.1f, 0.3f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		eglSwapBuffers(g_display, g_surface);
	}
}

static void cleanup_egl() {
	if (g_display != EGL_NO_DISPLAY) {
		eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		if (g_context != EGL_NO_CONTEXT) {
			eglDestroyContext(g_display, g_context);
		}
		if (g_surface != EGL_NO_SURFACE) {
			eglDestroySurface(g_display, g_surface);
		}
		eglTerminate(g_display);
	}
	g_display = EGL_NO_DISPLAY;
	g_context = EGL_NO_CONTEXT;
	g_surface = EGL_NO_SURFACE;
}

/*
 * Emulator thread - runs the TaijiOS Dis VM
 * This is where the actual emulator execution happens
 *
 * NOTE: vmachine is now spawned as a pthread from libinit(), so we
 * don't call vmachine(nil) here anymore. The vmachine thread runs
 * independently and handles all Dis VM execution.
 */
static void* emu_thread_func(void* arg) {
	LOGI("Emulator thread: Starting");

	/* Initialize the TaijiOS emulator */
	LOGI("Emulator thread: Calling libinit");
	libinit("emu-g");  /* Use emu-g module (graphical version) */

	LOGI("Emulator thread: libinit returned");
	LOGI("Emulator thread: vmachine thread spawned from libinit");

	/* vmachine now runs in its own pthread, spawned from libinit */
	/* This thread can now be used for other purposes or just wait */

	LOGI("Emulator thread: Waiting for VM to complete...");
	/* TODO: Wait for vmachine thread to complete */
	/* For now, just sleep to keep thread alive */
	while (g_emu_running) {
		usleep(100000);  /* 100ms */
	}

	LOGI("Emulator thread: Exiting");
	return NULL;
}

/*
 * Start the emulator thread when the window is ready
 */
static void start_emulator() {
	if (g_emu_thread != 0) {
		LOGI("Emulator already running");
		return;
	}

	g_emu_running = 1;
	int result = pthread_create(&g_emu_thread, NULL, emu_thread_func, NULL);
	if (result != 0) {
		LOGE("Failed to create emulator thread: %d", result);
		return;
	}

	LOGI("Emulator thread started");
}

/*
 * Stop the emulator thread
 */
static void stop_emulator() {
	if (g_emu_thread == 0) {
		return;
	}

	g_emu_running = 0;
	pthread_join(g_emu_thread, NULL);
	g_emu_thread = 0;

	LOGI("Emulator thread stopped");
}

/* Callbacks */
static void onDestroy(ANativeActivity* activity) {
	LOGI("onDestroy");
	stop_emulator();
	cleanup_egl();
}

static void onStart(ANativeActivity* activity) {
	LOGI("onStart");
}

static void onResume(ANativeActivity* activity) {
	LOGI("onResume");
}

static void onPause(ANativeActivity* activity) {
	LOGI("onPause");
}

static void onStop(ANativeActivity* activity) {
	LOGI("onStop");
}

static void onNativeWindowCreated(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window created");
	init_egl(window);

	/* Start the emulator after EGL is initialized */
	start_emulator();

	/* The VM will render to the screen through flushmemscreen() calls */
}

static void onNativeWindowDestroyed(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window destroyed");
	stop_emulator();
	cleanup_egl();
}

static void onNativeWindowResized(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window resized");
}

static void onNativeWindowRedrawNeeded(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window redraw needed");
	/* Don't clear the screen - preserve what was drawn */
	/* draw_frame(); */
}

static void onInputQueueCreated(ANativeActivity* activity, AInputQueue* queue) {
	LOGI("Input queue created");
}

static void onInputQueueDestroyed(ANativeActivity* activity, AInputQueue* queue) {
	LOGI("Input queue destroyed");
}

static void onWindowFocusChanged(ANativeActivity* activity, int focused) {
	LOGI("Window focus changed: %d", focused);
}

/* NativeActivity entry point */
void ANativeActivity_onCreate(ANativeActivity* activity, void* savedState, size_t savedStateSize) {
	LOGI("TaijiOS Android port - Emulator Version");
	LOGI("Device: 9B161FFAZ000FP");
	LOGI("Initializing TaijiOS emulator...");

	/* Set debug flag for more verbose output */
	dflag = 1;

	activity->callbacks->onDestroy = onDestroy;
	activity->callbacks->onStart = onStart;
	activity->callbacks->onResume = onResume;
	activity->callbacks->onPause = onPause;
	activity->callbacks->onStop = onStop;
	activity->callbacks->onNativeWindowCreated = onNativeWindowCreated;
	activity->callbacks->onNativeWindowDestroyed = onNativeWindowDestroyed;
	activity->callbacks->onNativeWindowResized = onNativeWindowResized;
	activity->callbacks->onNativeWindowRedrawNeeded = onNativeWindowRedrawNeeded;
	activity->callbacks->onInputQueueCreated = onInputQueueCreated;
	activity->callbacks->onInputQueueDestroyed = onInputQueueDestroyed;
	activity->callbacks->onWindowFocusChanged = onWindowFocusChanged;

	g_activity = activity;
	activity->instance = activity;

	/* Set the global asset manager for loading Dis bytecode files */
	set_asset_manager(activity->assetManager);

	LOGI("NativeActivity callbacks registered");
}
