/*
 * Minimal TaijiOS Android test
 * Simple native activity that logs and clears screen
 */

#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <android/input.h>
#include <android/looper.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <unistd.h>

#define LOG_TAG "TaijiOS"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static EGLDisplay g_display = EGL_NO_DISPLAY;
static EGLSurface g_surface = EGL_NO_SURFACE;
static EGLContext g_context = EGL_NO_CONTEXT;
static ANativeActivity* g_activity = NULL;

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

// Callbacks
static void onDestroy(ANativeActivity* activity) {
	LOGI("onDestroy");
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

	// Render a few frames
	for (int i = 0; i < 10; i++) {
		draw_frame();
		usleep(16667);
	}
}

static void onNativeWindowDestroyed(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window destroyed");
	cleanup_egl();
}

static void onNativeWindowResized(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window resized");
}

static void onNativeWindowRedrawNeeded(ANativeActivity* activity, ANativeWindow* window) {
	LOGI("Native window redraw needed");
	draw_frame();
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

// NativeActivity entry point
void ANativeActivity_onCreate(ANativeActivity* activity, void* savedState, size_t savedStateSize) {
	LOGI("TaijiOS Android port - Test Version");
	LOGI("Device: 9B161FFAZ000FP");

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
}
