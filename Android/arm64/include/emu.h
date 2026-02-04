/*
 * Android ARM64 system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 */

#include <stdint.h>
#include <signal.h>
#include <setjmp.h>

#include "lib9.h"

/*
 * This structure must agree with FPsave and FPrestore asm routines
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[528];	/* 32 Q-regs (16 bytes each) + FPCR + FPSR for ARM64 */
};

/*
 * Android uses pthreads, so we need a different approach
 * The Proc structure will have a pthread-specific field
 */
#define KSTACK (64 * 1024)

extern	Proc*	getup(void);

#define	up	(getup())

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
