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
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <math.h>

#include <stdint.h>
#include <android/log.h>

#include "dat.h"
#include "fns.h"
#include "error.h"
#include <raise.h>

/* Forward declarations */
typedef struct Memimage Memimage;
typedef struct Rendez Rendez;
typedef struct Point Point;
typedef struct Rectangle Rectangle;
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
struct Point {
	int x;
	int y;
};
struct Rectangle {
	Point min;
	Point max;
};

#define LOG_TAG "TaijiOS"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

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

/* Forward declaration - modinit is defined in emu/Android/emu.c */
extern void modinit(void);

/* Emulator initialization - loads the Dis VM modules and starts execution */
void
emuinit(void *imod)
{
	USED(imod);
	LOGI("emuinit: TaijiOS emulator starting");

	/* Initialize the module system */
	modinit();

	LOGI("emuinit: Module initialization complete");
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

int
cflag = 0;

int keepbroken = 0;
char* exdebug = nil;

void
setid(char *name, int isid)
{
	USED(name);
	USED(isid);
}

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

Memimage*
attachscreen(char *label, char *win)
{
	USED(label);
	USED(win);
	return nil;
}

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

void
flushmemscreen(Rectangle r)
{
	(void)r;
}

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

/* Rendez synchronization */
void
acquire(Rendez *r)
{
	USED(r);
}

void
release(Rendez *r)
{
	USED(r);
}

/* Root device table - defined in emu-g.root.h */
/* Process monitoring */
/* memmonitor is defined as a function pointer in emu/port/alloc.c */
int progpid = 0;

/* PC to disassembler - stub for profiling */
char*
pc2dispc(uchar *pc, char *buf, int n)
{
	USED(pc);
	USED(n);
	if (n > 0) buf[0] = '\0';
	return buf;
}

/* poolmsize is defined in emu/port/alloc.c */

/* Runtime functions (acquire, release, delruntail, addrun) are in emu/port/proc.c */

/* Channel operations - stub */
int
csend(Chan *c, void *v, Block *b)
{
	USED(c);
	USED(v);
	USED(b);
	return 0;
}

int
crecv(Chan *c, void *v, Block *b)
{
	USED(c);
	USED(v);
	USED(b);
	return 0;
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

/* Format lock for fmt.c */
Lock _fmtlock;

void
_fmtunlock(void)
{
	/* Empty unlock for Android */
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

/* newmount is in emu/port/pgrp.c */

void
mountfree(Mount *m)
{
	USED(m);
}

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

/* Current running process */
Proc *currun = nil;

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

/* Kernel error string */
void
kwerrstr(char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	vsnprintf(errbuf, sizeof(errbuf), fmt, args);
	va_end(args);
}

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
freedyndata(void)
{
}

/* Kill command */
void
killcomm(void *c)
{
	USED(c);
}

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
int TDisplay = 0;
int TFont = 1;
int TImage = 2;
int TScreen = 3;
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
void*
newdyndata(void)
{
	return nil;
}

void
freedyncode(void *d)
{
	USED(d);
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
char gfltconv[256] = "%g";

/* Kernel file stat */
Dir*
kdirfstat(int fd)
{
	USED(fd);
	return nil;
}

/* Check if file is dynamically loadable */
int
dynldable(char *path)
{
	USED(path);
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
void*
newdyncode(int size)
{
	USED(size);
	return nil;
}

/* System error string */
char* syserr = "system error";

/* Sys_* system call wrappers for Dis VM - these are defined in the emu/port/ layer */
/* These stubs are placeholders - real implementations should be in port layer */

void Sys_announce(void)
{
}

void Sys_bind(void)
{
}

void Sys_chdir(void)
{
}

void Sys_create(void)
{
}

void Sys_dial(void)
{
}

void Sys_dirread(void)
{
}

void Sys_dup(void)
{
}

void Sys_export(void)
{
}

void Sys_fildes(void)
{
}

void Sys_file_accessible(void)
{
}

void Sys_fstat(void)
{
}

void Sys_fwstat(void)
{
}

void Sys_mount(void)
{
}

void Sys_open(void)
{
}

void Sys_read(void)
{
}

void Sys_remove(void)
{
}

void Sys_seek(void)
{
}

void Sys_sleep(void)
{
}

void Sys_stat(void)
{
}

void Sys_unmount(void)
{
}

void Sys_wstat(void)
{
}

void Sys_write(void)
{
}

void Sys_fauth(void)
{
}

void Sys_fd2path(void)
{
}

void Sys_file2chan(void)
{
}

void Sys_fprint(void)
{
}

void Sys_fversion(void)
{
}

void Sys_iounit(void)
{
}

void Sys_listen(void)
{
}

void Sys_millisec(void)
{
}

void Sys_pctl(void)
{
}

void Sys_pwrite(void)
{
}

void Sys_readn(void)
{
}

void Sys_awaken(void)
{
}

void Sys_alt(void)
{
}

void Sys_exits(void)
{
}

void Sys_disown(void)
{
}

void Sys_kill(void)
{
}

void Sys_main(void)
{
}

void Sys_mals(void)
{
}

void Sys_told(void)
{
}

void Sys_werrstr(void)
{
}

/* Tk functions - from libtk */
void
tkexec(void *tk, void *arg)
{
	USED(tk);
	USED(arg);
}

char*
tkerrstr(void)
{
	return errbuf;
}

void*
tklook(void *tk, int x, int y, int want)
{
	USED(tk);
	USED(x);
	USED(y);
	USED(want);
	return nil;
}

void
tkdeliver(void *tk, void *t, void *c1, void *c2)
{
	USED(tk);
	USED(t);
	USED(c1);
	USED(c2);
}

void
tkquit(void *tk, int status)
{
	USED(tk);
	USED(status);
}

void
tkdirty(void *tk)
{
	USED(tk);
}

char*
tkposn(void *t)
{
	USED(t);
	return "";
}

void*
checkdisplay(void)
{
	return nil;
}

void*
tknewobj(void *tk, void *parent, char *name, char *type)
{
	USED(tk);
	USED(parent);
	USED(name);
	USED(type);
	return nil;
}

void Sys_stream(void)
{
}

int
tkrepeat(void *tk, int ms)
{
	USED(tk);
	USED(ms);
	return 0;
}

void
tkfreeobj(void *tk, void *obj)
{
	USED(tk);
	USED(obj);
}

void*
tksorttable(void)
{
	return nil;
}

char*
tkeventfmt(char *buf, int n, void *e)
{
	USED(buf);
	USED(n);
	USED(e);
	return "";
}

void
tkfreebind(void *b)
{
	USED(b);
}

/* Display functions */
void
libqlock(void)
{
}

void
libqunlock(void)
{
}

void*
lookupimage(char *name, int lock)
{
	USED(name);
	USED(lock);
	return nil;
}

Rectangle
tkrect(void *t)
{
	USED(t);
	Rectangle r = {{0, 0}, {0, 0}};
	return r;
}

void*
mkdrawimage(void *tk, void *d, char *name, char *data, int ndata)
{
	USED(tk);
	USED(d);
	USED(name);
	USED(data);
	USED(ndata);
	return nil;
}

/* Program creation */
void*
newprog(void *mod, void *rstart)
{
	USED(mod);
	USED(rstart);
	return nil;
}

/* Display global */
void *_display = nil;
void *_drawinfo = nil;
void *_screen = nil;

/* Buffer image */
uchar*
bufimage(void *d, int n)
{
	USED(d);
	USED(n);
	return nil;
}

long
libread(int fd, void *buf, long len)
{
	USED(fd);
	USED(buf);
	USED(len);
	return -1;
}

void*
libqlalloc(void)
{
	return nil;
}

int
libbind(char *old, char *new, int flag)
{
	USED(old);
	USED(new);
	USED(flag);
	return -1;
}

void
libqlfree(void *q)
{
	USED(q);
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

long
libwrite(int fd, void *buf, long len)
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

/* Sys_print */
void Sys_print(void)
{
}

/* Flush image buffer */
int
flushimage(void *d, int visible)
{
	USED(d);
	USED(visible);
	return 0;
}

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

void
drawerror(char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	USED(fmt);
	va_end(args);
}

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

void
tkfreename(char *name)
{
	USED(name);
}

char*
tkvalue(char *s, char *fmt, ...)
{
	USED(s);
	USED(fmt);
	return "";
}

void*
tkgc(void *tk, void *d, int fill)
{
	USED(tk);
	USED(d);
	USED(fill);
	return nil;
}

void
tkbevel(void *tk, void *b, int style)
{
	USED(tk);
	USED(b);
	USED(style);
}

char*
tkitem(char *s, char *e)
{
	USED(s);
	USED(e);
	return "";
}

int
tkchanhastype(void *c, char *type)
{
	USED(c);
	USED(type);
	return 0;
}

void
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

void
tkdrawrelief(void *tk, void *b, int w, int style)
{
	USED(tk);
	USED(b);
	USED(w);
	USED(style);
}

int
tkhasalpha(void *d)
{
	USED(d);
	return 0;
}

int
TKF2I(int tk)
{
	return tk;
}

void
tkputenv(char *name, char *val)
{
	USED(name);
	USED(val);
}

int
tkfprint(int fd, char *s)
{
	USED(fd);
	USED(s);
	return 0;
}

char*
tkfracword(char *s, char *e, char **w)
{
	USED(s);
	USED(e);
	USED(w);
	return "";
}

char*
tkaction(void *tk, void *b, char *a, char *r, int infirst)
{
	USED(tk);
	USED(b);
	USED(a);
	USED(r);
	USED(infirst);
	return "";
}

int
tkfrac(char *s, char *e, int *num, int *denom)
{
	USED(s);
	USED(e);
	USED(num);
	USED(denom);
	return 0;
}

void
tksubdeliver(void *tk, void *t, void *c, int type, void *a, int click)
{
	USED(tk);
	USED(t);
	USED(c);
	USED(type);
	USED(a);
	USED(click);
}

char*
tkname(char *s, char *e, char **w)
{
	USED(s);
	USED(e);
	USED(w);
	return "";
}

void*
tkaddchild(void *tk, void *parent, void *child)
{
	USED(tk);
	USED(parent);
	USED(child);
	return nil;
}

int
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

int
tkrgbashade(int col, int shade)
{
	USED(col);
	USED(shade);
	return 0;
}

int
tkinsidepoly(void *poly, int x, int y)
{
	USED(poly);
	USED(x);
	USED(y);
	return 0;
}

void
tktextsdraw(void *t, void *screen, int offx, int offy)
{
	USED(t);
	USED(screen);
	USED(offx);
	USED(offy);
}

void*
tkfindsub(void *tk, void *w, char *name)
{
	USED(tk);
	USED(w);
	USED(name);
	return nil;
}

void
tkerr(void *tk, void *t, char *msg)
{
	USED(tk);
	USED(t);
	USED(msg);
}

void
tkcancel(void *tk, void *t)
{
	USED(tk);
	USED(t);
}

void
tksetmgrab(void *tk, void *t, void *grab)
{
	USED(tk);
	USED(t);
	USED(grab);
}

int
tkhaskeyfocus(void *t)
{
	USED(t);
	return 0;
}

int
tkmmax(int a, int b)
{
	return a > b ? a : b;
}

int
tkiswordchar(int c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

void
tkblink(void *t, int on)
{
	USED(t);
	USED(on);
}

void
tkscrn2local(void *t, int *x, int *y)
{
	USED(t);
	USED(x);
	USED(y);
}

int
tkvisiblerect(void *t, int x, int y, int w, int h)
{
	USED(t);
	USED(x);
	USED(y);
	USED(w);
	USED(h);
	return 0;
}

void
tkbox(void *tk, void *b, int n, int *x, int *y)
{
	USED(tk);
	USED(b);
	USED(n);
	USED(x);
	USED(y);
}

void
tkcancelrepeat(void *tk)
{
	USED(tk);
}

void
tkblinkreset(void *tk)
{
	USED(tk);
}

char*
tkdefaultenv(char *s)
{
	USED(s);
	return "";
}

int
tkstringsize(void *f, char *s, int n)
{
	USED(f);
	USED(s);
	USED(n);
	return 0;
}

/* poolsetcompact is defined in emu/port/alloc.c */

/* Tk more functions */
void
tksettransparent(void *tk, void *t, int trans)
{
	USED(tk);
	USED(t);
	USED(trans);
}

int
tkrgbavals(char *s, int *red, int *green, int *blue, int *alpha)
{
	USED(s);
	USED(red);
	USED(green);
	USED(blue);
	USED(alpha);
	return 0;
}

int
tkrgba(int red, int green, int blue, int alpha)
{
	USED(red);
	USED(green);
	USED(blue);
	USED(alpha);
	return 0;
}

void*
display_open(char *name)
{
	USED(name);
	return nil;
}

void*
font_open(char *name, int height)
{
	USED(name);
	USED(height);
	return nil;
}

char**
tkdupenv(char **env)
{
	USED(env);
	return nil;
}

/* Kernel channel I/O */
int
kchanio(void *c, void *buf, int n, int mode)
{
	USED(c);
	USED(buf);
	USED(n);
	USED(mode);
	return -1;
}

/* Library I/O wrappers */
long
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
void Sys_pipe(void)
{
}

void Sys_pread(void)
{
}

/* Font functions */
void
font_close(void *f)
{
	USED(f);
}

/* Tk environment functions */
char**
tknewenv(char **env)
{
	USED(env);
	return nil;
}

void
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

/* Missing device tables - stub implementations */
Dev envdevtab;
Dev progdevtab;
Dev dupdevtab;
Dev capdevtab;
Dev fsdevtab;
Dev cmddevtab;
Dev indirdevtab;
Dev ipdevtab;
Dev eiadevtab;
Dev memdevtab;

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
	Proc *p;

	LOGI("libinit: Starting TaijiOS emulator");

	/* Initialize the hostname */
	kstrdup(&ossysname, "Android");

	/* Create the first process */
	p = newproc();
	if(p == nil) {
		LOGE("libinit: newproc failed");
		return;
	}

	kprocinit(p);

	/* Set up user environment */
	p->env->uid = getuid();
	p->env->gid = getgid();

	LOGI("libinit: Calling emuinit");
	emuinit((void*)imod);  /* emuinit takes void* per fns.h */

	LOGI("libinit: Initialization complete");
}

/* emuinit is declared in fns.h as: void emuinit(void*); */