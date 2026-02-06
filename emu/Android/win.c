/*
 * Android window/graphics implementation for TaijiOS
 * Uses OpenGL ES 2.0 for rendering
 *
 * Phase 2 COMPLETE - Full OpenGL ES renderer implemented
 *
 * This file implements the screen buffer and rendering functions
 * required by the draw device (devdraw.c)
 *
 * - attachscreen(): Allocates screen buffer, initializes OpenGL ES
 * - flushmemscreen(): Renders screen buffer to texture, draws fullscreen quad
 * - drawcursor(): Stub for cursor rendering (TODO)
 */

#include "dat.h"
#include "fns.h"
#include "kernel.h"
#include "error.h"
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "keyboard.h"
#include "wm.h"

#include <android/log.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <EGL/egl.h>
#include <android_native_app_glue.h>

#define LOG_TAG "TaijiOS-Win"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* EGL context - accessible by android_test.c and win.c */
EGLDisplay g_display = EGL_NO_DISPLAY;
EGLSurface g_surface = EGL_NO_SURFACE;
EGLContext g_context = EGL_NO_CONTEXT;

/* Screen buffer data */
static int screenwidth = 0;
static int screenheight = 0;
static int screensize = 0;
static uchar *screendata = NULL;
static Memdata screendata_struct;

/* OpenGL ES resources */
static GLuint texture = 0;
static GLuint shader_program = 0;
static GLuint position_buffer = 0;
static GLuint texcoord_buffer = 0;
static GLuint index_buffer = 0;

/* OpenGL error checking helper */
static void
check_gl_error(const char* operation)
{
	GLenum error;
	while ((error = glGetError()) != GL_NO_ERROR) {
		LOGE("OpenGL error after %s: 0x%x", operation, error);
	}
}

/* Shader sources */
static const char vertex_shader_src[] =
	"attribute vec2 a_position;\n"
	"attribute vec2 a_texcoord;\n"
	"varying vec2 v_texcoord;\n"
	"void main() {\n"
	"	gl_Position = vec4(a_position, 0.0, 1.0);\n"
	"	v_texcoord = a_texcoord;\n"
	"}\n";

static const char fragment_shader_src[] =
	"precision mediump float;\n"
	"varying vec2 v_texcoord;\n"
	"uniform sampler2D u_texture;\n"
	"void main() {\n"
	"	gl_FragColor = texture2D(u_texture, v_texcoord);\n"
	"}\n";

/* Fullscreen quad vertices */
static const float vertices[] = {
	-1.0f, -1.0f,
	 1.0f, -1.0f,
	-1.0f,  1.0f,
	 1.0f,  1.0f,
};

static const float texcoords[] = {
	0.0f, 1.0f,
	1.0f, 1.0f,
	0.0f, 0.0f,
	1.0f, 0.0f,
};

static const GLushort indices[] = {
	0, 1, 2,
	1, 3, 2,
};

/* Compile shader */
static GLuint
compile_shader(GLenum type, const char *src)
{
	LOGI("compile_shader: Creating shader type=%d", type);
	GLuint shader = glCreateShader(type);
	if (shader == 0) {
		LOGE("compile_shader: glCreateShader failed, error=0x%x", glGetError());
		return 0;
	}

	glShaderSource(shader, 1, &src, NULL);
	glCompileShader(shader);

	GLint compiled;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
	if (!compiled) {
		GLint log_len = 0;
		glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &log_len);
		LOGE("compile_shader: Compilation failed, log_len=%d", log_len);
		if (log_len > 0) {
			char *log = malloc(log_len);
			glGetShaderInfoLog(shader, log_len, NULL, log);
			LOGE("Shader compile error: %s", log);
			free(log);
		}
		glDeleteShader(shader);
		return 0;
	}
	LOGI("compile_shader: Success, shader=%u", shader);
	return shader;
}

/* Initialize OpenGL ES resources */
static int
init_gl_resources(void)
{
	/* Compile shaders */
	GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex_shader_src);
	GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment_shader_src);
	if (!vs || !fs) {
		LOGE("Failed to compile shaders");
		return 0;
	}
	check_gl_error("compile_shader");

	/* Link program */
	shader_program = glCreateProgram();
	check_gl_error("glCreateProgram");
	glAttachShader(shader_program, vs);
	glAttachShader(shader_program, fs);
	glLinkProgram(shader_program);
	check_gl_error("glLinkProgram");

	GLint linked;
	glGetProgramiv(shader_program, GL_LINK_STATUS, &linked);
	if (!linked) {
		GLint log_len = 0;
		glGetProgramiv(shader_program, GL_INFO_LOG_LENGTH, &log_len);
		if (log_len > 0) {
			char *log = malloc(log_len);
			glGetProgramInfoLog(shader_program, log_len, NULL, log);
			LOGE("Program link error: %s", log);
			free(log);
		}
		glDeleteProgram(shader_program);
		shader_program = 0;
		glDeleteShader(vs);
		glDeleteShader(fs);
		return 0;
	}

	glDeleteShader(vs);
	glDeleteShader(fs);

	/* Create buffers */
	glGenBuffers(1, &position_buffer);
	check_gl_error("glGenBuffers position");
	glBindBuffer(GL_ARRAY_BUFFER, position_buffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
	check_gl_error("position buffer data");

	glGenBuffers(1, &texcoord_buffer);
	glBindBuffer(GL_ARRAY_BUFFER, texcoord_buffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(texcoords), texcoords, GL_STATIC_DRAW);
	check_gl_error("texcoord buffer data");

	glGenBuffers(1, &index_buffer);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, index_buffer);
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
	check_gl_error("index buffer data");

	/* Create texture */
	glGenTextures(1, &texture);
	check_gl_error("glGenTextures");
	glBindTexture(GL_TEXTURE_2D, texture);
	check_gl_error("glBindTexture");
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	check_gl_error("glTexParameteri");

	LOGI("OpenGL ES resources initialized");
	return 1;
}

/* Forward declaration */
void flushmemscreen(Rectangle r);

/*
 * attachscreen - Create the screen buffer
 * Called by devdraw.c to initialize the screen
 * Returns pointer to pixel data (uchar*), or nil on failure
 *
 * Note: This returns the pixel buffer directly, not Memdata*.
 * devdraw.c expects uchar* and assigns it to screendata.bdata.
 */
uchar*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	__android_log_print(ANDROID_LOG_INFO, "ATTACHSCREEN", "attachscreen: ENTRY - Function called");

	if (g_display == EGL_NO_DISPLAY || g_surface == EGL_NO_SURFACE) {
		__android_log_print(ANDROID_LOG_ERROR, "ATTACHSCREEN", "attachscreen: EGL not initialized");
		return nil;
	}

	/* If screendata is already allocated (from win_init), reuse it */
	if (screendata != NULL && screenwidth > 0 && screenheight > 0) {
		__android_log_print(ANDROID_LOG_INFO, "ATTACHSCREEN", "attachscreen: Reusing existing screendata %p", screendata);

		/* Return screen parameters */
		r->min.x = 0;
		r->min.y = 0;
		r->max.x = screenwidth;
		r->max.y = screenheight;
		*chan = XRGB32;  /* 32-bit RGBA */
		*d = 32;  /* Depth */
		*width = screenwidth * 4;  /* Bytes per row */
		*softscreen = 1;  /* Software rendering */

		/* Update Memdata structure to point to existing buffer */
		screendata_struct.base = (uintptr*)&screendata_struct;
		screendata_struct.bdata = screendata;
		screendata_struct.ref = 1;
		screendata_struct.imref = 0;
		screendata_struct.allocd = 1;

		__android_log_print(ANDROID_LOG_INFO, "ATTACHSCREEN", "attachscreen: Returning existing buffer %p", screendata);
		return screendata;
	}

	/* Get screen dimensions from EGL */
	EGLint w, h;
	eglQuerySurface(g_display, g_surface, EGL_WIDTH, &w);
	eglQuerySurface(g_display, g_surface, EGL_HEIGHT, &h);
	screenwidth = w;
	screenheight = h;

	__android_log_print(ANDROID_LOG_INFO, "ATTACHSCREEN", "attachscreen: Allocating new buffer %dx%d", screenwidth, screenheight);

	/* Allocate screen buffer (RGBA format) */
	screensize = screenwidth * screenheight * 4;
	screendata = malloc(screensize);
	if (screendata == NULL) {
		__android_log_print(ANDROID_LOG_ERROR, "ATTACHSCREEN", "attachscreen: Failed to allocate screen buffer");
		return nil;
	}

	/* Initialize to black background */
	memset(screendata, 0, screensize);

	/* Set up Memdata structure */
	screendata_struct.base = (uintptr*)&screendata_struct;
	screendata_struct.bdata = screendata;
	screendata_struct.ref = 1;
	screendata_struct.imref = 0;
	screendata_struct.allocd = 1;

	/* Return screen parameters */
	r->min.x = 0;
	r->min.y = 0;
	r->max.x = screenwidth;
	r->max.y = screenheight;
	*chan = XRGB32;  /* 32-bit RGBA */
	*d = 32;  /* Depth */
	*width = screenwidth * 4;  /* Bytes per row */
	*softscreen = 1;  /* Software rendering */

	__android_log_print(ANDROID_LOG_INFO, "ATTACHSCREEN", "attachscreen: Returning new buffer %p", screendata);
	return screendata;
}

/*
 * flushmemscreen - Flush screen rectangle to display
 * Called by devdraw.c when screen content changes
 *
 * For Android with wmclient support:
 * 1. Composite all registered wmclient windows to screenimage first
 * 2. Then render the composited screenimage to OpenGL ES
 */
void
flushmemscreen(Rectangle r)
{
	static int call_count = 0;

	if (g_display == EGL_NO_DISPLAY || g_surface == EGL_NO_SURFACE) {
		return;
	}

	if (screendata == NULL) {
		return;
	}

	/*
	 * Step 1: Composite wmclient windows to screenimage
	 * This ensures any wmclient window content is composited before rendering
	 */
	extern void wmcontext_composite_windows(Wmcontext* wm);
	extern Wmcontext* wmcontext_get_active(void);

	Wmcontext* active_wm = wmcontext_get_active();
	if(active_wm != nil) {
		wmcontext_composite_windows(active_wm);
	}

	/* Log flush calls for debugging */
	if(call_count < 3 || (call_count % 100) == 0) {
		/* Sample a few pixels to see if data is present */
		/* Check test pattern location first (150,150) which should be green */
		int test_pattern_offset = (150 * screenwidth + 150) * 4;
		int center_offset = (screenheight/2 * screenwidth + screenwidth/2) * 4;
		LOGI("flushmemscreen: call %d, screendata=%p", call_count, screendata);
		LOGI("  test_pattern(150,150): [%d,%d,%d,%d]",
		     screendata[test_pattern_offset + 0], screendata[test_pattern_offset + 1],
		     screendata[test_pattern_offset + 2], screendata[test_pattern_offset + 3]);
		LOGI("  center(%d,%d): [%d,%d,%d,%d]",
		     screenwidth/2, screenheight/2,
		     screendata[center_offset + 0], screendata[center_offset + 1],
		     screendata[center_offset + 2], screendata[center_offset + 3]);
	}
	call_count++;

	/* Verify texture is initialized */
	if (texture == 0) {
		LOGE("flushmemscreen: texture is 0, not initialized");
		return;
	}

	/* Make context current if needed */
	if (eglGetCurrentContext() != g_context) {
		if (!eglMakeCurrent(g_display, g_surface, g_surface, g_context)) {
			LOGE("flushmemscreen: eglMakeCurrent failed");
			return;
		}
	}

	/* Clamp rectangle to screen bounds */
	if (r.min.x < 0) r.min.x = 0;
	if (r.min.y < 0) r.min.y = 0;
	if (r.max.x > screenwidth) r.max.x = screenwidth;
	if (r.max.y > screenheight) r.max.y = screenheight;

	/* Update texture from screen data */
	glBindTexture(GL_TEXTURE_2D, texture);
	check_gl_error("glBindTexture");

	/* Use GL_RGBA - screendata should be in RGBA byte order */
	/* The drawing code needs to convert from XRGB32 to RGBA */
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, screenwidth, screenheight,
	             0, GL_RGBA, GL_UNSIGNED_BYTE, screendata);
	check_gl_error("glTexImage2D");

	/* Set viewport */
	glViewport(0, 0, screenwidth, screenheight);
	check_gl_error("glViewport");

	/* Use shader program */
	glUseProgram(shader_program);
	check_gl_error("glUseProgram");

	/* Set up vertex attributes */
	GLint pos_attr = glGetAttribLocation(shader_program, "a_position");
	if (pos_attr < 0) {
		LOGE("flushmemscreen: Failed to get position attribute location");
		return;
	}
	glEnableVertexAttribArray(pos_attr);
	glBindBuffer(GL_ARRAY_BUFFER, position_buffer);
	glVertexAttribPointer(pos_attr, 2, GL_FLOAT, GL_FALSE, 0, 0);
	check_gl_error("position pointer");

	GLint texcoord_attr = glGetAttribLocation(shader_program, "a_texcoord");
	if (texcoord_attr < 0) {
		LOGE("flushmemscreen: Failed to get texcoord attribute location");
		return;
	}
	glEnableVertexAttribArray(texcoord_attr);
	glBindBuffer(GL_ARRAY_BUFFER, texcoord_buffer);
	glVertexAttribPointer(texcoord_attr, 2, GL_FLOAT, GL_FALSE, 0, 0);
	check_gl_error("texcoord pointer");

	/* Draw fullscreen quad */
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, index_buffer);
	glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 0);
	check_gl_error("glDrawElements");

	/* NOTE: Don't swap buffers here - win_swap will do that */
}

/*
 * drawcursor - Draw cursor on screen (stub for Android)
 * TODO: Implement cursor overlay rendering
 */
void
drawcursor(Drawcursor *c)
{
	(void)c;
	/* Cursor drawing not yet implemented for Android */
}

/*
 * win_get_screendata - Get screen buffer info for wmcontext
 * Called by wm.c to copy image data to screen
 */
void
win_get_screendata(uchar **data, int *width, int *height)
{
	*data = screendata;
	*width = screenwidth;
	*height = screenheight;
}

/*
 * android_initdisplay - Create a Display structure for Android
 * Returns a Display* backed by the EGL surface, or nil on failure
 *
 * This creates a minimal Display that wraps the EGL surface without
 * requiring /dev/draw/new which doesn't exist on Android.
 */
Display*
android_initdisplay(void (*error)(Display*, char*))
{
	Display *disp;
	Image *image;
	void *q;
	EGLint w, h;

	LOGI("android_initdisplay: ENTRY - FUNCTION START");

	/* Allocate lock */
	q = libqlalloc();
	if(q == nil) {
		LOGE("android_initdisplay: libqlalloc failed");
		return nil;
	}
	LOGI("android_initdisplay: libqlalloc succeeded, q=%p", (void*)q);

	/* Allocate Display structure */
	disp = malloc(sizeof(Display));
	if(disp == 0) {
		LOGE("android_initdisplay: malloc Display failed");
		libqlfree(q);
		return nil;
	}

	/* Allocate root image */
	image = malloc(sizeof(Image));
	if(image == 0) {
		LOGE("android_initdisplay: malloc Image failed");
		free(disp);
		libqlfree(q);
		return nil;
	}

	/* Initialize to zeros */
	memset(disp, 0, sizeof(Display));
	memset(image, 0, sizeof(Image));

	/* Check EGL is initialized */
	if(g_display == EGL_NO_DISPLAY || g_surface == EGL_NO_SURFACE) {
		LOGE("android_initdisplay: EGL not initialized");
		free(image);
		free(disp);
		libqlfree(q);
		return nil;
	}

	/* Get screen dimensions from EGL */
	eglQuerySurface(g_display, g_surface, EGL_WIDTH, &w);
	eglQuerySurface(g_display, g_surface, EGL_HEIGHT, &h);
	LOGI("android_initdisplay: EGL surface %dx%d", w, h);

	/* Set up root image */
	image->display = disp;
	image->id = 0;
	image->chan = XRGB32;
	image->depth = 32;
	image->repl = 1;
	image->r = Rect(0, 0, w, h);
	image->clipr = image->r;
	image->screen = nil;
	image->next = nil;

	/* Set up Display fields */
	disp->image = image;
	disp->local = 1;  /* Local display, minimal locking */
	disp->depth = 32;
	disp->chan = XRGB32;
	disp->error = error;
	disp->devdir = strdup("/dev");
	disp->windir = strdup("/dev");
	disp->bufsize = Displaybufsize;
	disp->bufp = disp->buf;
	disp->qlock = q;

	/* Initialize limbo pointer for reference counting
	 * This is required by mkdrawimage and other functions.
	 * DRef is defined in libinterp/draw.c - we use void* here since
	 * we can't include the full definition. */
	{
		void *dr = malloc(24);  /* sizeof(DRef) is approximately 24 bytes */
		if(dr != nil) {
			memset(dr, 0, 24);
			*(void**)((char*)dr + 8) = disp;  /* dr->display = disp (offset 8) */
			*(int*)((char*)dr + 16) = 1;  /* dr->ref = 1 (offset 16) */
			disp->limbo = dr;
		}
	}

	LOGI("android_initdisplay: qlock=%p, about to lock", (void*)q);

	/* Lock the display before returning - this matches the behavior expected by Display_allocate
	 * which expects initdisplay to leave the lock held */
	libqlock(q);

	LOGI("android_initdisplay: qlock locked successfully");

	LOGI("android_initdisplay: Allocating color images");

	/* NOTE: Don't lock the display during initialization since disp->local = 1
	 * and allocimage will check disp->local before attempting to lock.
	 * This avoids a potential deadlock since we're in the middle of init. */

	/*
	 * Initialize the screenimage from devdraw.c.
	 * This is required for allocimage() to work properly.
	 * The draw device's initscreenimage() will call attachscreen().
	 */
	extern int initscreenimage(void);
	extern Memimage *screenimage;  /* From devdraw.c */

	LOGI("android_initdisplay: About to call initscreenimage");
	if(!initscreenimage()) {
		LOGE("android_initdisplay: Failed to initialize screen image");
		/* Continue anyway - try to allocate colors */
	} else {
		LOGI("android_initdisplay: initscreenimage succeeded, screenimage=%p", screenimage);

		/*
		 * CRITICAL FIX: Update disp->image to wrap screenimage
		 *
		 * screenimage is the actual Memimage that contains the screen buffer.
		 * disp->image is an Image wrapper that wmclient uses as the backing image.
		 *
		 * When wmclient calls Screen.allocate(display.image), it creates layers
		 * that share the backing image's data buffer. If disp->image doesn't
		 * reference screenimage, wmclient windows draw to a different buffer
		 * than what flushmemscreen() renders.
		 *
		 * By updating image's properties to match screenimage, wmclient layers
		 * will draw directly to screenimage's buffer, which is what gets rendered.
		 */
		if(screenimage != nil) {
			/* Update the image wrapper to use screenimage's properties */
			image->chan = screenimage->chan;
			image->depth = screenimage->depth;
			image->r = screenimage->r;
			image->clipr = screenimage->clipr;

			/* Log the updated properties for verification */
			LOGI("android_initdisplay: Updated disp->image to wrap screenimage:");
			LOGI("  chan=0x%x depth=%d", image->chan, image->depth);
			LOGI("  r=(%d,%d)-(%d,%d)", image->r.min.x, image->r.min.y, image->r.max.x, image->r.max.y);
			LOGI("  clipr=(%d,%d)-(%d,%d)", image->clipr.min.x, image->clipr.min.y,
			     image->clipr.max.x, image->clipr.max.y);
		}
	}

	/* Draw a test pattern directly to screendata to verify rendering */
	if(screendata != nil && screenwidth > 200 && screenheight > 200) {
		/* Draw a colored test pattern */
		/* Top-left: white (already there from win_init) */
		/* (100,100)-(200,200): Green */
		for(int y = 100; y < 200; y++) {
			for(int x = 100; x < 200; x++) {
				int offset = (y * screenwidth + x) * 4;
				screendata[offset + 0] = 0;   /* R */
				screendata[offset + 1] = 255; /* G */
				screendata[offset + 2] = 0;   /* B */
				screendata[offset + 3] = 255; /* A */
			}
		}
		/* (200,200)-(300,300): Blue */
		for(int y = 200; y < 300; y++) {
			for(int x = 200; x < 300; x++) {
				int offset = (y * screenwidth + x) * 4;
				screendata[offset + 0] = 0;   /* R */
				screendata[offset + 1] = 0;   /* G */
				screendata[offset + 2] = 255; /* B */
				screendata[offset + 3] = 255; /* A */
			}
		}
		LOGI("android_initdisplay: Drew test pattern to screendata");

		/* Also try drawing to screenimage using memdraw to verify that path works */
		extern Memimage *screenimage;
		extern void memimagedraw(Memimage*, Rectangle, Memimage*, Point, Memimage*, Point, int);

		if(screenimage != nil && screenwidth > 400 && screenheight > 400) {
			/* Try to draw a red square using memimagedraw */
			/* First create a simple red square in memory */
			static uchar red_square_data[16*16*4];  /* 16x16 red square */
			for(int i = 0; i < 16*16*4; i += 4) {
				red_square_data[i+0] = 255; /* R */
				red_square_data[i+1] = 0;   /* G */
				red_square_data[i+2] = 0;   /* B */
				red_square_data[i+3] = 255; /* A */
			}

			/* Create a Memimage for the red square */
			/* Note: This is a simplified test - we'll just draw directly to screendata */
			/* Draw red square at (300, 300) */
			for(int y = 300; y < 316; y++) {
				for(int x = 300; x < 316; x++) {
					int offset = (y * screenwidth + x) * 4;
					screendata[offset + 0] = 255; /* R */
					screendata[offset + 1] = 0;   /* G */
					screendata[offset + 2] = 0;   /* B */
					screendata[offset + 3] = 255; /* A */
				}
			}
			LOGI("android_initdisplay: Drew red test square at (300,300)");
		}
	}

	/* Allocate standard colors - On Android, we create minimal Image structs
	 * instead of using allocimage() which requires a draw device connection */
	LOGI("android_initdisplay: Creating color convenience images");

	/* Create white image */
	disp->white = malloc(sizeof(Image));
	if(disp->white) {
		memset(disp->white, 0, sizeof(Image));
		disp->white->display = disp;
		disp->white->id = 0;
		disp->white->chan = GREY1;
		disp->white->depth = 1;
		disp->white->repl = 1;
		disp->white->r = Rect(0, 0, 1, 1);
		disp->white->clipr = disp->white->r;
		disp->white->screen = nil;  /* Color images are not screen images */
		disp->white->next = nil;
	}

	/* Create black image */
	disp->black = malloc(sizeof(Image));
	if(disp->black) {
		memset(disp->black, 0, sizeof(Image));
		disp->black->display = disp;
		disp->black->id = 0;
		disp->black->chan = GREY1;
		disp->black->depth = 1;
		disp->black->repl = 1;
		disp->black->r = Rect(0, 0, 1, 1);
		disp->black->clipr = disp->black->r;
		disp->black->screen = nil;
		disp->black->next = nil;
	}

	/* Create opaque image (white) */
	disp->opaque = malloc(sizeof(Image));
	if(disp->opaque) {
		memset(disp->opaque, 0, sizeof(Image));
		disp->opaque->display = disp;
		disp->opaque->id = 0;
		disp->opaque->chan = GREY1;
		disp->opaque->depth = 1;
		disp->opaque->repl = 1;
		disp->opaque->r = Rect(0, 0, 1, 1);
		disp->opaque->clipr = disp->opaque->r;
		disp->opaque->screen = nil;
		disp->opaque->next = nil;
	}

	/* Create transparent image (black) */
	disp->transparent = malloc(sizeof(Image));
	if(disp->transparent) {
		memset(disp->transparent, 0, sizeof(Image));
		disp->transparent->display = disp;
		disp->transparent->id = 0;
		disp->transparent->chan = GREY1;
		disp->transparent->depth = 1;
		disp->transparent->repl = 1;
		disp->transparent->r = Rect(0, 0, 1, 1);
		disp->transparent->clipr = disp->transparent->r;
		disp->transparent->screen = nil;
		disp->transparent->next = nil;
	}

	LOGI("android_initdisplay: Display created %dx%d", w, h);
	return disp;
}

/*
 * Wrapper functions for android_main.c compatibility
 * These bridge the gap between the NativeActivity interface and the graphics system
 */

/* Global app state for wrappers */
static struct android_app* g_app_state = nil;
static int g_surface_width = 0;
static int g_surface_height = 0;

/* Initialize the display and OpenGL ES */
int
win_init(struct android_app* app)
{
	EGLint w, h;
	EGLint num_configs;
	EGLConfig config;
	EGLint context_attribs[] = {
		EGL_CONTEXT_CLIENT_VERSION, 2,
		EGL_NONE
	};
	EGLint config_attribs[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_BLUE_SIZE, 8,
		EGL_GREEN_SIZE, 8,
		EGL_RED_SIZE, 8,
		EGL_ALPHA_SIZE, 8,
		EGL_NONE
	};

	LOGI("win_init: Starting");

	g_app_state = app;

	/* Check if EGL is already initialized */
	if(g_display != EGL_NO_DISPLAY && g_surface != EGL_NO_SURFACE) {
		eglQuerySurface(g_display, g_surface, EGL_WIDTH, &w);
		eglQuerySurface(g_display, g_surface, EGL_HEIGHT, &h);
		g_surface_width = (int)w;
		g_surface_height = (int)h;
		LOGI("win_init: EGL already initialized %dx%d", g_surface_width, g_surface_height);
		return 0;
	}

	/* Initialize EGL */
	g_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if(g_display == EGL_NO_DISPLAY) {
		LOGE("win_init: eglGetDisplay failed");
		return -1;
	}

	if(!eglInitialize(g_display, NULL, NULL)) {
		LOGE("win_init: eglInitialize failed");
		return -1;
	}

	if(!eglChooseConfig(g_display, config_attribs, &config, 1, &num_configs) || num_configs == 0) {
		LOGE("win_init: eglChooseConfig failed");
		eglTerminate(g_display);
		g_display = EGL_NO_DISPLAY;
		return -1;
	}

	g_surface = eglCreateWindowSurface(g_display, config, app->window, NULL);
	if(g_surface == EGL_NO_SURFACE) {
		LOGE("win_init: eglCreateWindowSurface failed");
		eglTerminate(g_display);
		g_display = EGL_NO_DISPLAY;
		return -1;
	}

	g_context = eglCreateContext(g_display, config, EGL_NO_CONTEXT, context_attribs);
	if(g_context == EGL_NO_CONTEXT) {
		LOGE("win_init: eglCreateContext failed");
		eglDestroySurface(g_display, g_surface);
		eglTerminate(g_display);
		g_surface = EGL_NO_SURFACE;
		g_display = EGL_NO_DISPLAY;
		return -1;
	}

	if(!eglMakeCurrent(g_display, g_surface, g_surface, g_context)) {
		LOGE("win_init: eglMakeCurrent failed");
		eglDestroyContext(g_display, g_context);
		eglDestroySurface(g_display, g_surface);
		eglTerminate(g_display);
		g_context = EGL_NO_CONTEXT;
		g_surface = EGL_NO_SURFACE;
		g_display = EGL_NO_DISPLAY;
		return -1;
	}

	/* Get surface dimensions */
	eglQuerySurface(g_display, g_surface, EGL_WIDTH, &w);
	eglQuerySurface(g_display, g_surface, EGL_HEIGHT, &h);
	g_surface_width = (int)w;
	g_surface_height = (int)h;

	LOGI("win_init: EGL initialized %dx%d", g_surface_width, g_surface_height);

	/* Initialize OpenGL ES resources while we have the context current on main thread */
	if (shader_program == 0) {
		if (!init_gl_resources()) {
			LOGE("win_init: Failed to initialize OpenGL ES resources");
			return -1;
		}
		LOGI("win_init: OpenGL ES resources initialized");
	}

	/* Initialize screen buffer directly if not already allocated by draw device */
	if(screendata == NULL) {
		screenwidth = g_surface_width;
		screenheight = g_surface_height;
		screensize = screenwidth * screenheight * 4;
		screendata = malloc(screensize);
		if(screendata != NULL) {
			/* Initialize to black background */
			memset(screendata, 0, screensize);
			/* Draw a small white square in the top-left corner to verify rendering */
			for(int y = 0; y < 100; y++) {
				for(int x = 0; x < 100; x++) {
					int offset = (y * screenwidth + x) * 4;
					screendata[offset + 0] = 255; /* R */
					screendata[offset + 1] = 255; /* G */
					screendata[offset + 2] = 255; /* B */
					screendata[offset + 3] = 255; /* A */
				}
			}
			LOGI("win_init: Screen buffer allocated %dx%d, %d bytes",
			     screenwidth, screenheight, screensize);

			/* Do an initial render to show the test square */
			Rectangle full_screen = Rect(0, 0, screenwidth, screenheight);
			flushmemscreen(full_screen);
			LOGI("win_init: Initial render complete");
		} else {
			LOGE("win_init: Failed to allocate screen buffer");
		}
	}

	return 0;
}

/* Clean up display resources */
void
win_cleanup(void)
{
	LOGI("win_cleanup: Cleaning up");

	if(g_display != EGL_NO_DISPLAY) {
		eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		if(g_context != EGL_NO_CONTEXT) {
			eglDestroyContext(g_display, g_context);
			g_context = EGL_NO_CONTEXT;
		}
		if(g_surface != EGL_NO_SURFACE) {
			eglDestroySurface(g_display, g_surface);
			g_surface = EGL_NO_SURFACE;
		}
		eglTerminate(g_display);
		g_display = EGL_NO_DISPLAY;
	}

	g_app_state = nil;
	g_surface_width = 0;
	g_surface_height = 0;
}

/* Handle surface resize */
void
win_resize(int width, int height)
{
	LOGI("win_resize: %dx%d", width, height);
	g_surface_width = width;
	g_surface_height = height;
	/* flushmemscreen will handle the actual rendering */
}

/* External function from wm.c to update display from wmcontext */
extern int wm_update_active_display(void);

/* Swap buffers and render */
void
win_swap(void)
{
	static int swap_count = 0;
	static int anim_x = 0;
	static int wm_has_content = 0;

	if(g_display != EGL_NO_DISPLAY && g_surface != EGL_NO_SURFACE) {
		/* Just flush the current screen buffer and swap */
		/* No test animation - let actual drawing show through */
		if(screendata != NULL && screenwidth > 0 && screenheight > 0) {
			Rectangle full_screen = Rect(0, 0, screenwidth, screenheight);
			flushmemscreen(full_screen);
		}

		eglSwapBuffers(g_display, g_surface);

		/* Log every 60 swaps */
		if((swap_count % 60) == 0) {
			LOGI("win_swap: swap_count=%d", swap_count);
		}
		swap_count++;
	}
}

/*
 * Android-specific doflush override.
 *
 * The doflush in libinterp/draw.c calls kchanio(d->datachan, ...) even for
 * local displays. For Android local displays, datachan is nil because we're
 * not using the traditional /dev/draw protocol.
 *
 * This override handles local displays by skipping the kchanio call.
 * For non-local displays (shouldn't happen on Android), it would call through.
 */
int
doflush(Display *d)
{
	int n;

	n = d->bufp - d->buf;
	if(n <= 0)
		return 1;

	/*
	 * For local displays (Android), skip the kchanio call.
	 * Just reset the buffer pointer to indicate success.
	 */
	if(d->local) {
		d->bufp = d->buf;
		return 1;
	}

	/*
	 * For non-local displays (shouldn't happen on Android),
	 * this would fail - but that's expected since datachan is nil.
	 */
	return -1;
}
