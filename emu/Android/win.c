/*
 * Android window/graphics implementation for TaijiOS
 * Uses OpenGL ES for rendering
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "keyboard.h"

#include <android/log.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#define LOG_TAG "TaijiOS-Win"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Screen dimensions */
static int screenwidth = 0;
static int screenheight = 0;

/* Screen data - RGBA format for OpenGL ES */
static uchar *screendata = nil;
static int screensize = 0;

/* OpenGL ES objects */
static GLuint screenTexture = 0;
static GLuint shaderProgram = 0;
static GLuint vertexBuffer = 0;
static GLuint indexBuffer = 0;

/* External references from android_test.c */
extern EGLDisplay g_display;
extern EGLSurface g_surface;
extern EGLContext g_context;

/* Simple vertex shader */
static const char vertexShaderSrc[] =
	"attribute vec4 aPosition;\n"
	"attribute vec2 aTexCoord;\n"
	"varying vec2 vTexCoord;\n"
	"void main() {\n"
	"	gl_Position = aPosition;\n"
	"	vTexCoord = aTexCoord;\n"
	"}\n";

/* Simple fragment shader */
static const char fragmentShaderSrc[] =
	"precision mediump float;\n"
	"varying vec2 vTexCoord;\n"
	"uniform sampler2D uTexture;\n"
	"void main() {\n"
	"	gl_FragColor = texture2D(uTexture, vTexCoord);\n"
	"}\n";

/* Vertex data for fullscreen quad */
static const float vertices[] = {
	/* Position (x, y) */  /* TexCoord (u, v) */
	-1.0f,  1.0f,          0.0f, 0.0f,
	-1.0f, -1.0f,          0.0f, 1.0f,
	 1.0f, -1.0f,          1.0f, 1.0f,
	 1.0f,  1.0f,          1.0f, 0.0f,
};

static const unsigned short indices[] = {
	0, 1, 2,
	0, 2, 3,
};

/* Shader compilation helper */
static GLuint compileShader(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	if (shader == 0) {
		LOGE("glCreateShader failed");
		return 0;
	}

	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);

	GLint compiled;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
	if (!compiled) {
		GLint infoLen = 0;
		glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &infoLen);
		if (infoLen > 1) {
			char* infoLog = malloc(infoLen);
			glGetShaderInfoLog(shader, infoLen, NULL, infoLog);
			LOGE("Shader compile error: %s", infoLog);
			free(infoLog);
		}
		glDeleteShader(shader);
		return 0;
	}

	return shader;
}

/* Initialize OpenGL ES resources for rendering */
static int initGLEResources(void)
{
	GLuint vertexShader, fragmentShader;
	GLint linked;

	/* Compile shaders */
	vertexShader = compileShader(GL_VERTEX_SHADER, vertexShaderSrc);
	if (vertexShader == 0)
		return -1;

	fragmentShader = compileShader(GL_FRAGMENT_SHADER, fragmentShaderSrc);
	if (fragmentShader == 0) {
		glDeleteShader(vertexShader);
		return -1;
	}

	/* Link program */
	shaderProgram = glCreateProgram();
	if (shaderProgram == 0) {
		glDeleteShader(vertexShader);
		glDeleteShader(fragmentShader);
		return -1;
	}

	glAttachShader(shaderProgram, vertexShader);
	glAttachShader(shaderProgram, fragmentShader);
	glLinkProgram(shaderProgram);

	glGetProgramiv(shaderProgram, GL_LINK_STATUS, &linked);
	if (!linked) {
		GLint infoLen = 0;
		glGetProgramiv(shaderProgram, GL_INFO_LOG_LENGTH, &infoLen);
		if (infoLen > 1) {
			char* infoLog = malloc(infoLen);
			glGetProgramInfoLog(shaderProgram, infoLen, NULL, infoLog);
			LOGE("Program link error: %s", infoLog);
			free(infoLog);
		}
		glDeleteProgram(shaderProgram);
		glDeleteShader(vertexShader);
		glDeleteShader(fragmentShader);
		return -1;
	}

	glDeleteShader(vertexShader);
	glDeleteShader(fragmentShader);

	/* Create vertex buffer */
	glGenBuffers(1, &vertexBuffer);
	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

	/* Create index buffer */
	glGenBuffers(1, &indexBuffer);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexBuffer);
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

	/* Create texture */
	glGenTextures(1, &screenTexture);
	glBindTexture(GL_TEXTURE_2D, screenTexture);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

	LOGI("OpenGL ES resources initialized");
	return 0;
}

/*
 * attachscreen - Create the screen buffer
 * Called by devdraw.c to initialize the screen
 * Returns pointer to screen data, or nil on failure
 */
Memdata*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	static Memdata screendata_struct;

	/* Get screen dimensions from current surface */
	EGLint w, h;

	if (g_display == EGL_NO_DISPLAY || g_surface == EGL_NO_SURFACE) {
		LOGE("attachscreen: EGL not initialized");
		return nil;
	}

	eglQuerySurface(g_display, g_surface, EGL_WIDTH, &w);
	eglQuerySurface(g_display, g_surface, EGL_HEIGHT, &h);

	screenwidth = w;
	screenheight = h;

	LOGI("attachscreen: %dx%d", screenwidth, screenheight);

	/* Set up rectangle */
	r->min.x = 0;
	r->min.y = 0;
	r->max.x = screenwidth;
	r->max.y = screenheight;

	/* RGBA format */
	*chan = XRGB32;
	*d = 32;
	*width = screenwidth * 4;
	*softscreen = 0;

	/* Allocate screen buffer (RGBA) */
	screensize = screenwidth * screenheight * 4;
	if (screendata == nil) {
		screendata = malloc(screensize);
		if (screendata == nil) {
			LOGE("attachscreen: malloc failed for %d bytes", screensize);
			return nil;
		}
	}

	/* Initialize to black */
	memset(screendata, 0, screensize);

	/* Set up Memdata structure */
	screendata_struct.base = nil;  /* No base, will be freed manually */
	screendata_struct.bdata = screendata;
	screendata_struct.ref = 1;

	/* Initialize OpenGL ES resources */
	if (shaderProgram == 0) {
		initGLEResources();
	}

	/* Make GL context current */
	eglMakeCurrent(g_display, g_surface, g_surface, g_context);

	return &screendata_struct;
}

/*
 * flushmemscreen - Flush screen rectangle to display
 * Called by devdraw.c when screen content changes
 */
void
flushmemscreen(Rectangle r)
{
	if (screendata == nil || screenTexture == 0)
		return;

	/* Make GL context current */
	eglMakeCurrent(g_display, g_surface, g_surface, g_context);

	/* Update texture from screen data */
	glBindTexture(GL_TEXTURE_2D, screenTexture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, screenwidth, screenheight,
	             0, GL_RGBA, GL_UNSIGNED_BYTE, screendata);

	/* Use shader program */
	glUseProgram(shaderProgram);

	/* Set up vertex attributes */
	GLint posAttr = glGetAttribLocation(shaderProgram, "aPosition");
	GLint texAttr = glGetAttribLocation(shaderProgram, "aTexCoord");
	GLint texUniform = glGetUniformLocation(shaderProgram, "uTexture");

	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
	glEnableVertexAttribArray(posAttr);
	glVertexAttribPointer(posAttr, 2, GL_FLOAT, GL_FALSE, 16, (void*)0);
	glEnableVertexAttribArray(texAttr);
	glVertexAttribPointer(texAttr, 2, GL_FLOAT, GL_FALSE, 16, (void*)8);

	/* Set texture uniform */
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, screenTexture);
	glUniform1i(texUniform, 0);

	/* Draw quad */
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexBuffer);
	glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 0);

	/* Swap buffers */
	eglSwapBuffers(g_display, g_surface);
}

/*
 * setcursor - Set mouse cursor (stub for Android)
 */
void
setcursor(Cursor *c)
{
	USED(c);
	/* TODO: Implement cursor rendering if needed */
}

/*
 * getcursor - Get mouse cursor (stub for Android)
 */
void
getcursor(Cursor *c)
{
	USED(c);
	/* TODO: Implement cursor rendering if needed */
}

/*
 * drawcursor - Draw cursor on screen (stub for Android)
 */
void
drawcursor(DrawCursor *c)
{
	USED(c);
	/* TODO: Implement cursor rendering if needed */
}
