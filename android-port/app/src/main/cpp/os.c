/*
 * Android OS abstraction layer for TaijiOS
 * Ported from emu/Linux/os.c with Android-specific adaptations
 */

#include <sys/types.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>
#include <sched.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <pthread.h>
#include <semaphore.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <math.h>
#include <dirent.h>

#include <stdint.h>
#include <android/log.h>

#include "dat.h"
#include "fns.h"
#include "error.h"
#include <raise.h>
#include <interp.h>
#include <isa.h>
#include <kernel.h>
#include <draw.h>
#include "../libinterp/runt.h"

/* Forward declarations */
typedef struct Memimage Memimage;
typedef struct Rendez Rendez;
typedef struct Pool Pool;
typedef struct Chan Chan;
typedef struct Block Block;
typedef struct DESstate DESstate;
typedef struct RC4state RC4state;
typedef struct IDEAstate IDEAstate;
typedef struct AESstate AESstate;
typedef struct BFstate BFstate;
typedef struct Fd Fd;
typedef struct Fgrp Fgrp;
typedef struct Pgrp Pgrp;
typedef struct Egrp Egrp;
typedef struct Sigs Sigs;
typedef struct Skeyset Skeyset;
typedef struct DigestState DigestState;
typedef struct Procs Procs;
typedef struct mpint mpint;

#define LOG_TAG "TaijiOS"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* fdchk - convert Sys_FD* to int fd number */
#define fdchk(x)    ((x) == (Sys_FD*)H ? -1 : (x)->fd)

extern char exNilref[];

enum
{
	DELETE	= 0x7f,
	CTRLC	= 'C'-'@',
	NSTACKSPERALLOC = 16,
	GLESSTACK= 256*1024
};

char *hosttype = "Android";

typedef struct {
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	int count;
} Sem;

extern int dflag;

int	gidnobody = -1;
int	uidnobody = -1;

/*
 * Android doesn't have the same signal handling as Linux
 * We use pthread primitives for synchronization
 */

static void
sysfault(char *what, void *addr)
{
	char buf[64];

	snprint(buf, sizeof(buf), "sys: %s%#p", what, addr);
	disfault(nil, buf);
}

static void
trapILL(int signo, siginfo_t *si, void *a)
{
	USED(signo);
	USED(a);
	sysfault("illegal instruction pc=", si->si_addr);
}

static int
isnilref(siginfo_t *si)
{
	return si != 0 && (si->si_addr == (void*)~(uintptr_t)0 || (uintptr_t)si->si_addr < 512);
}

static void
trapmemref(int signo, siginfo_t *si, void *a)
{
	USED(a);
	if(isnilref(si))
		disfault(nil, exNilref);
	else if(signo == SIGBUS)
		sysfault("bad address addr=", si->si_addr);
	else
		sysfault("segmentation violation addr=", si->si_addr);
}

static void
trapFPE(int signo, siginfo_t *si, void *a)
{
	char buf[64];

	USED(signo);
	USED(a);
	snprint(buf, sizeof(buf), "sys: fp: exception addr=%#p", si->si_addr);
	disfault(nil, buf);
}

/*
 * Android uses pthreads, so we use pthread condition for signaling
 */
static void
trapUSR1(int signo)
{
	int intwait;

	USED(signo);

	intwait = up->intwait;
	up->intwait = 0;

	if(up->type != Interp)
		return;

	if(intwait == 0)
		disfault(nil, Eintr);
}

void
oslongjmp(void *regs, osjmpbuf env, int val)
{
	USED(regs);
	siglongjmp(env, val);
}

void
cleanexit(int x)
{
	USED(x);

	if(up->intwait) {
		up->intwait = 0;
		return;
	}

	_exit(0);
}

void
osreboot(char *file, char **argv)
{
	execvp(file, argv);
	error("reboot failure");
}

/* Note: libinit and emuinit are defined below (Android-specific versions) */

/* Forward declarations - module initialization only for now */
extern void modinit(void);
extern void opinit(void);
extern void excinit(void);

/* External functions from libinterp for loading and executing Dis bytecode */
extern Module* parsemod(char *path, uchar *code, u32 length, Dir *dir);
extern Modlink* mklinkmod(Module *m, int n);
extern Prog* newprog(Prog *p, Modlink *m);
extern void addrun(Prog *p);

/* External function from android_test.c for loading assets */
extern uchar* load_dis_from_assets(const char* path, int* size_out);

/* External function from libinterp for scheduling Dis modules */
extern Prog* schedmod(Module*);

/* External functions for environment group initialization */
extern Pgrp* newpgrp(void);
extern Fgrp* newfgrp(Fgrp*);
extern Egrp* newegrp(void);

/* Reference to isched structure from emu/port/dis.c */
extern struct {
	Lock	l;
	Prog*	runhd;
	Prog*	runtl;
	Prog*	head;
	Prog*	tail;
	Rendez	irend;
	int	idle;
	int	nyield;
	int	creating;
	Proc*	vmq;
	Proc*	vmqt;
	Proc*	idlevmq;
	Atidle*	idletasks;
} isched;

/*
 * Create a minimal Dir structure for in-memory module loading
 * This bypasses the file system when loading Dis bytecode from assets
 */
Dir*
fake_dir_for_module(const char* name, u32 size, u32 mtime)
{
	Dir* d = mallocz(sizeof(Dir), 1);
	if (!d) {
		LOGE("fake_dir_for_module: mallocz failed");
		return NULL;
	}

	d->type = 0;        /* Regular file */
	d->dev = 0x819248;  /* Fake device number */
	d->mode = 0444;     /* Read-only */
	d->atime = mtime;
	d->mtime = mtime;
	d->length = size;
	d->name = strdup(name);
	d->qid.type = 0;
	d->qid.path = (uvlong)size;  /* Simple hash */
	d->qid.vers = 0;
	d->uid = NULL;
	d->gid = NULL;
	d->muid = NULL;

	return d;
}

/*
 * Load Dis bytecode from memory and return the Prog*
 * The caller must complete initialization following disinit() pattern
 */
Prog*
load_and_run_dis_module_from_memory(const char* name, uchar* code, int size)
{
	LOGI("load_and_run_dis_module: %s, %d bytes", name, size);

	if (!code || size <= 0) {
		LOGE("load_and_run_dis_module: Invalid code or size");
		return NULL;
	}

	/* Create fake Dir structure */
	Dir* d = fake_dir_for_module(name, (u32)size, (u32)time(NULL));
	if (!d) {
		LOGE("load_and_run_dis_module: fake_dir_for_module failed");
		return NULL;
	}

	/* Parse Dis bytecode from memory */
	Module* m = parsemod((char*)name, code, (u32)size, d);
	free(d->name);
	free(d);
	if (!m) {
		LOGE("load_and_run_dis_module: parsemod failed for %s", name);
		return NULL;
	}

	LOGI("load_and_run_dis_module: Module parsed, nprog=%d", m->nprog);

	/* Use schedmod() to properly schedule the module for execution */
	/* schedmod() handles all the proper initialization: Modlink, Prog, PC, stack, etc */
	/* NOTE: newprog() (called by schedmod) already calls addrun(), so we don't need to */
	Prog* p = schedmod(m);
	if (!p) {
		LOGE("load_and_run_dis_module: schedmod failed");
		return NULL;
	}

	LOGI("load_and_run_dis_module: Process created (already in run queue), pid=%d", p->pid);
	return p;
}

/* Global pointer to the loaded Dis program - accessed by libinit() for osenv initialization
 * IMPORTANT: This must be initialized BEFORE spawning vmachine, otherwise
 * vmachine will try to execute programs before their environment is ready.
 */
static Prog* loaded_prog = NULL;

/* Emulator initialization - initializes the Dis VM modules */
void
emuinit(void *imod)
{
	USED(imod);
	LOGI("emuinit: ENTRY - TaijiOS emulator starting");

	/* Initialize operators for Dis VM */
	opinit();
	excinit();

	/* Initialize all modules */
	modinit();

	LOGI("emuinit: Module initialization complete");

	/* Load and run a simple Dis module from assets */
	/* Try clock first - user requested to test it */
	static const char* test_modules[] = {
		"dis/clock.dis",       /* Clock application - user requested */
		"dis/testsimple.dis",  /* Has Sys_print calls that log to Android */
		"dis/testload.dis",    /* Minimal Draw module test */
		"dis/minimal.dis",     /* GUI test with button */
		"dis/testprint.dis",
		"dis/testnobox.dis",
		"dis/testsleep.dis",
		"dis/testwm.dis",
		"dis/hello.dis",
		NULL
	};

	loaded_prog = NULL;
	LOGI("emuinit: About to load Dis modules");
	for (int i = 0; test_modules[i] != NULL && !loaded_prog; i++) {
		int size;
		uchar* code = load_dis_from_assets(test_modules[i], &size);
		if (code) {
			LOGI("emuinit: Loading %s from assets", test_modules[i]);
			loaded_prog = load_and_run_dis_module_from_memory(test_modules[i], code, size);
			if (loaded_prog) {
				LOGI("emuinit: Successfully loaded %s", test_modules[i]);
			} else {
				LOGE("emuinit: Failed to run %s", test_modules[i]);
			}
			/* Don't free code - parsemod may keep references to it */
		} else {
			LOGI("emuinit: Could not load %s from assets (file may not exist)", test_modules[i]);
		}
	}

	if (loaded_prog) {
		Osenv *o;

		LOGI("emuinit: Initializing environment groups for pid=%d", loaded_prog->pid);
		/* Initialize the process Osenv for the first Dis process */
		/* This follows the pattern from emu/port/main.c:281-285 */
		o = loaded_prog->osenv;

		/* Initialize environment groups - required for proper process cleanup */
		o->pgrp = newpgrp();
		o->fgrp = newfgrp(nil);
		o->egrp = newegrp();

		/* Set up error buffers */
		o->errstr = o->errbuf0;
		o->syserrstr = o->errbuf1;

		/* Set user to empty string like main.c does */
		o->user = strdup("");
		if (o->user == nil) {
			LOGE("emuinit: strdup failed for user");
		}

		LOGI("emuinit: Process initialization complete for pid=%d", loaded_prog->pid);
	} else {
		LOGI("emuinit: No Dis module loaded - this is expected if assets are not bundled yet");
	}

	/* Set idle flag so startup() doesn't block */
	/* See emu/port/dis.c:915-933 - startup() checks isched.idle */
	LOGI("emuinit: Setting isched.idle = 1");
	isched.idle = 1;
	LOGI("emuinit: Set isched.idle = 1, isched.head=%p, isched.runhd=%p",
	     isched.head, isched.runhd);
	if (loaded_prog) {
		LOGI("emuinit: Process pid=%d state=%d", loaded_prog->pid, loaded_prog->state);
		Osenv *o = (Osenv*)loaded_prog->osenv;
		void *pgrp_ptr = o ? o->pgrp : NULL;
		LOGI("emuinit: loaded_prog=%p, pid=%d, state=%d, osenv->pgrp=%p",
		     loaded_prog, loaded_prog->pid, loaded_prog->state, pgrp_ptr);
	}
	LOGI("emuinit: Returning to libinit");
}

/*
 * Android: use ADB or logcat for keyboard input
 */
int
readkbd(void)
{
	int n;
	char buf[1];

	n = read(0, buf, sizeof(buf));
	if(n < 0)
		print("keyboard close (n=%d, %s)\n", n, strerror(errno));
	if(n <= 0)
		pexit("keyboard thread", 0);

	switch(buf[0]) {
	case '\r':
		buf[0] = '\n';
		break;
	case DELETE:
		buf[0] = 'H' - '@';
		break;
	case CTRLC:
		cleanexit(0);
		break;
	}
	return buf[0];
}

/*
 * Fast tick counter for Android
 * Uses clock_gettime with CLOCK_MONOTONIC for high resolution
 */
static uvlong fasthz = 0;

uvlong
osfastticks(void)
{
	struct timespec ts;

	if(fasthz == 0) {
		/* Calibrate the clock frequency */
		clock_gettime(CLOCK_MONOTONIC, &ts);
		fasthz = 1000000000;	/* nanoseconds per second */
	}
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uvlong)ts.tv_sec * fasthz + ts.tv_nsec;
}

uvlong
osfastticks2ns(uvlong ticks)
{
	if(fasthz == 0)
		return ticks;
	return ticks * 1000000000 / fasthz;
}

/*
 * Return an arbitrary millisecond clock time
 */
long
osmillisec(void)
{
	static long sec0 = 0, usec0;
	struct timeval t;

	if(gettimeofday(&t, (struct timezone*)0) < 0)
		return 0;

	if(sec0 == 0) {
		sec0 = t.tv_sec;
		usec0 = t.tv_usec;
	}
	return (t.tv_sec - sec0)*1000 + (t.tv_usec - usec0 + 500)/1000;
}

/*
 * Return the time since the epoch in nanoseconds and microseconds
 */
vlong
osnsec(void)
{
	struct timeval t;

	gettimeofday(&t, nil);
	return (vlong)t.tv_sec*1000000000L + t.tv_usec*1000;
}

vlong
osusectime(void)
{
	struct timeval t;

	gettimeofday(&t, nil);
	return (vlong)t.tv_sec * 1000000 + t.tv_usec;
}

int
osmillisleep(ulong milsec)
{
	struct timespec time;

	time.tv_sec = milsec/1000;
	time.tv_nsec = (milsec%1000)*1000000;
	nanosleep(&time, NULL);
	return 0;
}

int
limbosleep(ulong milsec)
{
	return osmillisleep(milsec);
}

/*
 * Android: OS-specific enter/leave for critical sections
 * osenter and osleave are implemented in emu/port/proc.c
 */

/*
 * Semaphore operations using pthread
 */
void
ossemacquire(Sem *s)
{
	pthread_mutex_lock(&s->mutex);
	while(s->count <= 0)
		pthread_cond_wait(&s->cond, &s->mutex);
	s->count--;
	pthread_mutex_unlock(&s->mutex);
}

void
ossemrelease(Sem *s, int count)
{
	pthread_mutex_lock(&s->mutex);
	s->count += count;
	pthread_cond_broadcast(&s->cond);
	pthread_mutex_unlock(&s->mutex);
}

/*
 * Error handling
 */
void
oserror(void)
{
	oserrstr(up->env->errstr, ERRMAX);
	error(up->env->errstr);
}

void
oserrstr(char *buf, uint n)
{
	char *s;

	s = strerror(errno);
	strncpy(buf, s, n);
	buf[n-1] = 0;
}

/*
 * Command execution for Android
 */
void*
oscmd(char **argv, int nice, char *dir, int *pid)
{
	USED(dir);
	USED(nice);
	/* TODO: Implement for Android */
	return nil;
}

int
oscmdwait(void *cmd, char *buf, int n)
{
	USED(cmd);
	USED(buf);
	USED(n);
	return -1;
}

int
oscmdkill(void *cmd)
{
	USED(cmd);
	return -1;
}

void
oscmdfree(void *cmd)
{
	USED(cmd);
}

/*
 * Stub implementations for missing symbols
 */
char** rebootargv = nil;

/* poolread is defined in emu/port/alloc.c */

/* cflag is in emu/port/dis.c */

/* keepbroken is in emu/port/dis.c */
char* exdebug = nil;

/* vflag - verbose debug flag, set to 0 for Android (no command line) */
int vflag = 0;

/* setid is in emu/port/devfs-posix.c */

void
memldelete(Memimage *m)
{
	USED(m);
}

void
memlfree(Memimage *m)
{
	USED(m);
}

/* attachscreen is in emu/Android/win.c */

/* Sleep and Wakeup are implemented in emu/port/proc.c */

int
memlnorefresh(Memimage *m)
{
	USED(m);
	return 0;
}

int
memlinealloc(int w, int h, int fill)
{
	USED(w);
	USED(h);
	USED(fill);
	return 0;
}

Point
memlorigin(Memimage *m)
{
	USED(m);
	Point p = {0, 0};
	return p;
}

int
memunload(Memimage *m, Rectangle r, uchar *data, int n)
{
	USED(m);
	(void)r;
	USED(data);
	return n;
}

void
memdraw(Memimage *dst, Rectangle r, Memimage *src, Point p0, int op)
{
	USED(dst);
	(void)r;
	USED(src);
	(void)p0;
	USED(op);
}

Memimage*
memlalloc(int w, int h, int fill)
{
	USED(w);
	USED(h);
	USED(fill);
	return nil;
}

void
memlsetrefresh(Memimage *m, void (*refresh)(Memimage*, Rectangle), Rectangle r)
{
	USED(m);
	USED(refresh);
	(void)r;
}

int
memline(Memimage *dst, Point p0, Point p1, int end0, int end1, int radius, Memimage *src, Point sp, int op, int zop, int clip)
{
	USED(dst);
	(void)p0;
	(void)p1;
	USED(end0);
	USED(end1);
	USED(radius);
	USED(src);
	(void)sp;
	USED(op);
	USED(zop);
	USED(clip);
	return 0;
}

void
memltofrontn(Memimage **mip, int n)
{
	USED(mip);
	USED(n);
}

void
memltorearn(Memimage **mip, int n)
{
	USED(mip);
	USED(n);
}

int
memload(Memimage *m, Rectangle r, uchar *data, int n)
{
	USED(m);
	(void)r;
	USED(data);
	return n;
}

/* flushmemscreen is in emu/Android/win.c */

void
exhausted(char *s)
{
	USED(s);
}

void
validstat(uchar *d, int n)
{
	USED(d);
	USED(n);
}

/* acquire and release are in emu/port/proc.c */

/* Root device table - defined in emu-g.root.h */
/* Process monitoring */
/* memmonitor is defined as a function pointer in emu/port/alloc.c */

/* progpid() function is in emu/port/dis.c */

/* pc2dispc is in emu/port/devprog.c with different signature (Inst*, Module*) */

/* poolmsize is defined in emu/port/alloc.c */

/* Runtime functions (acquire, release, delruntail, addrun) are in emu/port/proc.c */

/* Channel operations - stub */
void
csend(Channel *c, void *v)
{
	USED(c);
	USED(v);
}

void
crecv(Channel *c, void *v)
{
	USED(c);
	USED(v);
}

/* DES encryption - stub */
void
setupDESstate(DESstate *s, uchar *key, int nkey)
{
	USED(s);
	USED(key);
	USED(nkey);
}

/* Base64 encoding - stub */
int
enc64(char *out, int len, uchar *in, int n)
{
	USED(out);
	USED(len);
	USED(in);
	USED(n);
	return 0;
}

int
dec64(uchar *out, int len, char *in, int n)
{
	USED(out);
	USED(len);
	USED(in);
	USED(n);
	return 0;
}

/* More crypto functions - stub */
void
setupRC4state(RC4state *s, uchar *key, int nkey)
{
	USED(s);
	USED(key);
	USED(nkey);
}

void
setupIDEAstate(IDEAstate *s, uchar *key, int nkey)
{
	USED(s);
	USED(key);
	USED(nkey);
}

int
block_cipher(uchar *p, int len)
{
	USED(p);
	USED(len);
	return 0;
}

void
des_ecb_cipher(uchar *in, uchar *out, int len)
{
	USED(in);
	USED(out);
	USED(len);
}

void
des_cipher(uchar *in, uchar *out, int len)
{
	USED(in);
	USED(out);
	USED(len);
}

void
idea_cipher(uchar *in, uchar *out, int len)
{
	USED(in);
	USED(out);
	USED(len);
}

void
rc4(RC4state *s, uchar *in, uchar *out, int len)
{
	USED(s);
	USED(in);
	USED(out);
	USED(len);
}

Chan*
fdtochan(Fgrp *f, int fd, int mode, int is_dup, int head)
{
	USED(f);
	USED(fd);
	USED(mode);
	USED(is_dup);
	USED(head);
	return nil;
}

/* SHA1 hash - stub */
DigestState*
sha1(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

DigestState*
md5(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

/* closefgrp, closepgrp, closeegrp are in emu/port/pgrp.c */

DigestState*
md4(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

/* Process list - global variable */
Procs procs;

/* closesigs is in emu/port/proc.c */

/* Root device - rootmaxq defined in emu-g.root.h */
/* Note: imagmem (Pool*) is defined in alloc.c, not Memimage* */

/* newproc is implemented in emu/port/proc.c */

/* Android pthread compatibility */
int
pthread_attr_setinheritsched(pthread_attr_t *attr, int inheritsched)
{
	USED(attr);
	USED(inheritsched);
	return 0;
}

void
pthread_yield(void)
{
	sched_yield();
}

/* Rune utility functions */
int
runevsnprint(Rune *str, int n, char *fmt, va_list args)
{
	USED(str);
	USED(n);
	USED(fmt);
	(void)args;
	return 0;
}

int
runevsmprint(Rune *str, char *fmt, va_list args)
{
	USED(str);
	USED(fmt);
	(void)args;
	return 0;
}

/* Atomic test-and-set for lock implementation */
int
_tas(int *addr)
{
	return __sync_lock_test_and_set(addr, 1);
}

/* Signal flag */
int sflag = 0;

/* disfault is in emu/port/dis.c */

/* Rune binary search */
Rune*
_runebsearch(Rune c, Rune *tab, int n)
{
	USED(c);
	USED(tab);
	USED(n);
	return nil;
}

/* vfprint - vfprintf to file descriptor */
int
vfprint(int fd, char *fmt, va_list args)
{
	USED(fd);
	USED(fmt);
	(void)args;
	return 0;
}

/* NaN constant for floating point */
double NaN = 0.0 / 0.0;

/* Program name global variable */
char *argv0 = "taijos";

/* Draw logging */
void
drawlog(char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	USED(fmt);
	va_end(args);
}

/* _fmtlock, _fmtunlock provided by emu/port/print.c */

/* print function - was in lib9/print.c */
int
print(char *fmt, ...)
{
	int n;
	va_list args;

	va_start(args, fmt);
	n = vfprint(1, fmt, args);
	va_end(args);
	return n;
}

/* isNaN function for math library */
int
isNaN(double d)
{
	return d != d; /* NaN != NaN is true */
}

/* isInf function for math library */
int
isInf(double d)
{
	return (d == __builtin_inf() || d == -__builtin_inf());
}

/* Error string functions */
static char errbuf[128] = "no error";

int
errstr(char *buf, uint len)
{
	if (buf != nil && len > 0) {
		strncpy(buf, errbuf, len - 1);
		buf[len - 1] = '\0';
	}
	return strlen(errbuf);
}

void
werrstr(char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	vsnprintf(errbuf, sizeof(errbuf), fmt, args);
	va_end(args);
}

/* _fmtFdFlush - format fd flush */
void
_fmtFdFlush(Fmt *f)
{
	USED(f);
}

/* AES encryption - stub */
void
aesCBCencrypt(uchar *data, int len, uchar *key, int keylen, uchar *iv)
{
	USED(data);
	USED(len);
	USED(key);
	USED(keylen);
	USED(iv);
}

void
setupAESstate(AESstate *s, uchar *key, int keylen, uchar *iv)
{
	USED(s);
	USED(key);
	USED(keylen);
	USED(iv);
}

/* Blowfish state setup - stub */
void
setupBFstate(BFstate *s, uchar *key, int keylen)
{
	USED(s);
	USED(key);
	USED(keylen);
}

/* Multi-precision integer stub */
mpint*
mpnew(int n)
{
	USED(n);
	return nil;
}

/* DSA primes - stub */
mpint *DSAprimes[1] = {nil};

/* delrun is in emu/port/dis.c */

/* bflag - debug flag */
int bflag = 0;

/* gensafeprime - generate safe prime */
mpint*
gensafeprime(mpint *p, int n)
{
	USED(p);
	USED(n);
	return nil;
}

/* MP signature - stub */
int
mpsignif(mpint *m, mpint *n, mpint *key, mpint *sig)
{
	USED(m);
	USED(n);
	USED(key);
	USED(sig);
	return 0;
}

/* HMAC functions - stub */
DigestState*
hmac_md5(uchar *data, ulong dlen, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(key);
	USED(klen);
	USED(digest);
	USED(s);
	return nil;
}

DigestState*
hmac_sha1(uchar *data, ulong dlen, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(key);
	USED(klen);
	USED(digest);
	USED(s);
	return nil;
}

/* RSA decrypt - stub */
mpint*
rsadecrypt(mpint *cipher, mpint *modulus, mpint *exponent)
{
	USED(cipher);
	USED(modulus);
	USED(exponent);
	return nil;
}

/* RSA encrypt - stub */
mpint*
rsaencrypt(mpint *plain, mpint *modulus, mpint *exponent)
{
	USED(plain);
	USED(modulus);
	USED(exponent);
	return nil;
}

/* RSA fill - stub */
void
rsafill(mpint *m, mpint *n, mpint *e)
{
	USED(m);
	USED(n);
	USED(e);
}

/* RC4 skip - stub */
void
rc4skip(RC4state *s, ulong n)
{
	USED(s);
	USED(n);
}

void
aesCBCdecrypt(uchar *data, int len, uchar *key, int keylen, uchar *iv)
{
	USED(data);
	USED(len);
	USED(key);
	USED(keylen);
	USED(iv);
}

/* Blowfish encryption - stub */
void
bfCBCencrypt(uchar *data, int len, uchar *key, int keylen, uchar *iv)
{
	USED(data);
	USED(len);
	USED(key);
	USED(keylen);
	USED(iv);
}

void
bfCBCdecrypt(uchar *data, int len, uchar *key, int keylen, uchar *iv)
{
	USED(data);
	USED(len);
	USED(key);
	USED(keylen);
	USED(iv);
}

/*
 * Additional runtime functions needed by the emu layer
 */

/* Forward declarations */
typedef struct Mount Mount;
typedef struct Mhead Mhead;

/* Panic handling - for stack traces during crashes */
char* panstr = nil;
void** panics = nil;
int npanics = 0;

/* smalloc is defined in emu/port/alloc.c */

/* Jump buffer display for debugging */
void
showjmpbuf(char *msg)
{
	USED(msg);
}

/* newmount and mountfree are in emu/port/pgrp.c */

/* Kernel date/time - defined in emu-g.c */
/* User name for the system */
char *eve = "android";

/* Open mode conversion - convert Inferno open mode to Unix mode */
int
openmode(ulong s)
{
	switch(s & 3) {
	case OREAD:
		return 0;
	case OWRITE:
		return 1;
	case ORDWR:
		return 2;
	case OEXEC:
		return 0;
	default:
		return 0;
	}
}

/* Latin1 character handling - converts UTF-8 to Latin1 */
long
latin1(uchar *p, int n)
{
	USED(p);
	USED(n);
	return 0;
}

/* Keyboard scan ID for console */
int gkscanid = 0;

/* emuinit is defined below with correct signature */

/* currun() function is in emu/port/dis.c */

/* RC4 backward - move RC4 state backward */
void
rc4back(RC4state *s, ulong n)
{
	USED(s);
	USED(n);
}

/* RSA private key free */
typedef struct RSApriv RSApriv;
void
rsaprivfree(RSApriv *r)
{
	USED(r);
}

/* SHA2-224 hash */
DigestState*
sha2_224(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

/* SHA2-256 hash */
DigestState*
sha2_256(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

/* SHA2-384 hash */
DigestState*
sha2_384(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

/* SHA2-512 hash */
DigestState*
sha2_512(uchar *data, ulong dlen, uchar *digest, DigestState *s)
{
	USED(data);
	USED(dlen);
	USED(digest);
	USED(s);
	return nil;
}

/* Error function - sets error string and jumps to error handler */
void
error(char *msg)
{
	if(msg != nil)
		werrstr("%s", msg);
	/* Jump to previous error handler in the stack */
	if(up->nerr > 0)
		oslongjmp(nil, up->estack[up->nerr-1], 1);
	else
		longjmp(up->estack[0], 1);
}

/* Next error in error chain */
void
nexterror(void)
{
	if(up->nerr > 0)
		oslongjmp(nil, up->estack[up->nerr-1], 1);
	else
		longjmp(up->estack[0], 1);
}

/* String duplication for kernel strings */
/* kstrdup is defined in chan.c */

/* System name */
/* ossysname is defined in devcons.c */

/* Build process initialization */
/* kprocinit is defined in kproc-pthreads.c */

/* Process exit */
/* pexit is defined in kproc-pthreads.c */

/* Additional crypto functions - DSA */
typedef struct DSApub DSApub;
typedef struct DSApriv DSApriv;
typedef struct EGpub EGpub;
typedef struct EGpriv EGpriv;

DSApub*
dsaverify(DSApub *key, mpint *hash, mpint *sig)
{
	USED(key);
	USED(hash);
	USED(sig);
	return nil;
}

DSApriv*
dsagen(DSApub *pub, mpint *exp)
{
	USED(pub);
	USED(exp);
	return nil;
}

void
dsaprivfree(DSApriv *dsa)
{
	USED(dsa);
}

/* Elliptic curve crypto */
EGpriv*
eggen(EGpub *pub, mpint *exp)
{
	USED(pub);
	USED(exp);
	return nil;
}

void
egprivfree(EGpriv *eg)
{
	USED(eg);
}

/* RSA generate */
RSApriv*
rsagen(int nlen, int eplen, mpint *e)
{
	USED(nlen);
	USED(eplen);
	USED(e);
	return nil;
}

/* Multi-precision copy */
mpint*
mpcopy(mpint *x)
{
	USED(x);
	return nil;
}

void
mpfree(mpint *x)
{
	USED(x);
}

mpint*
mpdiv(mpint *a, mpint *b, mpint *r)
{
	USED(a);
	USED(b);
	USED(r);
	return nil;
}

/* Elliptic curve verify */
EGpub*
egverify(EGpub *key, mpint *hash, mpint *sig)
{
	USED(key);
	USED(hash);
	USED(sig);
	return nil;
}

/* kwerrstr is in emu/port/errstr.c */

/* FreeType font functions */
typedef struct Face Face;
typedef struct Ftname Ftname;

int
fthaschar(Face *f, Rune r)
{
	USED(f);
	USED(r);
	return 0;
}

void*
ftloadglyph(Face *f, Rune r)
{
	USED(f);
	USED(r);
	return nil;
}

Face*
ftnewface(uchar *data, int len)
{
	USED(data);
	USED(len);
	return nil;
}

void
ftsetcharsize(Face *f, int size, int dpi)
{
	USED(f);
	USED(size);
	USED(dpi);
}

void
ftsettransform(Face *f, void *mat)
{
	USED(f);
	USED(mat);
}

void
ftdoneface(Face *f)
{
	USED(f);
}

/* Memory pool functions */
/* poolchain and poolfree are defined in emu/port/alloc.c */

/* Free dynamic data */
void
freedyndata(Modlink *ml)
{
	USED(ml);
}

/* killcomm is in emu/port/pgrp.c */

/* Error with format */
void
errorf(char *fmt, ...)
{
	char buf[ERRMAX];
	va_list args;
	va_start(args, fmt);
	vsnprintf(buf, sizeof(buf), fmt, args);
	va_end(args);
	error(buf);
}

/* Pool allocate */
/* poolalloc is defined in emu/port/alloc.c */

/* Type constants for heap auditing */
/* TDisplay, TFont, TImage, TScreen defined in libinterp/draw.c - excluded here */
int TSigAlg = 4;
int TCertificate = 5;
int TDESstate = 6;
int TFD = 7;
int TFileIO = 8;
int TAuthinfo = 9;
int TDigestState = 10;
int TSK = 11;
int TPK = 12;

/* More multi-precision functions */
mpint*
mpadd(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

mpint*
mpand(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

mpint*
betomp(uchar *p, int n, mpint *b)
{
	USED(p);
	USED(n);
	return nil;
}

mpint*
mpexp(mpint *base, mpint *exp, mpint *mod)
{
	USED(base);
	USED(exp);
	USED(mod);
	return nil;
}

mpint*
genprime(int n, int accuracy)
{
	USED(n);
	USED(accuracy);
	return nil;
}

mpint*
genstrongprime(int n)
{
	USED(n);
	return nil;
}

mpint*
itomp(int i, mpint *b)
{
	USED(i);
	return nil;
}

mpint*
mpinvert(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

char*
mptoa(mpint *n, int base, char *buf, int len)
{
	USED(n);
	USED(base);
	USED(buf);
	USED(len);
	return "";
}

int
mptobe(mpint *n, uchar *p, int len, int skip)
{
	USED(n);
	USED(p);
	USED(len);
	USED(skip);
	return 0;
}

int
mptoi(mpint *n)
{
	USED(n);
	return 0;
}

mpint*
mpmod(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

mpint*
mpmul(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

mpint*
mpnot(mpint *a)
{
	USED(a);
	return nil;
}

mpint*
mpor(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

int
probably_prime(mpint *n, int nrep)
{
	USED(n);
	USED(nrep);
	return 0;
}

mpint*
mprand(int bits, int (*gen)(int), int seed)
{
	USED(bits);
	USED(gen);
	USED(seed);
	return nil;
}

mpint*
mpleft(mpint *a, int shift)
{
	USED(a);
	USED(shift);
	return nil;
}

mpint*
mpxor(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

int
mpcmp(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return 0;
}

mpint*
strtomp(char *str, char **end, int base, mpint *b)
{
	USED(str);
	USED(end);
	USED(base);
	return nil;
}

/* Kernel file operations - stub implementations */
int
kopen(char *path, int mode)
{
	USED(path);
	USED(mode);
	return -1;
}

int
kclose(int fd)
{
	USED(fd);
	return -1;
}

int
kcreate(char *path, int mode, ulong perm)
{
	USED(path);
	USED(mode);
	USED(perm);
	return -1;
}

/* Hex encoding */
int
enc16(char *out, int len, uchar *in, int n)
{
	USED(out);
	USED(len);
	USED(in);
	USED(n);
	return 0;
}

/* Pool memory region functions */
/* poolimmutable and poolmutable are defined in emu/port/alloc.c */

/* Kernel write */
s32
kwrite(int fd, void *buf, s32 len)
{
	USED(fd);
	USED(buf);
	USED(len);
	return -1;
}

/* Crypto module initialization */
void
elgamalinit(void)
{
}

void
rsainit(void)
{
}

void
dsainit(void)
{
}

/* More mp functions */
mpint*
mpright(mpint *a, int shift)
{
	USED(a);
	USED(shift);
	return nil;
}

mpint*
mpsub(mpint *a, mpint *b)
{
	USED(a);
	USED(b);
	return nil;
}

/* Kernel read */
s32
kread(int fd, void *buf, s32 len)
{
	USED(fd);
	USED(buf);
	USED(len);
	return -1;
}

/* Dynamic module linking */
void
newdyndata(Modlink *ml)
{
	USED(ml);
}

void
freedyncode(Module *m)
{
	USED(m);
}

/* System module initialization */
void
sysinit(void)
{
}

/* Floating point control */
ulong
FPcontrol(ulong new, ulong mask)
{
	USED(new);
	USED(mask);
	return 0;
}

ulong
FPstatus(ulong new, ulong mask)
{
	USED(new);
	USED(mask);
	return 0;
}

/* IEEE 754 math library functions */
double
__ieee754_acos(double x)
{
	return acos(x);
}

double
__ieee754_acosh(double x)
{
	return acosh(x);
}

double
__ieee754_asin(double x)
{
	return asin(x);
}

double
__ieee754_atan2(double y, double x)
{
	return atan2(y, x);
}

double
__ieee754_atanh(double x)
{
	return atanh(x);
}

double
__ieee754_cosh(double x)
{
	return cosh(x);
}

double
__ieee754_exp(double x)
{
	return exp(x);
}

double
__ieee754_fmod(double x, double y)
{
	return fmod(x, y);
}

double
__ieee754_log(double x)
{
	return log(x);
}

double
__ieee754_log10(double x)
{
	return log10(x);
}

double
__ieee754_pow(double x, double y)
{
	return pow(x, y);
}

double
__ieee754_remainder(double x, double y)
{
	return remainder(x, y);
}

double
__ieee754_scalb(double x, double fn)
{
	return x * pow(2.0, fn);
}

double
__ieee754_sinh(double x)
{
	return sinh(x);
}

double
__ieee754_sqrt(double x)
{
	return sqrt(x);
}

/* Vector dot product */
double
dot(void *a, void *b, int n)
{
	USED(a);
	USED(b);
	USED(n);
	return 0.0;
}

/* Matrix multiply */
void
gemm(void *a, void *b, void *c, int m, int n, int k)
{
	USED(a);
	USED(b);
	USED(c);
	USED(m);
	USED(n);
	USED(k);
}

/* Get FP control/status */
ulong
getFPcontrol(void)
{
	return 0;
}

ulong
getFPstatus(void)
{
	return 0;
}

/* More IEEE 754 math functions */
double
__ieee754_hypot(double x, double y)
{
	return hypot(x, y);
}

double
__ieee754_j0(double x)
{
	USED(x);
	return 0.0;
}

double
__ieee754_j1(double x)
{
	USED(x);
	return 0.0;
}

double
__ieee754_jn(int n, double x)
{
	USED(n);
	USED(x);
	return 0.0;
}

double
__ieee754_lgamma_r(double x, int *signgamp)
{
	USED(x);
	*signgamp = 1;
	return 0.0;
}

/* Index of absolute max */
int
iamax(void *x, int n)
{
	USED(x);
	USED(n);
	return 0;
}

/* Vector norms */
double
norm1(void *x, int n)
{
	USED(x);
	USED(n);
	return 0.0;
}

double
norm2(void *x, int n)
{
	USED(x);
	USED(n);
	return 0.0;
}

/* Integer power of 10 */
double
ipow10(int n)
{
	switch(n) {
	case 0: return 1.0;
	case 1: return 10.0;
	case 2: return 100.0;
	case 3: return 1000.0;
	case 4: return 10000.0;
	case 5: return 100000.0;
	case 6: return 1000000.0;
	default: return pow(10.0, (double)n);
	}
}

/* Bessel functions of second kind */
double
__ieee754_y0(double x)
{
	USED(x);
	return 0.0;
}

double
__ieee754_y1(double x)
{
	USED(x);
	return 0.0;
}

double
__ieee754_yn(int n, double x)
{
	USED(n);
	USED(x);
	return 0.0;
}

/* Global float conversion */
int
gfltconv(Fmt *f)
{
	USED(f);
	return '%g';
}

/* Kernel file stat */
Dir*
kdirfstat(int fd)
{
	USED(fd);
	return nil;
}

/* Check if file is dynamically loadable */
int
dynldable(int fd)
{
	USED(fd);
	return 0;
}

/* Kernel seek */
vlong
kseek(int fd, vlong offset, int whence)
{
	USED(fd);
	USED(offset);
	USED(whence);
	return -1;
}

/* New dynamic code */
Module*
newdyncode(int size, char *path, Dir *d)
{
	USED(size);
	USED(path);
	USED(d);
	return nil;
}

/* System error string */
char*
syserr(char *buf, char *s, Prog *p)
{
	USED(buf);
	USED(s);
	USED(p);
	return "system error";
}

/* Sys_* system call wrappers for Dis VM - these are defined in the emu/port/ layer */
/* These stubs are placeholders - real implementations should be in port layer */

void Sys_announce(void *fp)
{
}

void Sys_bind(void *fp)
{
}

void Sys_chdir(void *fp)
{
}

void Sys_create(void *fp)
{
}

void Sys_dial(void *fp)
{
}

void Sys_dirread(void *fp)
{
}

void Sys_dup(void *fp)
{
}

void Sys_export(void *fp)
{
}

/* Sys_fildes - get file descriptor number (returns Sys_FD* for given fd number) */
void Sys_fildes(void *fp)
{
	/* Stub: return nil for now - proper implementation requires mkfd() */
	USED(fp);
}

void Sys_file_accessible(void *fp)
{
}

void Sys_fstat(void *fp)
{
}

void Sys_fwstat(void *fp)
{
}

void Sys_mount(void *fp)
{
}

/* Sys_open - open a file (returns Sys_FD*) */
void Sys_open(void *fp)
{
	/* Stub: return nil for now - proper implementation requires mkfd() */
	USED(fp);
}

/* Sys_read - read from file descriptor */
void Sys_read(void *fp)
{
	F_Sys_read *f;

	f = fp;
	*f->ret = kread(fdchk(f->fd), f->buf, f->n);
}

void Sys_remove(void *fp)
{
}

void Sys_seek(void *fp)
{
}

/* Sys_sleep - sleep for milliseconds */
void Sys_sleep(void *fp)
{
	F_Sys_sleep *f;

	f = fp;
	*f->ret = osmillisleep(f->period);
}

void Sys_stat(void *fp)
{
}

void Sys_unmount(void *fp)
{
}

void Sys_wstat(void *fp)
{
}

/* Sys_write - write to file descriptor */
void Sys_write(void *fp)
{
	F_Sys_write *f;

	f = fp;
	*f->ret = kwrite(fdchk(f->fd), f->buf, f->n);
}

void Sys_fauth(void *fp)
{
}

void Sys_fd2path(void *fp)
{
}

void Sys_file2chan(void *fp)
{
}

/* Sys_fprint - print to file descriptor */
void Sys_fprint(void *fp)
{
	int n;
	Prog *p;
	char buf[1024], *b = buf;
	F_Sys_fprint *f;

	f = fp;
	p = currun();
	release();
	n = xprint(p, f, &f->vargs, f->s, buf, sizeof(buf));
	if (n >= sizeof(buf)-UTFmax-2)
		n = bigxprint(p, f, &f->vargs, f->s, &b, sizeof(buf));

	/* Logging DISABLED FOR DEBUGGING */

	*f->ret = n;
	acquire();
}

void Sys_fversion(void *fp)
{
}

void Sys_iounit(void *fp)
{
}

void Sys_listen(void *fp)
{
}

void Sys_millisec(void *fp)
{
}

void Sys_pctl(void *fp)
{
}

void Sys_pwrite(void *fp)
{
}

void Sys_readn(void *fp)
{
}

void Sys_awaken(void *fp)
{
}

void Sys_alt(void *fp)
{
}

void Sys_exits(void *fp)
{
}

void Sys_disown(void *fp)
{
}

void Sys_kill(void *fp)
{
}

void Sys_main(void *fp)
{
}

void Sys_mals(void *fp)
{
}

void Sys_told(void *fp)
{
}

void Sys_werrstr(void *fp)
{
}

/* Tk functions - from libtk */
static void
tkexec(void *tk, void *arg)
{
	USED(tk);
	USED(arg);
}

static char*
tkerrstr(void)
{
	return errbuf;
}

static void*
tklook(void *tk, int x, int y, int want)
{
	USED(tk);
	USED(x);
	USED(y);
	USED(want);
	return nil;
}

static void
tkdeliver(void *tk, void *t, void *c1, void *c2)
{
	USED(tk);
	USED(t);
	USED(c1);
	USED(c2);
}

static void
tkquit(void *tk, int status)
{
	USED(tk);
	USED(status);
}

static void
tkdirty(void *tk)
{
	USED(tk);
}

static char*
tkposn(void *t)
{
	USED(t);
	return "";
}

/* checkdisplay defined in libinterp/draw.c - excluded here */

static void*
tknewobj(void *tk, void *parent, char *name, char *type)
{
	USED(tk);
	USED(parent);
	USED(name);
	USED(type);
	return nil;
}

void Sys_stream(void *fp)
{
}

static int
tkrepeat(void *tk, int ms)
{
	USED(tk);
	USED(ms);
	return 0;
}

static void
tkfreeobj(void *tk, void *obj)
{
	USED(tk);
	USED(obj);
}

static void*
tksorttable(void)
{
	return nil;
}

static char*
tkeventfmt(char *buf, int n, void *e)
{
	USED(buf);
	USED(n);
	USED(e);
	return "";
}

static void
tkfreebind(void *b)
{
	USED(b);
}

/* lookupimage defined in libinterp/draw.c - excluded here */

static Rectangle
tkrect(void *t)
{
	USED(t);
	Rectangle r = {{0, 0}, {0, 0}};
	return r;
}

/* mkdrawimage defined in libinterp/draw.c - excluded here */

/* newprog is in emu/port/dis.c */

/* Display global */
void *_display = nil;
void *_drawinfo = nil;
void *_screen = nil;

/* bufimage defined in libinterp/draw.c - excluded here */

int
libread(int fd, void *buf, int len)
{
	USED(fd);
	USED(buf);
	USED(len);
	return -1;
}

/*
 * libqlalloc - Allocate a QLock (queue lock) for display synchronization
 * On Android, we use pthread mutex as the underlying implementation
 */
void*
libqlalloc(void)
{
	pthread_mutex_t *lock;

	lock = malloc(sizeof(pthread_mutex_t));
	if(lock == nil)
		return nil;

	if(pthread_mutex_init(lock, NULL) != 0) {
		free(lock);
		return nil;
	}

	return lock;
}

void
libqlock(void *q)
{
	pthread_mutex_t *lock = (pthread_mutex_t*)q;
	if(lock)
		pthread_mutex_lock(lock);
}

void
libqunlock(void *q)
{
	pthread_mutex_t *lock = (pthread_mutex_t*)q;
	if(lock)
		pthread_mutex_unlock(lock);
}

void
libqlfree(void *q)
{
	pthread_mutex_t *lock = (pthread_mutex_t*)q;
	if(lock) {
		pthread_mutex_destroy(lock);
		free(lock);
	}
}

int
libbind(char *old, char *new, int flag)
{
	USED(old);
	USED(new);
	USED(flag);
	return -1;
}

void*
libfdtochan(int fd, int mode)
{
	USED(fd);
	USED(mode);
	return nil;
}

Dir*
libdirfstat(int fd)
{
	USED(fd);
	return nil;
}

int
libwrite(int fd, void *buf, int len)
{
	USED(fd);
	USED(buf);
	USED(len);
	return -1;
}

void
libchanclose(void *c)
{
	USED(c);
}

void*
libqlowner(void *q)
{
	USED(q);
	return nil;
}

/* Sys_print - print to stdout (fd 1), which we redirect to logcat */
void Sys_print(void *fp)
{
	int n;
	Prog *p;
	char buf[1024], *b = buf;
	F_Sys_print *f;

	f = fp;
	p = currun();

	release();
	n = xprint(p, f, &f->vargs, f->s, buf, sizeof(buf));
	if (n >= sizeof(buf)-UTFmax-2)
		n = bigxprint(p, f, &f->vargs, f->s, &b, sizeof(buf));

	/* Log to Android logcat for debugging */
	__android_log_print(ANDROID_LOG_INFO, "TaijiOS-Dis", "%.*s", n, buf);

	acquire();

	*f->ret = n;
	/* Don't modify memory allocated by Limbo GC */
}

/* flushimage defined in libinterp/draw.c - excluded here */

/* Bio functions */
typedef struct Biobuf Biobuf;
typedef struct Biobufhdr Biobufhdr;

int
Bopen(char *name, int mode)
{
	USED(name);
	USED(mode);
	return -1;
}

/* drawerror defined in libinterp/draw.c - excluded here */

char*
Brdline(Biobuf *bp, int n)
{
	USED(bp);
	USED(n);
	return nil;
}

int
Bterm(Biobufhdr *bp)
{
	USED(bp);
	return -1;
}

/* Pool name */
/* poolname is defined in emu/port/alloc.c */

/* Tk string parsing */
/* tkword is defined in libtk/parse.c */

static void
tkfreename(char *name)
{
	USED(name);
}

static char*
tkvalue(char *s, char *fmt, ...)
{
	USED(s);
	USED(fmt);
	return "";
}

static void*
tkgc(void *tk, void *d, int fill)
{
	USED(tk);
	USED(d);
	USED(fill);
	return nil;
}

static void
tkbevel(void *tk, void *b, int style)
{
	USED(tk);
	USED(b);
	USED(style);
}

static char*
tkitem(char *s, char *e)
{
	USED(s);
	USED(e);
	return "";
}

static int
tkchanhastype(void *c, char *type)
{
	USED(c);
	USED(type);
	return 0;
}

static void
tkdrawstring(void *tk, void *bp, char *s, int n, void *f, void *scr, int p)
{
	USED(tk);
	USED(bp);
	USED(s);
	USED(n);
	USED(f);
	USED(scr);
	USED(p);
}

static void
tkdrawrelief(void *tk, void *b, int w, int style)
{
	USED(tk);
	USED(b);
	USED(w);
	USED(style);
}

static int
tkhasalpha(void *d)
{
	USED(d);
	return 0;
}

static int
TKF2I(int tk)
{
	return tk;
}

static void
tkputenv(char *name, char *val)
{
	USED(name);
	USED(val);
}

static int
tkfprint(int fd, char *s)
{
	USED(fd);
	USED(s);
	return 0;
}

static char*
tkfracword(char *s, char *e, char **w)
{
	USED(s);
	USED(e);
	USED(w);
	return "";
}

static char*
tkaction(void *tk, void *b, char *a, char *r, int infirst)
{
	USED(tk);
	USED(b);
	USED(a);
	USED(r);
	USED(infirst);
	return "";
}

static int
tkfrac(char *s, char *e, int *num, int *denom)
{
	USED(s);
	USED(e);
	USED(num);
	USED(denom);
	return 0;
}

static void
tksubdeliver(void *tk, void *t, void *c, int type, void *a, int click)
{
	USED(tk);
	USED(t);
	USED(c);
	USED(type);
	USED(a);
	USED(click);
}

static char*
tkname(char *s, char *e, char **w)
{
	USED(s);
	USED(e);
	USED(w);
	return "";
}

static void*
tkaddchild(void *tk, void *parent, void *child)
{
	USED(tk);
	USED(parent);
	USED(child);
	return nil;
}

static int
tklinehit(void *t, int x0, int y0, int x1, int y1, int thick)
{
	USED(t);
	USED(x0);
	USED(y0);
	USED(x1);
	USED(y1);
	USED(thick);
	return 0;
}

static int
tkrgbashade(int col, int shade)
{
	USED(col);
	USED(shade);
	return 0;
}

static int
tkinsidepoly(void *poly, int x, int y)
{
	USED(poly);
	USED(x);
	USED(y);
	return 0;
}

static void
tktextsdraw(void *t, void *screen, int offx, int offy)
{
	USED(t);
	USED(screen);
	USED(offx);
	USED(offy);
}

static void*
tkfindsub(void *tk, void *w, char *name)
{
	USED(tk);
	USED(w);
	USED(name);
	return nil;
}

static void
tkerr(void *tk, void *t, char *msg)
{
	USED(tk);
	USED(t);
	USED(msg);
}

static void
tkcancel(void *tk, void *t)
{
	USED(tk);
	USED(t);
}

static void
tksetmgrab(void *tk, void *t, void *grab)
{
	USED(tk);
	USED(t);
	USED(grab);
}

static int
tkhaskeyfocus(void *t)
{
	USED(t);
	return 0;
}

static int
tkmmax(int a, int b)
{
	return a > b ? a : b;
}

static int
tkiswordchar(int c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

static void
tkblink(void *t, int on)
{
	USED(t);
	USED(on);
}

static void
tkscrn2local(void *t, int *x, int *y)
{
	USED(t);
	USED(x);
	USED(y);
}

static int
tkvisiblerect(void *t, int x, int y, int w, int h)
{
	USED(t);
	USED(x);
	USED(y);
	USED(w);
	USED(h);
	return 0;
}

static void
tkbox(void *tk, void *b, int n, int *x, int *y)
{
	USED(tk);
	USED(b);
	USED(n);
	USED(x);
	USED(y);
}

static void
tkcancelrepeat(void *tk)
{
	USED(tk);
}

static void
tkblinkreset(void *tk)
{
	USED(tk);
}

static char*
tkdefaultenv(char *s)
{
	USED(s);
	return "";
}

static int
tkstringsize(void *f, char *s, int n)
{
	USED(f);
	USED(s);
	USED(n);
	return 0;
}

/* poolsetcompact is defined in emu/port/alloc.c */

/* Tk more functions */
static void
tksettransparent(void *tk, void *t, int trans)
{
	USED(tk);
	USED(t);
	USED(trans);
}

static int
tkrgbavals(char *s, int *red, int *green, int *blue, int *alpha)
{
	USED(s);
	USED(red);
	USED(green);
	USED(blue);
	USED(alpha);
	return 0;
}

static int
tkrgba(int red, int green, int blue, int alpha)
{
	USED(red);
	USED(green);
	USED(blue);
	USED(alpha);
	return 0;
}

/* display_open defined in libinterp/draw.c - excluded here */

/* font_open defined in libinterp/draw.c - excluded here */

static char**
tkdupenv(char **env)
{
	USED(env);
	return nil;
}

/* Kernel channel I/O */
long
kchanio(void *c, void *buf, int n, int mode)
{
	USED(c);
	USED(buf);
	USED(n);
	USED(mode);
	return -1;
}

/* Library I/O wrappers */
int
libreadn(int fd, void *buf, long len)
{
	USED(fd);
	USED(buf);
	USED(len);
	return -1;
}

int
libopen(char *name, int mode)
{
	USED(name);
	USED(mode);
	return -1;
}

int
libclose(int fd)
{
	USED(fd);
	return -1;
}

/* Missing Sys_* functions */
void Sys_pipe(void *fp)
{
}

void Sys_pread(void *fp)
{
}

/* Font functions */
/* font_close defined in libinterp/draw.c - excluded here */

/* Tk environment functions */
static char**
tknewenv(char **env)
{
	USED(env);
	return nil;
}

static void
tkfreecolcache(void *tk)
{
	USED(tk);
}

/* kmalloc is defined in emu/port/alloc.c */

/* Device table - defined in emu-g.c */
/* Debug flag */
int dflag = 0;

/* Panic function - for critical errors */
void
panic(char *fmt, ...)
{
	char buf[512];
	va_list args;
	va_start(args, fmt);
	vsnprintf(buf, sizeof(buf), fmt, args);
	va_end(args);
	/* Log and exit */
	__android_log_print(ANDROID_LOG_FATAL, "TaijiOS", "PANIC: %s", buf);
	abort();
}

/*
 * sbrk - grow the data segment for memory pool allocator
 * Android doesn't provide sbrk, so we implement it using mmap
 * This overrides any weak system declaration
 */
#undef sbrk  /* Undefine any system declaration */

void* sbrk(intptr_t increment)
{
	static void* current_brk = NULL;
	static void* max_brk = NULL;
	static pthread_mutex_t brk_lock = PTHREAD_MUTEX_INITIALIZER;
	void* new_brk;
	void* result;

	pthread_mutex_lock(&brk_lock);

	/* Initialize brk on first call */
	if (current_brk == NULL) {
		current_brk = mmap(NULL, 16*1024*1024, PROT_READ|PROT_WRITE,
		                   MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		if (current_brk == MAP_FAILED) {
			pthread_mutex_unlock(&brk_lock);
			return (void*)-1;
		}
		max_brk = (char*)current_brk + 16*1024*1024;
		LOGI("sbrk: initialized heap at %p, max %p", current_brk, max_brk);
	}

	if (increment == 0) {
		result = current_brk;
		pthread_mutex_unlock(&brk_lock);
		return result;
	}

	if (increment < 0) {
		/* shrinking */
		new_brk = (char*)current_brk + increment;
		if (new_brk < (char*)max_brk - 16*1024*1024) {
			pthread_mutex_unlock(&brk_lock);
			return (void*)-1;  /* Can't shrink below original */
		}
		result = current_brk;
		current_brk = new_brk;
		pthread_mutex_unlock(&brk_lock);
		return result;
	}

	/* growing */
	new_brk = (char*)current_brk + increment;
	if (new_brk > max_brk) {
		/* Need to expand the mapped region */
		size_t cur_size = (char*)max_brk - (char*)current_brk;
		size_t new_size = cur_size + increment + 1024*1024;  /* Add 1MB buffer */
		void* new_region = mremap(current_brk, cur_size, new_size, MREMAP_MAYMOVE);
		if (new_region == MAP_FAILED) {
			LOGE("sbrk: mremap failed cur=%zu new=%zu", cur_size, new_size);
			pthread_mutex_unlock(&brk_lock);
			return (void*)-1;
		}
		/* Update pointers if mremap moved the region */
		if (new_region != current_brk) {
			ptrdiff_t offset = (char*)new_region - (char*)current_brk;
			current_brk = (char*)current_brk + offset;
			max_brk = (char*)max_brk + offset;
		}
		max_brk = (char*)current_brk + new_size;
		new_brk = (char*)current_brk + increment;
		LOGI("sbrk: expanded heap to %zu bytes", new_size);
	}

	result = current_brk;
	current_brk = new_brk;
	pthread_mutex_unlock(&brk_lock);
	return result;
}

/* EG sign functions */
void*
egsign(EGpub *key, mpint *m, mpint *a)
{
	USED(key);
	USED(m);
	USED(a);
	return nil;
}

void
egsigfree(void *sig)
{
	USED(sig);
}

/* DSA sign functions */
void*
dsasign(DSApub *key, mpint *m, mpint *a)
{
	USED(key);
	USED(m);
	USED(a);
	return nil;
}

void
dsasigfree(void *sig)
{
	USED(sig);
}

/* Device tables - extern declarations */
extern Dev envdevtab;
extern Dev progdevtab;
extern Dev dupdevtab;
extern Dev capdevtab;
extern Dev fsdevtab;
extern Dev cmddevtab;
extern Dev indirdevtab;
extern Dev ipdevtab;
extern Dev eiadevtab;
extern Dev memdevtab;

/* vflag is in emu/port/dis.c */

/* Forward declarations for Android display initialization */
extern Display* android_initdisplay(void (*error)(Display*, char*));
extern void libqunlock(void* q);

static void
init_android_display(void)
{
	extern void *_display;

	if(_display == nil) {
		_display = android_initdisplay(nil);
		if(_display) {
			LOGI("init_android_display: Display initialized at %p", _display);
			LOGI("init_android_display: Graphics working - waiting for Dis module to draw");
		} else {
			LOGE("init_android_display: Failed to initialize display");
		}
	}
}

/* Missing module initialization */
void
srvmodinit(void)
{
}

/*
 * libinit - Initialize the TaijiOS emulator for Android
 * Called from NativeActivity onCreate
 */
void
libinit(char *imod)
{
	LOGI("libinit: ENTRY - imod=%s", imod ? imod : "NULL");
	Proc *p;
	typedef struct Osdep Osdep;
	struct Osdep {
		sem_t	sem;
		pthread_t	self;
	};
	Osdep *os;

	LOGI("libinit: Starting TaijiOS emulator");

	/* Initialize the hostname */
	kstrdup(&ossysname, "Android");

	/* Create the first process */
	p = newproc();
	if(p == nil) {
		LOGE("libinit: newproc failed");
		return;
	}

	/* Initialize the os field with a semaphore for this process */
	os = malloc(sizeof(Osdep));
	if(os == nil) {
		LOGE("libinit: malloc for os failed");
		return;
	}
	os->self = pthread_self();  /* Set self to current thread */
	sem_init(&os->sem, 0, 1);  /* Initialize semaphore with value 1 for main process */
	p->os = os;

	kprocinit(p);

	/* Set up user environment */
	p->env->uid = getuid();
	p->env->gid = getgid();
	p->env->user = strdup("");  /* Initialize user to empty string */
	if (p->env->user == nil) {
		LOGE("libinit: strdup failed for user");
	}
	p->env->errstr = p->env->errbuf0;
	p->env->syserrstr = p->env->errbuf1;

	/* Initialize Android display FIRST - before loading any Dis modules
	 * This fixes a race condition where Dis VM code (e.g., minimal.dis)
	 * tries to call GUI functions (tkclient->init(), tkclient->toplevel())
	 * before the display is ready, causing SIGSEGV crashes.
	 */
	init_android_display();

	LOGI("libinit: Calling emuinit");
	emuinit((void*)imod);  /* emuinit takes void* per fns.h */

	/* emuinit() has now loaded the Dis program and initialized its osenv (pgrp, fgrp, egrp).
	 * It's now safe to spawn vmachine which will execute the program. */

	/*
	 * CRITICAL FIX: Spawn vmachine as a kproc using kproc()
	 *
	 * The standard Inferno architecture has vmachine run in a dedicated kproc
	 * that blocks forever in the scheduler loop. kproc() properly sets up:
	 * 1. Thread-specific storage for the 'up' pointer (via pthread_setspecific)
	 * 2. Environment groups (pgrp, fgrp, egrp)
	 * 3. User credentials
	 * 4. The 'tramp' wrapper that calls the target function
	 *
	 * Using raw pthread_create doesn't set up 'up' correctly, causing
	 * NULL pointer crashes when vmachine calls startup().
	 *
	 * IMPORTANT: This MUST happen AFTER emuinit() completes, because
	 * emuinit() initializes the program's osenv (pgrp, fgrp, egrp) which
	 * is required before vmachine tries to execute the program.
	 */

	if (loaded_prog) {
		LOGI("libinit: BEFORE kproc, loaded_prog=%p, pid=%d, state=%d",
		     loaded_prog, loaded_prog->pid, loaded_prog->state);
	}

	LOGI("libinit: Spawning vmachine as kproc");

	kproc("dis", vmachine, nil, 0);

	LOGI("libinit: vmachine kproc spawned, returning to Android event loop");
}

/* emuinit is declared in fns.h as: void emuinit(void*); */

/* Stub implementations for missing architecture-specific functions */

/* FP (Floating Point) save/restore - stubs for ARM64 */
void
FPsave(void *fp)
{
	USED(fp);
	/* TODO: Implement ARM64 FP register save */
}

void
FPrestore(void *fp)
{
	USED(fp);
	/* TODO: Implement ARM64 FP register restore */
}

void
FPinit(void)
{
	/* TODO: Initialize ARM64 FP state */
}

/*
 * osdisksize - Get disk size for a file descriptor
 * Android doesn't expose all the Linux ioctls, so return 0
 */
vlong
osdisksize(int fd)
{
	USED(fd);
	/* TODO: Implement for Android using fstatfs if needed */
	return 0;
}

/*
 * seekdir - Set directory position
 * Android NDK may not provide seekdir, so provide an implementation
 */
void
seekdir(DIR *dirp, long loc)
{
	/*
	 * Simple implementation: close and reopen the directory
	 * This is not efficient but works for the use case in devfs-posix.c
	 * which only calls seekdir(dir, 0) to reset to beginning
	 */
	if (loc == 0) {
		rewinddir(dirp);
	}
	/* For non-zero positions, we'd need a more complex implementation */
}

/* Signal handler is system-provided */

/* dbgexit is in emu/port/devprog.c */
/* vflag is in emu/port/dis.c */
/* closeegrp is in emu/port/env.c */

/*
 * Android filesystem initialization
 * Stub implementation for android_main.c compatibility
 */
void
android_fs_init(const char* internal_path, const char* external_path)
{
	USED(internal_path);
	USED(external_path);
	/* Paths will be handled by the existing devfs-posix.c implementation */
	LOGI("android_fs_init: internal=%s external=%s",
	     internal_path ? internal_path : "nil",
	     external_path ? external_path : "nil");
}

/*
 * Load Dis bytecode from Android assets
 * Uses AAssetManager to read files from APK assets
 */

/* Forward declarations for Android Asset Manager */
typedef struct AAssetManager AAssetManager;
typedef struct AAsset AAsset;
#define AASSET_MODE_BUFFER 1
extern AAssetManager* android_get_asset_manager(void);
extern AAsset* AAssetManager_open(AAssetManager* manager, const char* filename, int mode);
extern off_t AAsset_getLength(AAsset* asset);
extern int AAsset_read(AAsset* asset, void* buf, size_t count);
extern void AAsset_close(AAsset* asset);

uchar*
load_dis_from_assets(const char* path, int* size_out)
{
	AAssetManager* mgr = android_get_asset_manager();
	if(mgr == NULL) {
		LOGE("load_dis_from_assets: Asset manager not initialized");
		return nil;
	}

	AAsset* asset = AAssetManager_open(mgr, path, AASSET_MODE_BUFFER);
	if(asset == NULL) {
		LOGE("load_dis_from_assets: Failed to open %s", path);
		return nil;
	}

	off_t size = AAsset_getLength(asset);
	uchar* buffer = malloc(size + 1);
	if(buffer == nil) {
		LOGE("load_dis_from_assets: malloc failed for %ld bytes", (long)size);
		AAsset_close(asset);
		return nil;
	}

	int read_result = AAsset_read(asset, buffer, size);
	if(read_result != size) {
		LOGE("load_dis_from_assets: Only read %d of %ld bytes", read_result, (long)size);
		free(buffer);
		AAsset_close(asset);
		return nil;
	}

	buffer[size] = '\0';
	AAsset_close(asset);

	*size_out = (int)size;
	LOGI("load_dis_from_assets: Loaded %s, %d bytes", path, (int)size);
	return buffer;
}