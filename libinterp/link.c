#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <kernel.h>

#define DP if(1){}else print

static void
newlink(Link *l, char *fn, int sig, Type *t)
{
	l->name = malloc(strlen(fn)+1);
	if(l->name == nil)
		error(exNomem);
	strcpy(l->name, fn);
	l->sig = sig;
	l->frame = t;
}

void
runtime(Module *m, Link *l, char *fn, int sig, void (*runt)(void*), Type *t)
{
	USED(m);
	newlink(l, fn, sig, t);
	l->u.runt = runt;
}

void
mlink(Module *m, Link* l, uchar *fn, int sig, int pc, Type *t)
{
	newlink(l, (char*)fn, sig, t);
	l->u.pc = m->prog+pc;
}

static int
linkm(Module *m, Modlink *ml, int i, Import *ldt)
{
	Link *l;
	int sig;
	char e[ERRMAX];

	sig = ldt->sig;
	for(l = m->ext; l->name; l++)
		if(strcmp(ldt->name, l->name) == 0){
			DP(" matched l->name %s l->sig 0x%ux\n", l->name, l->sig);
			break;
		}

	if(l == nil) {
		snprint(e, sizeof(e), "link failed fn %s->%s() not implemented",
			m->name, ldt->name);
		goto bad;
	}
	if(l->sig != sig) {
		snprint(e, sizeof(e), "link typecheck %s->%s() %ux/%ux",
			m->name, ldt->name, l->sig, sig);
		goto bad;
	}

	ml->links[i].u = l->u;
	ml->links[i].frame = l->frame;
	ml->links[i].name = l->name;
	return 0;
bad:
	kwerrstr(e);
	print("%s\n", e);
	return -1;
}

Modlink*
mklinkmod(Module *m, int n)
{
	Heap *h;
	Modlink *ml;

	h = nheap(sizeof(Modlink)+(n-1)*sizeof(ml->links[0]));
	h->t = &Tmodlink;
	Tmodlink.ref++;
	ml = H2D(Modlink*, h);
	ml->nlinks = n;
	ml->m = m;
	ml->prog = m->prog;
	ml->type = m->type;
	ml->compiled = m->compiled;
	ml->MP = H;
	ml->data = nil;

	return ml;
}
/* Create a Modlink which connects
   the functions in the ldt with their code in Module m
   Module m exports those functions through m->ext
 */
Modlink*
linkmod(Module *m, Import *ldt, int mkmp)
{
	Type *t;
	Heap *h;
	int i;
	Modlink *ml;
	Import *l;

	print("linkmod: m=%p, ldt=%p, mkmp=%d\n", m, ldt, mkmp);
	if(m != nil)
		print("linkmod: m->name='%s', m->path='%s'\n", m->name, m->path);

	if(m == nil)
		return H;

	for(i = 0, l = ldt; l->name != nil; i++, l++)
		;
	print("linkmod: %d imports to link\n", i);
	ml = mklinkmod(m, i);
	print("linkmod: ml=%p created by mklinkmod\n", ml);

	if(mkmp){
		if(m->rt == DYNMOD)
			newdyndata(ml);
		else if(mkmp && m->origmp != H && m->ntype > 0) {
			t = m->type[0];
			h = nheap(t->size);
			h->t = t;
			t->ref++;
			ml->MP = H2D(uchar*, h);
			newmp(ml->MP, m->origmp, t);
		}
	}

	for(i = 0, l = ldt; l->name != nil; i++, l++) {
		DP("linkmod connect i %d l->name %s l->sig 0x%ux",
			i, l->name, l->sig);
		print("linkmod: linking import %d: %s (sig 0x%x)\n", i, l->name, l->sig);
		if(linkm(m, ml, i, l) < 0){
			print("linkmod ERROR: linkm failed for %s\n", l->name);
			destroy(ml);
			return H;
		}
	}

	print("linkmod: returning ml=%p\n", ml);
	return ml;
}

void
destroylinks(Module *m)
{
	Link *l;

	for(l = m->ext; l->name; l++)
		free(l->name);
	free(m->ext);
}
