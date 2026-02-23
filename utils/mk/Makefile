# Simple Makefile to build mk with Posix/sh support

CC=gcc
CFLAGS=-c -g -O2 -std=c11 -fPIC -fno-strict-aliasing -fno-aggressive-loop-optimizations \
	-Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-unused-variable \
	-I../include -I../../include \
	-DROOT='"/mnt/storage/Projects/inferno"' \
	-DLINUX_AMD64 -D_GNU_SOURCE -D_DEFAULT_SOURCE

LDFLAGS=-o mk
LIBDIR=../../../Linux/amd64/lib
LIBS=-L$(LIBDIR) -lbio -l9 -lregexp -lm

# Source files - using Posix.c and sh.c for Linux
SOURCES=Posix.c sh.c arc.c archive.c bufblock.c env.c file.c graph.c job.c \
	lex.c main.c match.c mk.c parse.c recipe.c rule.c run.c shprint.c \
	symtab.c var.c varsub.c word.c

OBJECTS=$(SOURCES:.c=.o)

all: mk

mk: $(OBJECTS)
	$(CC) $(LDFLAGS) $(OBJECTS) $(LIBS)

clean:
	rm -f $(OBJECTS) mk

install: mk
	cp mk /mnt/storage/Projects/inferno/Linux/amd64/bin/

.PHONY: all clean install
