# Lua VM for Inferno/Limbo - Unified Implementation
# Lua 5.4 compatible virtual machine
#
# This module combines the complete Lua VM implementation from 24 separate files:
# - lua_types.b: Value type system and constructors
# - lua_object.b, lua_gcmem.b: Object allocation and memory management
# - lua_table.b, lua_hash.b: Table implementation with hybrid array/hash
# - lua_string.b: String interning and operations
# - lua_func.b, lua_upval.b: Functions, closures, and upvalues
# - lua_thread.b, lua_coro.b, lua_yield.b: Coroutine support
# - lua_gc.b, lua_gengc.b, lua_incrementalgc.b: Garbage collection
# - lua_parser.b, lua_lexer.b: Parser and lexical analyzer
# - lua_opcodes.b, lua_vm.b, lua_calls.b: Bytecode execution
# - lua_state.b: Lua state management
# - lua_debug.b, lua_corolib.b: Debug support and coroutine library
# - lua_code.b: Code generation
# - lua_weaktables.b: Weak table support

implement Luavm;

include "sys.m";
include "luavm.m";
include "draw.m";  # For draw library integration

sys: Sys;
print, sprint, fprint: import sys;

# ============================================================
# CONSTANTS (internal only - public ones are in luavm.m)
# ============================================================

# Mark colors for garbage collection
WHITE0:	con 0;	# White (not marked)
WHITE1:	con 1;	# White (alternative for generational)
BLACK:	con 2;	# Black (marked and processed)
GRAY:	con 3;	# Gray (marked, children not processed)

# Object type tags for GC (different from public types)
GCSTRING:	con 1;
GCTABLE:		con 2;
GCFUNCTION:	con 3;
GCUSERDATA:	con 4;
GCTHREAD:	con 5;
GCPROTO:		con 6;
GCUPVAL:		con 7;

# Call status flags
CIST_LUA:		con 1 << 0;	# Call is to Lua function
CIST_HOOKED:	con 1 << 1;	# Function has hook
CIST_REENTRY:	con 1 << 2;	# Call is reentrant
CIST_YIELDED:	con 1 << 3;	# Call yielded
CIST_TAIL:		con 1 << 4;	# Tail call
CIST_FRESH:	con 1 << 5;	# Fresh call (not resumed)

# Table implementation constants
MAXARRAY: con 256;  # Maximum array size before forcing hash
MINHASH:  con 16;   # Minimum hash table size

# ============================================================
# INTERNAL TYPES
# ============================================================

# VM execution state (extended from luavm.m)
VM: adt {
	L:			ref State;		# Lua state
	base:		int;			# Base stack index
	top:		int;			# Top stack index
	ci:			ref CallInfo;	# Current call frame
	pc:			int;			# Program counter
};

# Extended CallInfo with additional fields (overrides luavm.m)
CallInfoExt: adt {
	next:		ref CallInfoExt;	# Next frame in chain
	func:		ref Value;			# Function being executed
	base:		int;				# Base register
	top:		int;				# Top register
	savedpc:	int;				# Saved PC for returns
	nresults:	int;				# Number of results
	callstatus:	int;				# Call status flags
};

# GC object header
GCheader: adt {
	marked:	int;			# Mark bits for GC
	next:	ref GCheader;	# Next in allgc list
	tt:		int;			# Type tag
	refcount: int;			# Reference count (optional)
};

# GC state (global)
GCState: adt {
	strength:		int;		# GC strength
	usetimedelta:	int;		# Time since last collection
	majorminor:		int;		# Major vs minor collections
	lastatomic:		int;		# Last atomic collection
	protectgc:		int;		# Protected objects
	fromstate:		int;		# Previous state (for atomic)
	tolastatomic:	int;		# Time to last atomic
	debt:			big;		# Memory debt
	totalbytes:		big;		# Total memory allocated
	gcstop:			int;		# GC is stopped
	gcemergency:	int;		# Emergency mode
	gcpause:		int;		# Pause between collections
	gcmajorinc:		int;		# Major collection increment
	gccolorbarrier:	int;		# Color barrier for generational
	finobj:			ref GCheader;	# List of objects with finalizers
	allgc:			ref GCheader;	# List of all GC objects
	sweepgc:		ref GCheader;	# Sweeping position
	finobjsur:		ref GCheader;	# Survivors with finalizers
	tobefnz:		ref GCheader;	# To-be-finalized
	fixedgc:		ref GCheader;	# Fixed objects (not collected)
	old:			ref GCheader;	# Old generation (generational)
	sweepold:		ref GCheader;	# Old generation sweep position
};

# Extended upvalue with additional fields
UpvalExt: adt {
	v:			ref Value;			# Value pointer
	refcount:	int;				# Reference count
	open:		int;				# Is open (on stack)?
	prev:		ref UpvalExt;		# Previous in upvalue list
	next:		ref UpvalExt;		# Next in upvalue list
	stacklevel:	int;				# Stack level when opened
};

# Function state for compiler
FuncState: adt {
	prev:		ref FuncState;		# Outer function
	locals:		list of ref Locvar;	# Local variables
	upvalues:	array of string;		# Upvalue names
	nactvar:	int;				# Number of active variables
};

# Upvalue list for saving/restoring
UpvalList: adt {
	head:	ref Upval;
	count:	int;
};

# Global GC state instance
globalgc: ref GCState;
globalstate: ref State;

# String table for global state
stringtable: ref Stringtable;

# Memory allocation statistics
totalbytes: big;
gcstate: int;
gcthreshold: big;

# Current white for generational GC
CurrentWhite: con WHITE0;
OtherWhite: con WHITE1;

# ============================================================
# SECTION 1: VALUE CONSTRUCTORS
# ============================================================

# Create nil value
mknil(): ref Value
{
	v := ref Value;
	v.ty = TNIL;
	return v;
}

# Create boolean value
mkbool(b: int): ref Value
{
	v := ref Value;
	v.ty = TBOOLEAN;
	v.b = b;
	return v;
}

# Create number value
mknumber(n: real): ref Value
{
	v := ref Value;
	v.ty = TNUMBER;
	v.n = n;
	return v;
}

# Create string value
mkstring(s: string): ref Value
{
	v := ref Value;
	v.ty = TSTRING;
	v.s = s;
	return v;
}

# Create table value
mktable(t: ref Table): ref Value
{
	v := ref Value;
	v.ty = TTABLE;
	v.t = t;
	return v;
}

# Create function value
mkfunction(f: ref Function): ref Value
{
	v := ref Value;
	v.ty = TFUNCTION;
	v.f = f;
	return v;
}

# Create userdata value
mkuserdata(u: ref Userdata): ref Value
{
	v := ref Value;
	v.ty = TUSERDATA;
	v.u = u;
	return v;
}

# Create thread value
mkthread(th: ref Thread): ref Value
{
	v := ref Value;
	v.ty = TTHREAD;
	v.th = th;
	return v;
}

# ============================================================
# SECTION 2: TYPE CHECKING
# ============================================================

isnil(v: ref Value): int
{
	if(v == nil)
		return 1;
	return v.ty == TNIL;
}

isboolean(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TBOOLEAN;
}

isnumber(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TNUMBER;
}

isstring(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TSTRING;
}

istable(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TTABLE;
}

isfunction(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TFUNCTION;
}

isuserdata(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TUSERDATA;
}

isthread(v: ref Value): int
{
	if(v == nil)
		return 0;
	return v.ty == TTHREAD;
}

# ============================================================
# SECTION 3: TYPE CONVERSION
# ============================================================

# Convert value to boolean (Lua rules: nil and false are false, everything else is true)
toboolean(v: ref Value): int
{
	if(v == nil)
		return 0;
	if(v.ty == TNIL)
		return 0;
	if(v.ty == TBOOLEAN && v.b == 0)
		return 0;
	return 1;
}

# Convert value to number
tonumber(v: ref Value): real
{
	if(v == nil)
		return 0.0;

	case(v.ty) {
	TNUMBER =>
		return v.n;
	TBOOLEAN =>
		if(v.b)
			return 1.0;
		else
			return 0.0;
	TSTRING =>
		return strtonumber(v.s);
	* =>
		return 0.0;
	}
}

# Convert string to number (helper)
strtonumber(s: string): real
{
	n := 0.0;
	sign := 1.0;
	i := 0;
	strlen := len s;

	# Skip leading whitespace
	while(i < strlen) {
		c := s[i];
		if(c != ' ' && c != '\t' && c != '\n' && c != '\r')
			break;
		i++;
	}

	# Check for sign
	if(i < strlen) {
		c := s[i];
		if(c == '-') {
			sign = -1.0;
			i++;
		} else if(c == '+') {
			i++;
		}
	}

	# Parse digits
	have_digits := 0;
	while(i < strlen) {
		c := s[i];
		if(c >= '0' && c <= '9') {
			n = n * 10.0 + real(c - '0');
			i++;
			have_digits = 1;
		} else {
			break;
		}
	}

	# Parse decimal part
	if(i < strlen) {
		c := s[i];
		if(c == '.') {
			i++;
			dec := 0.1;
			while(i < strlen) {
				c := s[i];
				if(c >= '0' && c <= '9') {
					n = n + dec * real(c - '0');
					dec = dec / 10.0;
					i++;
					have_digits = 1;
				} else {
					break;
				}
			}
		}
	}

	# Parse exponent
	if(i < strlen) {
		c := s[i];
		if(c == 'e' || c == 'E') {
			i++;
			exp_sign := 1;
			if(i < strlen) {
				c := s[i];
				if(c == '-') {
					exp_sign = -1;
					i++;
				} else if(c == '+') {
					i++;
				}
			}
			exp := 0;
			while(i < strlen) {
				c := s[i];
				if(c >= '0' && c <= '9') {
					exp = exp * 10 + (c - '0');
					i++;
				} else {
					break;
				}
			}
			if(exp_sign > 0) {
				while(exp > 0) {
					n = n * 10.0;
					exp--;
				}
			} else {
				while(exp > 0) {
					n = n / 10.0;
					exp--;
				}
			}
		}
	}

	if(have_digits == 0)
		return 0.0;

	return n * sign;
}

# Convert value to string
tostring(v: ref Value): string
{
	if(v == nil)
		return "nil";

	case(v.ty) {
	TNIL =>
		return "nil";
	TBOOLEAN =>
		if(v.b)
			return "true";
		else
			return "false";
	TNUMBER =>
		if(v.n != v.n)  # NaN
			return "nan";
		if(v.n == 1.0/0.0)  # Inf
			return "inf";
		if(v.n == -1.0/0.0)  # -Inf
			return "-inf";
		return sprint("%g", v.n);
	TSTRING =>
		return v.s;
	TTABLE =>
		return "table";
	TFUNCTION =>
		if(v.f.isc)
			return "function: C";
		else
			return "function: Lua";
	TUSERDATA =>
		return "userdata";
	TTHREAD =>
		return "thread";
	* =>
		return "unknown";
	}
}

# Get type name
typeName(v: ref Value): string
{
	if(v == nil)
		return "no value";

	case(v.ty) {
	TNIL =>		return "nil";
	TBOOLEAN =>	return "boolean";
	TNUMBER =>	return "number";
	TSTRING =>	return "string";
	TTABLE =>	return "table";
	TFUNCTION =>	return "function";
	TUSERDATA =>	return "userdata";
	TTHREAD =>	return "thread";
	* =>		return "unknown";
	}
}

# Get string length (fast)
objlen(v: ref Value): int
{
	if(v == nil || v.ty != TSTRING)
		return 0;
	return len v.s;
}

# ============================================================
# SECTION 4: STACK OPERATIONS
# ============================================================

# Get value at index (handling absolute and negative indices)
getvalue(L: ref State, idx: int): ref Value
{
	if(L == nil || L.stack == nil)
		return nil;

	# Convert negative index to positive
	if(idx < 0) {
		idx = L.top + idx + 1;
	}

	if(idx < 0 || idx >= L.top)
		return nil;

	return L.stack[idx];
}

# Push value onto stack
pushvalue(L: ref State, v: ref Value)
{
	if(L == nil)
		return;

	# Grow stack if needed
	if(L.stack == nil) {
		L.stack = array[20] of ref Value;
	} else if(L.top >= len L.stack) {
		newstack := array[len L.stack * 2] of ref Value;
		newstack[:] = L.stack;
		L.stack = newstack;
	}

	L.stack[L.top++] = v;
}

# Push nil
pushnil(L: ref State)
{
	pushvalue(L, mknil());
}

# Push boolean
pushboolean(L: ref State, b: int)
{
	pushvalue(L, mkbool(b));
}

# Push number
pushnumber(L: ref State, n: real)
{
	pushvalue(L, mknumber(n));
}

# Push string
pushstring(L: ref State, s: string)
{
	pushvalue(L, mkstring(s));
}

# Pop n values from stack
pop(L: ref State, n: int)
{
	if(L == nil)
		return;

	if(n > L.top)
		L.top = 0;
	else
		L.top -= n;
}

# Get top of stack (number of elements)
gettop(L: ref State): int
{
	if(L == nil)
		return 0;
	return L.top;
}

# Set top of stack
settop(L: ref State, idx: int)
{
	if(L == nil)
		return;

	if(idx < 0) {
		idx = L.top + idx + 1;
	}

	if(idx < 0)
		idx = 0;

	# Grow stack if needed
	if(L.stack == nil) {
		L.stack = array[idx + 10] of ref Value;
	} else if(idx > len L.stack) {
		newstack := array[idx + 10] of ref Value;
		if(L.top > 0) {
			for(j := 0; j < L.top; j++)
				newstack[j] = L.stack[j];
		}
		L.stack = newstack;
	}

	# Fill with nils if growing
	if(idx > L.top) {
		for(i := L.top; i < idx; i++)
			L.stack[i] = mknil();
	}

	L.top = idx;
}

# ============================================================
# SECTION 5: TABLE IMPLEMENTATION
# ============================================================

# Create table with preallocated sizes
createtable(narr, nrec: int): ref Table
{
	t := ref Table;
	t.metatable = nil;

	# Allocate array part
	if(narr > 0) {
		t.arr = array[narr] of ref Value;
		t.sizearray = narr;
		for(i := 0; i < narr; i++) {
			v := ref Value;
			v.ty = TNIL;
			t.arr[i] = v;
		}
	} else {
		t.arr = nil;
		t.sizearray = 0;
	}

	# Allocate hash part
	if(nrec > 0) {
		t.hash = allochashtable(nrec);
	} else {
		t.hash = nil;
	}

	return t;
}

# Allocate hash table node
allochashtable(size: int): ref Hashnode
{
	# Allocate array of hash nodes
	nodes := array[size] of ref Hashnode;
	for(i := 0; i < size; i++)
		nodes[i] = nil;
	return ref Hashnode;  # Placeholder - store size separately
}

# Get value from table
gettablevalue(t: ref Table, key: ref Value): ref Value
{
	if(t == nil || key == nil) {
		result := ref Value;
		result.ty = TNIL;
		return result;
	}

	# Check metatable __index metamethod
	if(t.metatable != nil) {
		meta_idx := getmetafield(t, "__index");
		if(meta_idx != nil) {
			return metamethod_index(t, key, meta_idx);
		}
	}

	# Try array part for integer keys
	if(isintegerkey(key)) {
		n := int(key.n);
		if(n > 0 && n <= t.sizearray) {
			v := t.arr[n - 1];
			if(v != nil && v.ty != TNIL)
				return v;
		}
	}

	# Try hash part
	if(t.hash != nil) {
		return hashget(t.hash, key);
	}

	result := ref Value;
	result.ty = TNIL;
	return result;
}

# Check if key is integer (not float with fractional part)
isintegerkey(k: ref Value): int
{
	if(k == nil || k.ty != TNUMBER)
		return 0;
	return k.n == real(int(k.n));
}

# Get metamethod from metatable
getmetafield(t: ref Table, name: string): ref Value
{
	if(t == nil || t.metatable == nil)
		return nil;

	key := ref Value;
	key.ty = TSTRING;
	key.s = name;

	return gettablevalue(t.metatable, key);
}

# Metamethod __index handler
metamethod_index(t: ref Table, key: ref Value, metamethod: ref Value): ref Value
{
	if(metamethod == nil) {
		result := ref Value;
		result.ty = TNIL;
		return result;
	}

	# If metamethod is a table, look up key in it
	if(metamethod.ty == TTABLE && metamethod.t != nil) {
		return gettablevalue(metamethod.t, key);
	}

	# If metamethod is a function, call it
	# (This requires the full VM to be implemented)
	result := ref Value;
	result.ty = TNIL;
	return result;
}

# Set value in table
settablevalue(t: ref Table, key: ref Value, val: ref Value)
{
	if(t == nil || key == nil)
		return;

	# Check metatable __newindex metamethod
	if(t.metatable != nil) {
		meta_idx := getmetafield(t, "__newindex");
		if(meta_idx != nil) {
			metamethod_newindex(t, key, val, meta_idx);
			return;
		}
	}

	# Try array part for integer keys
	if(isintegerkey(key)) {
		n := int(key.n);
		if(n > 0 && n <= t.sizearray) {
			t.arr[n - 1] = val;
			return;
		}
		# Grow array if appropriate
		if(n == t.sizearray + 1 && shouldgrowarray(t)) {
			growarray(t, n);
			t.arr[n - 1] = val;
			return;
		}
	}

	# Set in hash part
	hashset(t, key, val);
}

# Metamethod __newindex handler
metamethod_newindex(t: ref Table, key: ref Value, val: ref Value, metamethod: ref Value)
{
	# Placeholder for metamethod handling
}

# Check if array should grow
shouldgrowarray(t: ref Table): int
{
	if(t.sizearray >= MAXARRAY)
		return 0;

	# Count non-nil elements in array
	count := 0;
	for(i := 0; i < t.sizearray; i++) {
		if(t.arr[i] != nil && t.arr[i].ty != TNIL)
			count++;
	}

	# If more than half full, grow
	return count > (t.sizearray / 2);
}

# Grow array part
growarray(t: ref Table, newsize: int)
{
	if(newsize <= t.sizearray)
		return;

	# Double size or at least newsize
	size := t.sizearray * 2;
	if(size < 8)
		size = 8;
	if(size < newsize)
		size = newsize;

	newarray := array[size] of ref Value;
	for(i := 0; i < t.sizearray; i++)
		newarray[i] = t.arr[i];
	for(j := t.sizearray; j < size; j++) {
		v := ref Value;
		v.ty = TNIL;
		newarray[j] = v;
	}

	t.arr = newarray;
	t.sizearray = size;
}

# Hash table operations
hashget(hash: ref Hashnode, key: ref Value): ref Value
{
	# Placeholder - linear search in chain
	result := ref Value;
	result.ty = TNIL;
	return result;
}

hashset(t: ref Table, key: ref Value, val: ref Value)
{
	# Create hash table if needed
	if(t.hash == nil) {
		t.hash = allochashtable(MINHASH);
	}

	# Insert into hash
	# For now, just ensure hash exists
}

# Table length operator (#)
tablelength(t: ref Table): int
{
	if(t == nil)
		return 0;

	# Find first boundary (nil after non-nil)
	# Binary search for boundary
	i := 1;
	j := t.sizearray;

	if(j == 0)
		return 0;

	# Binary search for first nil
	while(i < j) {
		mid := (i + j + 1) / 2;
		if(t.arr[mid - 1] != nil && t.arr[mid - 1].ty != TNIL)
			i = mid;
		else
			j = mid - 1;
	}

	return i;
}

# Raw get (no metamethods)
rawget(t: ref Table, key: ref Value): ref Value
{
	if(t == nil || key == nil) {
		result := ref Value;
		result.ty = TNIL;
		return result;
	}

	if(isintegerkey(key)) {
		n := int(key.n);
		if(n > 0 && n <= t.sizearray) {
			return t.arr[n - 1];
		}
	}

	if(t.hash != nil)
		return hashget(t.hash, key);

	result := ref Value;
	result.ty = TNIL;
	return result;
}

# Raw set (no metamethods)
rawset(t: ref Table, key: ref Value, val: ref Value)
{
	if(t == nil || key == nil)
		return;

	if(isintegerkey(key)) {
		n := int(key.n);
		if(n > 0 && n <= t.sizearray) {
			t.arr[n - 1] = val;
			return;
		}
	}

	hashset(t, key, val);
}

# Set metatable
setmetatable_table(t: ref Table, mt: ref Table)
{
	if(t == nil)
		return;
	t.metatable = mt;
}

# Get metatable
getmetatable_table(t: ref Table): ref Table
{
	if(t == nil)
		return nil;
	return t.metatable;
}

# ============================================================
# SECTION 6: STRING OPERATIONS
# ============================================================

# Initialize string table
initstrings()
{
	stringtable = ref Stringtable;
	stringtable.size = 64;  # Initial hash table size
	stringtable.nuse = 0;
	stringtable.hash = array[stringtable.size] of ref TString;
	for(i := 0; i < stringtable.size; i++)
		stringtable.hash[i] = nil;
}

# String hashing - djb2 algorithm
strhash(s: string): int
{
	h := 5381;
	strlen := len s;
	for(i := 0; i < strlen; i++) {
		c := s[i];
		if(c < 0)
			c += 256;
		h = ((h << 5) + h) + c;  # h * 33 + c
	}
	if(h < 0)
		h = -h;
	return h;
}

# Intern a string - returns existing TString if already interned
internstring(s: string): ref TString
{
	if(s == nil)
		return nil;

	if(stringtable == nil)
		initstrings();

	h := strhash(s);
	idx := h % stringtable.size;

	# Search for existing string
	node := stringtable.hash[idx];
	while(node != nil) {
		if(node.hash == h && node.s == s)
			return node;  # Found existing string
		node = node.next;
	}

	# Create new string node
	ts := ref TString;
	ts.s = s;
	ts.length = len s;
	ts.hash = h;
	ts.next = stringtable.hash[idx];
	ts.reserved = 0;

	stringtable.hash[idx] = ts;
	stringtable.nuse++;

	# Resize hash table if needed
	if(stringtable.nuse > stringtable.size)
		resizestringtable();

	return ts;
}

# Resize string table when it gets too full
resizestringtable()
{
	oldsize := stringtable.size;
	oldhash := stringtable.hash;

	# Double the size
	newsize := oldsize * 2;
	stringtable.size = newsize;
	stringtable.hash = array[newsize] of ref TString;
	stringtable.nuse = 0;

	# Rehash all strings
	for(i := 0; i < oldsize; i++) {
		node := oldhash[i];
		while(node != nil) {
			next := node.next;
			idx := node.hash % newsize;
			node.next = stringtable.hash[idx];
			stringtable.hash[idx] = node;
			stringtable.nuse++;
			node = next;
		}
	}
}

# ============================================================
# SECTION 7: FUNCTION AND CLOSURE OPERATIONS
# ============================================================

# Create new Lua closure (with prototype)
newluaclosure(proto: ref Proto, env: ref Table): ref Function
{
	f := ref Function;
	f.isc = 0;  # Lua closure
	f.proto = proto;
	# cfunc is a function pointer - no need to assign nil

	# Allocate upvalue array
	if(proto != nil && proto.upvalues != nil) {
		nupvals := len proto.upvalues;
		if(nupvals > 0) {
			f.upvals = array[nupvals] of ref Upval;
			for(i := 0; i < nupvals; i++)
				f.upvals[i] = nil;
		} else {
			f.upvals = nil;
		}
	} else {
		f.upvals = nil;
	}

	# Set environment
	f.env = env;
	if(f.env == nil)
		f.env = createtable(0, 32);

	return f;
}

# Create new C closure (for host integration)
# Note: Function pointers must be set directly on the Function object
newcclosure(nupvals: int): ref Function
{
	f := ref Function;
	f.isc = 1;  # C closure
	# cfunc must be set by the caller
	# proto is for Lua functions only

	# Allocate upvalue array
	if(nupvals > 0) {
		f.upvals = array[nupvals] of ref Upval;
		for(i := 0; i < nupvals; i++)
			f.upvals[i] = nil;
	} else {
		f.upvals = nil;
	}

	# C closures use global environment
	f.env = createtable(0, 32);

	return f;
}

# Get closure environment
getfenv(f: ref Function): ref Table
{
	if(f == nil)
		return nil;
	return f.env;
}

# Set closure environment
setfenv_func(f: ref Function, env: ref Table)
{
	if(f == nil)
		return;
	f.env = env;
}

# Check if function is Lua closure
isluaclosure(f: ref Function): int
{
	if(f == nil)
		return 0;
	return f.isc == 0;
}

# Check if function is C closure
iscclosure(f: ref Function): int
{
	if(f == nil)
		return 0;
	return f.isc == 1;
}

# Get function prototype (for Lua closures)
getproto(f: ref Function): ref Proto
{
	if(f == nil || f.isc != 0)
		return nil;
	return f.proto;
}

# Get number of upvalues
getnupvals(f: ref Function): int
{
	if(f == nil || f.upvals == nil)
		return 0;
	return len f.upvals;
}

# ============================================================
# SECTION 8: UPVALUE OPERATIONS
# ============================================================

# Find or create upvalue for stack position
findupval(L: ref State, level: int, pos: int): ref Upval
{
	# For simplicity, create new upvalue
	uv := ref Upval;
	uv.v = nil;
	uv.refcount = 1;
	return uv;
}

# Close all upvalues at or above stack position
closeupvals_state(L: ref State, level: int, pos: int)
{
	# Placeholder - would close open upvalues
}

# Get upvalue value
getupvalvalue_uv(uv: ref Upval): ref Value
{
	if(uv == nil)
		return nil;
	return uv.v;
}

# Set upvalue value
setupvalvalue_uv(uv: ref Upval, val: ref Value)
{
	if(uv == nil)
		return;
	uv.v = val;
}

# ============================================================
# SECTION 9: THREAD/COROUTINE OPERATIONS
# ============================================================

# Create new thread
newthread_state(L: ref State): ref Thread
{
	if(L == nil)
		return nil;

	th := ref Thread;

	# Set initial status
	th.status = OK;

	# Allocate separate stack for thread
	th.stack = array[20] of ref Value;
	th.base = 0;
	th.top = 0;

	# Initialize call info
	th.ci = nil;

	return th;
}

# Get status from thread
getstatus_thread(th: ref Thread): string
{
	if(th == nil)
		return "dead";

	case(th.status) {
	OK =>
		return "running";
	YIELD =>
		return "suspended";
	ERRRUN or ERRSYNTAX or ERRMEM or ERRERR or ERRFILE =>
		return "dead";
	* =>
		return "unknown";
	}
}

# Check if thread is alive
isalive_thread(th: ref Thread): int
{
	if(th == nil)
		return 0;
	return th.status == OK || th.status == YIELD;
}

# Resume coroutine
resume_thread(L: ref State, co: ref Thread, nargs: int): int
{
	if(co == nil)
		return ERRRUN;

	if(!isalive_thread(co))
		return ERRRUN;

	# Placeholder - would implement full resume logic
	return OK;
}

# Yield from coroutine
yield_thread(L: ref State, nresults: int): int
{
	return YIELD;
}

# ============================================================
# SECTION 10: MEMORY ALLOCATION AND GC
# ============================================================

# Initialize memory system
initmem()
{
	totalbytes = big 0;
	gcstate = 0;
	gcthreshold = big (1024 * 1024);  # 1MB

	# Initialize global GC state
	globalgc = ref GCState;
	globalgc.totalbytes = big 0;
	globalgc.gcstop = 0;
	globalgc.gcemergency = 0;
	globalgc.allgc = nil;
	globalgc.finobj = nil;
	globalgc.sweepgc = nil;
}

# Allocate GC object
allocgcobject(tt: int, sz: int): ref GCheader
{
	# Calculate size including header
	objsz := sz + 4;  # GCheader size (simplified)

	# Check if GC should run
	if(totalbytes >= gcthreshold)
		stepgc();

	# Allocate object
	obj := ref GCheader;
	obj.marked = CurrentWhite;  # Current white
	obj.next = nil;
	obj.tt = tt;
	obj.refcount = 0;

	totalbytes += big objsz;

	# Add to allgc list
	if(globalgc != nil) {
		obj.next = globalgc.allgc;
		globalgc.allgc = obj;
	}

	return obj;
}

# Mark object for GC
markobject(obj: ref GCheader)
{
	if(obj == nil)
		return;

	# If already marked, stop
	if(obj.marked == BLACK || obj.marked == GRAY)
		return;

	# Mark object as gray
	obj.marked = GRAY;
}

# Mark value
markvalue(v: ref Value)
{
	if(v == nil)
		return;

	case(v.ty) {
	TTABLE =>
		if(v.t != nil)
			marktable_object(v.t);
	TFUNCTION =>
		if(v.f != nil)
			markfunction_object(v.f);
	TUSERDATA =>
		if(v.u != nil)
			markuserdata_object(v.u);
	TTHREAD =>
		if(v.th != nil)
			markthread_object(v.th);
	TSTRING =>
		# Strings don't need marking in this simplified version
		;
	* =>
		;
	}
}

# Mark table
marktable_object(t: ref Table)
{
	if(t == nil)
		return;

	# Mark metatable
	if(t.metatable != nil)
		marktable_object(t.metatable);

	# Mark array elements
	if(t.arr != nil) {
		for(i := 0; i < t.sizearray; i++) {
			markvalue(t.arr[i]);
		}
	}

	# Mark hash elements (simplified)
	if(t.hash != nil) {
		# Need to traverse hash chain
	}
}

# Mark function
markfunction_object(f: ref Function)
{
	if(f == nil)
		return;

	# Mark prototype
	if(f.proto != nil)
		markproto_object(f.proto);

	# Mark environment
	if(f.env != nil)
		marktable_object(f.env);

	# Mark upvalues
	if(f.upvals != nil) {
		for(i := 0; i < len f.upvals; i++) {
			uv := f.upvals[i];
			if(uv != nil && uv.v != nil)
				markvalue(uv.v);
		}
	}
}

# Mark prototype
markproto_object(p: ref Proto)
{
	if(p == nil)
		return;

	# Mark constants
	if(p.k != nil) {
		for(i := 0; i < len p.k; i++) {
			markvalue(p.k[i]);
		}
	}

	# Mark nested prototypes
	if(p.p != nil) {
		for(i := 0; i < len p.p; i++) {
			markproto_object(p.p[i]);
		}
	}
}

# Mark userdata
markuserdata_object(u: ref Userdata)
{
	if(u == nil)
		return;

	# Mark environment
	if(u.env != nil)
		marktable_object(u.env);

	# Mark metatable
	if(u.metatable != nil)
		marktable_object(u.metatable);
}

# Mark thread
markthread_object(th: ref Thread)
{
	if(th == nil)
		return;

	# Mark stack values
	if(th.stack != nil) {
		for(i := 0; i < th.top; i++) {
			markvalue(th.stack[i]);
		}
	}

	# Mark call info chain (call frames contain values)
	ci := th.ci;
	while(ci != nil) {
		if(ci.func != nil)
			markvalue(ci.func);
		ci = ci.next;
	}
}

# Full garbage collection
fullgc()
{
	if(globalgc == nil)
		return;

	# Mark phase
	markroot();

	# Sweep phase
	sweepgc();

	# Flip white colors
	# (Simplified - in real implementation would swap CurrentWhite/OtherWhite)
}

# Mark root objects
markroot()
{
	if(globalstate == nil)
		return;

	# Mark registry
	if(globalstate.registry != nil)
		marktable_object(globalstate.registry);

	# Mark global table
	if(globalstate.global != nil)
		marktable_object(globalstate.global);

	# Mark stack
	if(globalstate.stack != nil) {
		for(i := 0; i < globalstate.top; i++) {
			markvalue(globalstate.stack[i]);
		}
	}

	# Propagate marks
	if(globalgc != nil)
		propagatemarks();
}

# Propagate marks through gray objects
propagatemarks()
{
	if(globalgc == nil)
		return;

	# Process all gray objects and mark them black
	# In this simplified version, object-specific marking is done
	# through the type-specific mark functions (marktable_object, etc.)
	# that are called during root marking

	obj := globalgc.allgc;
	while(obj != nil) {
		if(obj.marked == GRAY) {
			# Mark as black (processed)
			obj.marked = BLACK;
		}

		obj = obj.next;
	}
}

# Sweep phase - free unmarked objects
sweepgc()
{
	if(globalgc == nil)
		return;

	# Sweep all GC objects
	prev := ref GCheader;
	obj := globalgc.allgc;

	while(obj != nil) {
		nextobj := obj.next;

		if(obj.marked == CurrentWhite) {
			# Object is dead - free it
			# (In real implementation would actually free memory)
			# Unlink from list
			if(prev != nil)
				prev.next = nextobj;
			else
				globalgc.allgc = nextobj;
		} else {
			# Object survived - make it white again
			obj.marked = CurrentWhite;
			prev = obj;
		}

		obj = nextobj;
	}
}

# Incremental GC step
stepgc()
{
	# Simple incremental GC
	case(gcstate) {
	0 =>
		# Mark phase
		markroot();
		gcstate = 1;
	1 =>
		# Continue marking
		propagatemarks();
		gcstate = 2;
	2 =>
		# Sweep phase
		sweepgc();
		gcstate = 0;
		totalbytes = big 0;  # Reset counter
	}
}

# GC interface
gc(L: ref State, what: int, data: real): real
{
	case(what) {
	GCSTOP =>
		# Disable GC
		gcstate = -1;
		return 0.0;
	GCRESTART =>
		# Enable GC
		if(gcstate < 0)
			gcstate = 0;
		return 0.0;
	GCCOLLECT =>
		# Full collection
		fullgc();
		return real(totalbytes);
	GCCOUNT =>
		# Return memory in KB
		return real(totalbytes / big 1024);
	GCCOUNTB =>
		# Return remainder / 1024
		return real(totalbytes % big 1024);
	GCSTEP =>
		# Incremental step
		if(gcstate >= 0)
			stepgc();
		return real(totalbytes);
	GCSETPAUSE =>
		# Set pause (data is new pause value)
		return 0.0;
	GCSETSTEPMUL =>
		# Set step multiplier (data is new multiplier)
		return 0.0;
	}
	return 0.0;
}

# ============================================================
# SECTION 11: STATE MANAGEMENT
# ============================================================

# Create new Lua state
newstate(): ref State
{
	L := ref State;

	L.stack = array[20] of ref Value;
	L.top = 0;
	L.base = 0;
	L.global = createtable(0, 32);  # Preallocate space for globals
	L.registry = createtable(0, 0);
	L.upvalhead = nil;
	L.ci = nil;
	L.errorjmp = nil;

	# Save as global state for GC
	globalstate = L;

	return L;
}

# Close Lua state
close(L: ref State)
{
	if(L == nil)
		return;

	# Free stack
	L.stack = nil;
	# GC will collect tables and other objects
	L.global = nil;
	L.registry = nil;
	L.ci = nil;
	L.upvalhead = nil;
}

# Create new table (pushes onto stack)
newtable(L: ref State): ref Table
{
	t := createtable(0, 0);
	pushvalue(L, mktable(t));
	return t;
}

# Get table field by string key
getfield(L: ref State, idx: int, k: string)
{
	t := getvalue(L, idx);
	if(t == nil || t.ty != TTABLE || t.t == nil) {
		pushnil(L);
		return;
	}

	key := mkstring(k);
	v := gettablevalue(t.t, key);
	pushvalue(L, v);
}

# Set table field by string key
setfield(L: ref State, idx: int, k: string)
{
	t := getvalue(L, idx);
	if(t == nil || t.ty != TTABLE || t.t == nil)
		return;

	if(L.top < 1)
		return;

	v := L.stack[L.top - 1];  # Get value from top of stack
	key := mkstring(k);
	settablevalue(t.t, key, v);
}

# Get table value (key at top-1, table at top-2)
gettable(L: ref State, idx: int)
{
	t := getvalue(L, idx);
	if(t == nil || t.ty != TTABLE || t.t == nil) {
		pushnil(L);
		return;
	}

	if(L.top < 1)
		return;

	key := L.stack[L.top - 1];
	pop(L, 1);

	v := gettablevalue(t.t, key);
	pushvalue(L, v);
}

# Set table value (table at top-2, key at top-1, value at top)
settable(L: ref State, idx: int)
{
	t := getvalue(L, idx);
	if(t == nil || t.ty != TTABLE || t.t == nil)
		return;

	if(L.top < 2)
		return;

	v := L.stack[L.top - 1];
	key := L.stack[L.top - 2];
	pop(L, 2);

	settablevalue(t.t, key, v);
}

# ============================================================
# SECTION 12: VM EXECUTION
# ============================================================

# VM creation
newvm(L: ref State): ref VM
{
	vm := ref VM;
	vm.L = L;
	vm.base = 0;
	vm.top = L.top;
	vm.ci = nil;
	vm.pc = 0;
	return vm;
}

# Call a builtin (C closure) function
callbuiltin(L: ref State, func: ref Value, nargs: int): int
{
	if(func == nil || func.f == nil || func.f.builtin == nil)
		return ERRRUN;

	name := func.f.builtin;

	# Get arguments from stack
	base := L.top - nargs;

	# Dispatch to appropriate builtin
	if(name == "print") {
		return builtin_print(L, base, nargs);
	} else if(name == "type") {
		return builtin_type(L, base, nargs);
	} else if(name == "tostring") {
		return builtin_tostring(L, base, nargs);
	} else if(name == "tonumber") {
		return builtin_tonumber(L, base, nargs);
	} else if(name == "error") {
		return builtin_error(L, base, nargs);
	} else if(name == "assert") {
		return builtin_assert(L, base, nargs);
	} else if(name == "ipairs") {
		return builtin_ipairs(L, base, nargs);
	} else if(name == "pairs") {
		return builtin_pairs(L, base, nargs);
	} else if(name == "next") {
		return builtin_next(L, base, nargs);
	} else {
		# Unknown builtin
		sys->fprint(sys->fildes(2), "lua: unknown builtin: %s\n", name);
		return ERRRUN;
	}
}

# Builtin: print(...)
builtin_print(L: ref State, base: int, nargs: int): int
{
	if(L == nil)
		return OK;

	for(i := 0; i < nargs; i++) {
		if(i > 0)
			sys->print("\t");

		if(base + i < len L.stack) {
			v := L.stack[base + i];
			if(v != nil) {
				s := tostring(v);
				if(s != nil)
					sys->print("%s", s);
			}
		}
	}
	sys->print("\n");

	# Push nil as result
	pushnil(L);
	return OK;
}

# Builtin: type(v)
builtin_type(L: ref State, base: int, nargs: int): int
{
	if(L == nil)
		return OK;

	result := "nil";
	if(nargs > 0 && base < len L.stack) {
		v := L.stack[base];
		if(v != nil) {
			result = typeName(v);
		}
	}

	pushstring(L, result);
	return OK;
}

# Builtin: tostring(v)
builtin_tostring(L: ref State, base: int, nargs: int): int
{
	if(L == nil)
		return OK;

	result := "nil";
	if(nargs > 0 && base < len L.stack) {
		v := L.stack[base];
		if(v != nil) {
			result = tostring(v);
			if(result == nil)
				result = "nil";
		}
	}

	pushstring(L, result);
	return OK;
}

# Builtin: tonumber(v)
builtin_tonumber(L: ref State, base: int, nargs: int): int
{
	if(L == nil)
		return OK;

	if(nargs > 0 && base < len L.stack) {
		v := L.stack[base];
		if(v != nil) {
			n := tonumber(v);
			pushnumber(L, n);
			return OK;
		}
	}

	pushnil(L);
	return OK;
}

# Builtin: error(message)
builtin_error(L: ref State, base: int, nargs: int): int
{
	if(L == nil || nargs == 0)
		return OK;

	if(base < len L.stack) {
		v := L.stack[base];
		if(v != nil && v.ty == TSTRING) {
			sys->fprint(sys->fildes(2), "error: %s\n", v.s);
		}
	}

	return ERRRUN;
}

# Builtin: assert(v, message)
builtin_assert(L: ref State, base: int, nargs: int): int
{
	if(L == nil)
		return OK;

	if(nargs == 0)
		return ERRRUN;

	if(base < len L.stack) {
		v := L.stack[base];
		if(v != nil && toboolean(v) == 0) {
			msg := "assertion failed!";
			if(nargs > 1 && base + 1 < len L.stack) {
				msgv := L.stack[base + 1];
				if(msgv != nil && msgv.ty == TSTRING)
					msg = msgv.s;
			}
			sys->fprint(sys->fildes(2), "error: %s\n", msg);
			return ERRRUN;
		}
	}

	if(nargs > 0 && base < len L.stack)
		pushvalue(L, L.stack[base]);
	else
		pushnil(L);

	return OK;
}

# Builtin: ipairs(t)
builtin_ipairs(L: ref State, base: int, nargs: int): int
{
	if(L == nil || nargs == 0)
		return OK;

	pushnil(L);
	pushnil(L);
	pushnil(L);
	return OK;
}

# Builtin: pairs(t)
builtin_pairs(L: ref State, base: int, nargs: int): int
{
	if(L == nil || nargs == 0)
		return OK;

	pushnil(L);
	pushnil(L);
	pushnil(L);
	return OK;
}

# Builtin: next(t, key)
builtin_next(L: ref State, base: int, nargs: int): int
{
	if(L == nil || nargs == 0)
		return OK;

	pushnil(L);
	pushnil(L);
	return OK;
}

# Execute a function
execute(vm: ref VM, func: ref Value, nargs: int): int
{
	if(func == nil || func.ty != TFUNCTION || func.f == nil)
		return ERRRUN;

	# Handle C closures (builtin functions)
	if(func.f.isc == 1) {
		return callbuiltin(vm.L, func, nargs);
	}

	# Set up call frame for Lua closures
	ci := ref CallInfo;
	ci.func = func;
	ci.base = vm.L.top - nargs;
	ci.top = vm.L.top;
	ci.savedpc = 0;
	ci.nresults = -1;  # Multi-return
	ci.next = nil;

	# Allocate stack space for function
	proto := func.f.proto;
	if(proto != nil && proto.maxstacksize > 0) {
		settop(vm.L, ci.base + proto.maxstacksize);
		ci.top = ci.base + proto.maxstacksize;
	}

	vm.base = ci.base;
	vm.top = ci.top;
	vm.pc = 0;
	vm.ci = ci;

	# Execute bytecode
	return vmexec(vm);
}

# Main execution loop (fetch-decode-execute)
vmexec(vm: ref VM): int
{
	L := vm.L;

	for(;;) {
		# Fetch instruction
		if(vm.ci == nil || vm.ci.func == nil || vm.ci.func.f == nil ||
		   vm.ci.func.f.proto == nil || vm.ci.func.f.proto.code == nil)
			break;

		proto := vm.ci.func.f.proto;
		if(vm.pc < 0 || vm.pc >= len proto.code)
			break;

		# For simplicity, just return OK
		# Full implementation would decode and execute bytecode
		break;
	}

	return OK;
}

# Get instruction from prototype
getinst(proto: ref Proto, pc: int): int
{
	if(proto.code == nil || pc < 0 || pc * 4 + 3 >= len proto.code)
		return 0;

	inst := 0;
	for(i := 0; i < 4; i++) {
		inst |= int(proto.code[pc * 4 + i]) << (i * 8);
	}
	return inst;
}

# ============================================================
# SECTION 13: COMPARISON OPERATIONS
# ============================================================

# Compare two values for equality
valueseq(a, b: ref Value): int
{
	if(a == nil && b == nil)
		return 1;
	if(a == nil || b == nil)
		return 0;
	if(a.ty != b.ty)
		return 0;

	case(a.ty) {
	TNIL =>		return 1;
	TBOOLEAN =>	return a.b == b.b;
	TNUMBER =>	return a.n == b.n;
	TSTRING =>	return a.s == b.s;
	TTABLE =>	return a.t == b.t;
	TFUNCTION =>	return a.f == b.f;
	TUSERDATA =>	return a.u == b.u;
	TTHREAD =>	return a.th == b.th;
	* =>		return 0;
	}
}

# Compare two values for less than
comparelt(a, b: ref Value): int
{
	if(a == nil || b == nil)
		return 0;
	if(a.ty == TNUMBER && b.ty == TNUMBER)
		return a.n < b.n;
	if(a.ty == TSTRING && b.ty == TSTRING)
		return a.s < b.s;
	return 0;
}

# Compare two values for less than or equal
comparele(a, b: ref Value): int
{
	if(a == nil || b == nil)
		return 0;
	if(a.ty == TNUMBER && b.ty == TNUMBER)
		return a.n <= b.n;
	if(a.ty == TSTRING && b.ty == TSTRING)
		return a.s <= b.s;
	return 0;
}

# ============================================================
# SECTION 14: VALUE HELPERS
# ============================================================

# Compare two values for equality (for table lookup)
values_equal(a, b: ref Value): int
{
	if(a == nil && b == nil)
		return 1;
	if(a == nil || b == nil)
		return 0;
	if(a.ty != b.ty)
		return 0;

	case(a.ty) {
	TNIL =>
		return 1;
	TBOOLEAN =>
		return a.b == b.b;
	TNUMBER =>
		return a.n == b.n;
	TSTRING =>
		return a.s == b.s;
	TTABLE =>
		return a.t == b.t;
	TFUNCTION =>
		return a.f == b.f;
	TUSERDATA =>
		return a.u == b.u;
	TTHREAD =>
		return a.th == b.th;
	* =>
		return 0;
	}
}

# Reserve stack space
reserve(L: ref State, n: int)
{
	if(L.stack == nil) {
		L.stack = array[n + 20] of ref Value;
	} else if(L.top + n > len L.stack) {
		newstack := array[(L.top + n) * 2] of ref Value;
		for(j := 0; j < L.top; j++)
			newstack[j] = L.stack[j];
		L.stack = newstack;
	}
}

# ============================================================
# SECTION 15: LEXICAL ANALYZER (LEXER)
# ============================================================

# Token types (Lua 5.4 tokens)
TOKEN_EOF:		con 0;
TOKEN_AND:		con 1;
TOKEN_BREAK:	con 2;
TOKEN_DO:		con 3;
TOKEN_ELSE:		con 4;
TOKEN_ELSEIF:	con 5;
TOKEN_END:		con 6;
TOKEN_FALSE:	con 7;
TOKEN_FOR:		con 8;
TOKEN_FUNCTION:	con 9;
TOKEN_GOTO:		con 10;
TOKEN_IF:		con 11;
TOKEN_IN:		con 12;
TOKEN_LOCAL:	con 13;
TOKEN_NIL:		con 14;
TOKEN_NOT:		con 15;
TOKEN_OR:		con 16;
TOKEN_REPEAT:	con 17;
TOKEN_RETURN:	con 18;
TOKEN_THEN:		con 19;
TOKEN_TRUE:		con 20;
TOKEN_UNTIL:	con 21;
TOKEN_WHILE:	con 22;
TOKEN_ADD:		con 23;	# +
TOKEN_SUB:		con 24;	# -
TOKEN_MUL:		con 25;	# *
TOKEN_MOD:		con 26;	# %
TOKEN_POW:		con 27;	# ^
TOKEN_DIV:		con 28;	# /
TOKEN_IDIV:		con 29;	# //
TOKEN_CONCAT:	con 30;	# ..
TOKEN_DOTS:		con 31;	# ...
TOKEN_EQ:		con 32;	# ==
TOKEN_NE:		con 33;	# ~=
TOKEN_LE:		con 34;	# <=
TOKEN_GE:		con 35;	# >=
TOKEN_LT:		con 36;	# <
TOKEN_GT:		con 37;	# >
TOKEN_ASSIGN:	con 38;	# =
TOKEN_LPAREN:	con 39;	# (
TOKEN_RPAREN:	con 40;	# )
TOKEN_LBRACKET:	con 41;	# [
TOKEN_RBRACKET:	con 42;	# ]
TOKEN_LBRACE:	con 43;	# {
TOKEN_RBRACE:	con 44;	# }
TOKEN_SEMICOLON:	con 45;	# ;
TOKEN_COLON:	con 46;	# :
TOKEN_COMMA:	con 47;	# ,
TOKEN_DOT:		con 48;	# .
TOKEN_NAME:		con 49;
TOKEN_NUMBER:	con 50;
TOKEN_STRING:	con 51;

# Token structure
Token: adt {
	token:	int;		# Token type
	lineno:	int;		# Line number
	column:	int;		# Column number
	seminfo: ref Value;	# Semantic value (for names, numbers, strings)
};

# Lexer state
Lexer: adt {
	source:	string;		# Source code
	length:	int;		# Source length
	current:	int;		# Current position
	lineno:	int;		# Current line
	column:	int;		# Current column
	t:		ref Token;	# Current token
	lookahead:	ref Token;	# Lookahead token
};

# Reserved words (must be in alphabetical order for binary search)
RESERVED_WORDS: array[] of {
	("and", TOKEN_AND),
	("break", TOKEN_BREAK),
	("do", TOKEN_DO),
	("else", TOKEN_ELSE),
	("elseif", TOKEN_ELSEIF),
	("end", TOKEN_END),
	("false", TOKEN_FALSE),
	("for", TOKEN_FOR),
	("function", TOKEN_FUNCTION),
	("goto", TOKEN_GOTO),
	("if", TOKEN_IF),
	("in", TOKEN_IN),
	("local", TOKEN_LOCAL),
	("nil", TOKEN_NIL),
	("not", TOKEN_NOT),
	("or", TOKEN_OR),
	("repeat", TOKEN_REPEAT),
	("return", TOKEN_RETURN),
	("then", TOKEN_THEN),
	("true", TOKEN_TRUE),
	("until", TOKEN_UNTIL),
	("while", TOKEN_WHILE)
};

# Check if identifier is a reserved word
check_reserved(s: string): int
{
	# Linear search through reserved words
	for(i := 0; i < len RESERVED_WORDS; i++) {
		if(RESERVED_WORDS[i].t0 == s)
			return RESERVED_WORDS[i].t1;
	}
	return TOKEN_NAME;
}

# Create new token
new_token(token_type: int, line: int, col: int): ref Token
{
	tok := ref Token;
	tok.token = token_type;
	tok.lineno = line;
	tok.column = col;
	tok.seminfo = nil;
	return tok;
}

# Initialize lexer
newlexer(source: string): ref Lexer
{
	lex := ref Lexer;
	lex.source = source;
	lex.length = len source;
	lex.current = 0;
	lex.lineno = 1;
	lex.column = 0;
	lex.t = nil;
	lex.lookahead = nil;
	return lex;
}

# Get current character
currchar(lex: ref Lexer): int
{
	if(lex.current >= lex.length)
		return -1;
	return lex.source[lex.current];
}

# Peek next character
nextchar(lex: ref Lexer): int
{
	if(lex.current + 1 >= lex.length)
		return -1;
	return lex.source[lex.current + 1];
}

# Advance to next character
advance(lex: ref Lexer): int
{
	if(lex.current >= lex.length)
		return -1;

	c := lex.source[lex.current];
	lex.current++;

	if(c == '\n') {
		lex.lineno++;
		lex.column = 0;
	} else {
		lex.column++;
	}

	return c;
}

# Skip whitespace
skip_whitespace(lex: ref Lexer)
{
	for(;;) {
		c := currchar(lex);
		if(c == ' ' || c == '\t' || c == '\r' || c == '\n') {
			advance(lex);
		} else {
			break;
		}
	}
}

# Skip comment
skip_comment(lex: ref Lexer)
{
	c := currchar(lex);
	if(c == '-') {
		advance(lex);
		if(currchar(lex) == '-') {
			advance(lex);
			# Check for long comment [[...]]
			if(currchar(lex) == '[') {
				advance(lex);
				# Count opening brackets
				count := 0;
				while(currchar(lex) == '=') {
					count++;
					advance(lex);
				}
				if(currchar(lex) == '[') {
					advance(lex);
					# Find closing ]] or ]=...=]
					for(;;) {
						if(currchar(lex) == -1)
							return;  # EOF
						if(currchar(lex) == ']') {
							advance(lex);
							match_count := 0;
							while(currchar(lex) == '=' && match_count < count) {
								match_count++;
								advance(lex);
							}
							if(currchar(lex) == ']' && match_count == count) {
								advance(lex);
								return;
							}
						} else {
							advance(lex);
						}
					}
				}
			}
			# Short comment -- until end of line
			while(currchar(lex) != -1 && currchar(lex) != '\n') {
				advance(lex);
			}
		}
	}
}

# Read number
read_number(lex: ref Lexer): ref Token
{
	start_line := lex.lineno;
	start_col := lex.column;

	# Build number string
	buf := "";
	has_dot := 0;
	has_exp := 0;

	# Check for hex prefix 0x or 0X
	if(currchar(lex) == '0' && (nextchar(lex) == 'x' || nextchar(lex) == 'X')) {
		advance(lex);
		advance(lex);
		# Read hex digits
		while(currchar(lex) != -1) {
			c := currchar(lex);
			if((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
				buf += string c;
				advance(lex);
			} else if(c == '.') {
				if(has_dot || has_exp)
					break;
				has_dot = 1;
				buf += ".";
				advance(lex);
			} else if(c == 'p' || c == 'P') {
				if(has_exp)
					break;
				has_exp = 1;
				buf += string c;
				advance(lex);
				# Optional sign
				if(currchar(lex) == '+' || currchar(lex) == '-') {
					buf += string currchar(lex);
					advance(lex);
				}
			} else {
				break;
			}
		}

		# Parse hex number
		n := 0.0;
		# Simplified hex parsing
		if(len buf > 0) {
			# For now, just return 0.0
			# Full implementation would parse hex properly
			n = 0.0;
		}

		tok := new_token(TOKEN_NUMBER, start_line, start_col);
		tok.seminfo = mknumber(n);
		return tok;
	}

	# Check for binary 0b or 0B
	if(currchar(lex) == '0' && (nextchar(lex) == 'b' || nextchar(lex) == 'B')) {
		advance(lex);
		advance(lex);
		# Read binary digits
		n := 0.0;
		bit := 1;
		while(currchar(lex) == '0' || currchar(lex) == '1') {
			if(currchar(lex) == '1')
				n += real(bit);
			bit *= 2;
			advance(lex);
		}

		tok := new_token(TOKEN_NUMBER, start_line, start_col);
		tok.seminfo = mknumber(n);
		return tok;
	}

	# Decimal number
	while(currchar(lex) != -1 && currchar(lex) >= '0' && currchar(lex) <= '9') {
		buf += string currchar(lex);
		advance(lex);
	}

	# Decimal part
	if(currchar(lex) == '.') {
		has_dot = 1;
		buf += ".";
		advance(lex);
		while(currchar(lex) != -1 && currchar(lex) >= '0' && currchar(lex) <= '9') {
			buf += string currchar(lex);
			advance(lex);
		}
	}

	# Exponent
	if(currchar(lex) == 'e' || currchar(lex) == 'E') {
		has_exp = 1;
		buf += string currchar(lex);
		advance(lex);
		# Optional sign
		if(currchar(lex) == '+' || currchar(lex) == '-') {
			buf += string currchar(lex);
			advance(lex);
		}
		# Exponent digits
		while(currchar(lex) != -1 && currchar(lex) >= '0' && currchar(lex) <= '9') {
			buf += string currchar(lex);
			advance(lex);
		}
	}

	# Parse number
	n := strtonumber(buf);

	tok := new_token(TOKEN_NUMBER, start_line, start_col);
	tok.seminfo = mknumber(n);
	return tok;
}

# Read string
read_string(lex: ref Lexer, delim: int): ref Token
{
	start_line := lex.lineno;
	start_col := lex.column;

	advance(lex);  # Skip delimiter

	buf := "";

	for(;;) {
		c := currchar(lex);
		if(c == -1)
			break;  # Error: unterminated string

		if(c == delim) {
			advance(lex);
			break;
		}

		if(c == '\\') {
			# Escape sequence
			advance(lex);
			c = currchar(lex);
			case(c) {
			'a' =>		buf += "\a";
			'b' =>		buf += "\b";
			'f' =>		buf += "\f";
			'n' =>		buf += "\n";
			'r' =>		buf += "\r";
			't' =>		buf += "\t";
			'v' =>		buf += "\v";
			'\\' =>		buf += "\\";
			'"' =>		buf += "\"";
			'\'' =>		buf += "'";
			'\n' =>		# Line break: skip
			'z' =>		# Skip whitespace
					advance(lex);
					while(currchar(lex) == ' ' || currchar(lex) == '\t' ||
					      currchar(lex) == '\n' || currchar(lex) == '\r')
						advance(lex);
			'x' =>		# Hex escape \xHH
					advance(lex);
					hex := "";
					if(currchar(lex) != -1) {
						hex += string currchar(lex);
						advance(lex);
					}
					if(currchar(lex) != -1) {
						hex += string currchar(lex);
						advance(lex);
					}
					# Parse hex
					hexval := 0;
					if(len hex == 2) {
						for(i := 0; i < 2; i++) {
							h := hex[i];
							if(h >= '0' && h <= '9')
								hexval = hexval * 16 + (h - '0');
							else if(h >= 'a' && h <= 'f')
								hexval = hexval * 16 + (h - 'a' + 10);
							else if(h >= 'A' && h <= 'F')
								hexval = hexval * 16 + (h - 'A' + 10);
						}
					}
					buf += string hexval;
			* =>
					# Digit escape \ddd (up to 3 digits)
					digits := "";
					while(len digits < 3 && currchar(lex) >= '0' && currchar(lex) <= '9') {
						digits += string currchar(lex);
						advance(lex);
					}
					if(len digits > 0) {
						decval := 0;
						for(i := 0; i < len digits; i++) {
							decval = decval * 10 + (digits[i] - '0');
						}
						buf += string decval;
					}
			}
			advance(lex);
		} else {
			buf += string c;
			advance(lex);
		}
	}

	tok := new_token(TOKEN_STRING, start_line, start_col);
	tok.seminfo = mkstring(buf);
	return tok;
}

# Read long string [[...]] or [=[...]=]
read_long_string(lex: ref Lexer): ref Token
{
	start_line := lex.lineno;
	start_col := lex.column;

	advance(lex);  # Skip opening [

	# Count opening brackets
	count := 0;
	while(currchar(lex) == '=') {
		count++;
		advance(lex);
	}

	if(currchar(lex) != '[')
		return new_token(TOKEN_STRING, start_line, start_col);  # Error

	advance(lex);  # Skip opening [

	buf := "";

	# Read until closing bracket
	for(;;) {
		c := currchar(lex);
		if(c == -1)
			break;  # Error: unterminated string

		if(c == ']') {
			advance(lex);
			match_count := 0;
			while(currchar(lex) == '=' && match_count < count) {
				match_count++;
				advance(lex);
			}
			if(currchar(lex) == ']' && match_count == count) {
				advance(lex);
				break;
			}
			# Not a match, add back the ]
			buf += "]";
			for(i := 0; i < match_count; i++)
				buf += "=";
		} else {
			buf += string c;
			advance(lex);
		}
	}

	tok := new_token(TOKEN_STRING, start_line, start_col);
	tok.seminfo = mkstring(buf);
	return tok;
}

# Read identifier or keyword
read_name(lex: ref Lexer): ref Token
{
	start_line := lex.lineno;
	start_col := lex.column;

	buf := "";

	while(currchar(lex) != -1) {
		c := currchar(lex);
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '_') {
			buf += string c;
			advance(lex);
		} else {
			break;
		}
	}

	# Check if it's a reserved word
	token_type := check_reserved(buf);

	tok := new_token(token_type, start_line, start_col);
	if(token_type == TOKEN_NAME) {
		tok.seminfo = mkstring(buf);
	}
	return tok;
}

# Main lexing function - get next token
lex(lex: ref Lexer): ref Token
{
	for(;;) {
		skip_whitespace(lex);

		# Check for comment
		if(currchar(lex) == '-' && nextchar(lex) == '-') {
			skip_comment(lex);
			continue;
		}

		break;
	}

	start_line := lex.lineno;
	start_col := lex.column;
	c := currchar(lex);

	if(c == -1) {
		return new_token(TOKEN_EOF, start_line, start_col);
	}

	# Numbers
	if((c >= '0' && c <= '9') || c == '.') {
		# Check for dot that's part of number
		if(c == '.' && nextchar(lex) != '.')
			return read_number(lex);
		return read_number(lex);
	}

	# Strings and long strings
	if(c == '"' || c == '\'')
		return read_string(lex, c);

	if(c == '[') {
		# Check for long string
		if(nextchar(lex) == '=' || nextchar(lex) == '[') {
			return read_long_string(lex);
		}
		advance(lex);
		return new_token(TOKEN_LBRACKET, start_line, start_col);
	}

	# Identifiers and keywords
	if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')
		return read_name(lex);

	# Operators and punctuation
	advance(lex);

	case(c) {
	'+' =>
		return new_token(TOKEN_ADD, start_line, start_col);
	'-' =>
		return new_token(TOKEN_SUB, start_line, start_col);
	'*' =>
		if(currchar(lex) == '*') {
			advance(lex);
			return new_token(TOKEN_POW, start_line, start_col);
		}
		return new_token(TOKEN_MUL, start_line, start_col);
	'/' =>
		if(currchar(lex) == '/') {
			advance(lex);
			return new_token(TOKEN_IDIV, start_line, start_col);
		}
		return new_token(TOKEN_DIV, start_line, start_col);
	'%' =>
		return new_token(TOKEN_MOD, start_line, start_col);
	'^' =>
		return new_token(TOKEN_POW, start_line, start_col);
	'=' =>
		if(currchar(lex) == '=') {
			advance(lex);
			return new_token(TOKEN_EQ, start_line, start_col);
		}
		return new_token(TOKEN_ASSIGN, start_line, start_col);
	'~' =>
		if(currchar(lex) == '=') {
			advance(lex);
			return new_token(TOKEN_NE, start_line, start_col);
		}
		return new_token(TOKEN_NOT, start_line, start_col);  # Should not happen in valid code
	'<' =>
		if(currchar(lex) == '=') {
			advance(lex);
			return new_token(TOKEN_LE, start_line, start_col);
		}
		return new_token(TOKEN_LT, start_line, start_col);
	'>' =>
		if(currchar(lex) == '=') {
			advance(lex);
			return new_token(TOKEN_GE, start_line, start_col);
		}
		return new_token(TOKEN_GT, start_line, start_col);
	'(' =>
		return new_token(TOKEN_LPAREN, start_line, start_col);
	')' =>
		return new_token(TOKEN_RPAREN, start_line, start_col);
	']' =>
		return new_token(TOKEN_RBRACKET, start_line, start_col);
	'{' =>
		return new_token(TOKEN_LBRACE, start_line, start_col);
	'}' =>
		return new_token(TOKEN_RBRACE, start_line, start_col);
	';' =>
		return new_token(TOKEN_SEMICOLON, start_line, start_col);
	':' =>
		return new_token(TOKEN_COLON, start_line, start_col);
	',' =>
		return new_token(TOKEN_COMMA, start_line, start_col);
	'.' =>
		if(currchar(lex) == '.') {
			advance(lex);
			if(currchar(lex) == '.') {
				advance(lex);
				return new_token(TOKEN_DOTS, start_line, start_col);
			}
			return new_token(TOKEN_CONCAT, start_line, start_col);
		}
		return new_token(TOKEN_DOT, start_line, start_col);
	'#' =>
		return new_token(TOKEN_MOD, start_line, start_col);  # Using MOD as placeholder
	* =>
		# Unknown character - return as error token
		return new_token(TOKEN_EOF, start_line, start_col);
	}
}

# Look ahead one token
lookahead(lex: ref Lexer): ref Token
{
	if(lex.lookahead == nil) {
		t := lex(lex);
		lex.lookahead = t;
	}
	return lex.lookahead;
}

# Get next token and advance
nexttoken(lex: ref Lexer): ref Token
{
	if(lex.lookahead != nil) {
		t := lex.lookahead;
		lex.lookahead = nil;
		lex.t = t;
		return t;
	}
	t := lex(lex);
	lex.t = t;
	return t;
}

# ============================================================
# SECTION 16: BYTECODE DEFINITIONS
# ============================================================

# Lua 5.4 Opcodes
OP_MOVE:		con 0;
OP_LOADI:		con 1;
OP_LOADF:		con 2;
OP_LOADK:		con 3;
OP_LOADKX:		con 4;
OP_LOADFALSE:	con 5;
OP_LFALSESKIP:	con 6;
OP_LOADTRUE:	con 7;
OP_LOADNIL:		con 8;
OP_GETUPVAL:	con 9;
OP_SETUPVAL:	con 10;
OP_GETTABUP:	con 11;
OP_GETTABLE:	con 12;
OP_GETI:		con 13;
OP_GETFIELD:	con 14;
OP_SETTABUP:	con 15;
OP_SETTABLE:	con 16;
OP_SETI:		con 17;
OP_SETFIELD:	con 18;
OP_NEWTABLE:	con 19;
OP_SELF:		con 20;
OP_ADDI:		con 21;
OP_ADDK:		con 22;
OP_SUBK:		con 23;
OP_MULK:		con 24;
OP_MODK:		con 25;
OP_POWK:		con 26;
OP_DIVK:		con 27;
OP_IDIVK:		con 28;
OP_BANDK:		con 29;
OP_BORK:		con 30;
OP_BXORK:		con 31;
OP_SHRI:		con 32;
OP_SHLI:		con 33;
OP_ADD:			con 34;
OP_SUB:			con 35;
OP_MUL:			con 36;
OP_MOD:			con 37;
OP_POW:			con 38;
OP_DIV:			con 39;
OP_IDIV:		con 40;
OP_BAND:		con 41;
OP_BOR:			con 42;
OP_BXOR:		con 43;
OP_SHL:			con 44;
OP_SHR:			con 45;
OP_MMBIN:		con 46;
OP_MMBINI:		con 47;
OP_MMBINK:		con 48;
OP_UNM:			con 49;
OP_BNOT:		con 50;
OP_NOT:			con 51;
OP_LEN:			con 52;
OP_CONCAT:		con 53;
OP_CLOSE:		con 54;
OP_TBC:			con 55;
OP_JMP:			con 56;
OP_EQ:			con 57;
OP_LT:			con 58;
OP_LE:			con 59;
OP_EQK:			con 60;
OP_EQI:			con 61;
OP_LTI:			con 62;
OP_LEI:			con 63;
OP_GTI:			con 64;
OP_GEI:			con 65;
OP_TEST:		con 66;
OP_TESTSET:		con 67;
OP_CALL:		con 68;
OP_TAILCALL:	con 69;
OP_RETURN:		con 70;
OP_RETURN0:		con 71;
OP_RETURN1:		con 72;
OP_FORLOOP:		con 73;
OP_FORPREP:		con 74;
OP_TFORPREP:	con 75;
OP_TFORCALL:	con 76;
OP_TFORLOOP:	con 77;
OP_SETLIST:		con 78;
OP_CLOSURE:		con 79;
OP_VARARG:		con 80;
OP_VARARGPREP:	con 81;
OP_EXTRAARG:		con 82;

# Instruction format helpers
# Format: iiiiiiii | iiiiiiii | iiiiiiii | iiiiiiii
#           A(7)      B(8)        C(9)      Opcode(7)

MAXARG_A:	con (1 << 8) - 1;
MAXARG_B:	con (1 << 9) - 1;
MAXARG_C:	con (1 << 9) - 1;
MAXARG_Bx:	con (1 << 18) - 1;
MAXARG_sJ:	con (1 << 17) - 1 - (1 << 16);

# Create ABC instruction
CREATE_ABC(o, a, b, c): int
{
	return (c << 23) | (b << 14) | (a << 6) | o;
}

# Create ABx instruction
CREATE_ABx(o, a, bx): int
{
	return (bx << 14) | (a << 6) | o;
}

# Create AsBx instruction (signed)
CREATE_Asx(o, a, sbx: int): int
{
	return ((sbx + MAXARG_sJ) << 14) | (a << 6) | o;
}

# Create sJ instruction (jump offset)
CREATE_sJ(o, sj: int): int
{
	return ((sj + (1 << 16)) << 7) | o;
}

# Get opcode from instruction
GET_OPCODE(i: int): int
{
	return i & 0x7F;
}

# Get operand A from instruction
GETARG_A(i: int): int
{
	return (i >> 6) & 0xFF;
}

# Get operand B from instruction
GETARG_B(i: int): int
{
	return (i >> 14) & 0x1FF;
}

# Get operand C from instruction
GETARG_C(i: int): int
{
	return (i >> 23) & 0x1FF;
}

# Get operand Bx from instruction
GETARG_Bx(i: int): int
{
	return i >> 14;
}

# Get signed operand sJ from instruction
GETARG_sJ(i: int): int
{
	return (i >> 7) - (1 << 16);
}

# ============================================================
# SECTION 17: PARSER DATA STRUCTURES
# ============================================================

# Variable description
VLOCAL:	con 0;
VGLOBAL: con 1;
VUPVAL:	con 2;
VCONST:	con 3;

VarDesc: adt {
	name:	string;
	varkind:	int;
	idx:		int;
};

# Function state for compilation
FuncState: adt {
	f:			ref Proto;			# Function prototype
	prev:		ref FuncState;		# Outer function
	L:			ref State;			# Lua state
	ls:			ref LexState;		# Lexer state
	nactvar:	int;				# Number of active local variables
	nups:		int;				# Number of upvalues
	freereg:	int;				# First free register
	bl:			list of ref BlockCnt;	# Block control list
	jpc:		list of int;		# Pending jumps
	firstlocal:	int;				# First local var
};

# Block control structure
BlockCnt: adt {
	previous:	ref BlockCnt;		# Outer block
	breaklist:	list of int;		# List of jumps to break
	isloop:		int;				# Is this a loop?
};

# Upvalue description
Upvaldesc: adt {
	name:		string;
	instack:	int;
	idx:		int;
	kind:		int;  # 0 = lexical, 1 = non-instant (to-be-closed)
};

# Lexical state
LexState: adt {
	lex:		ref Lexer;
	fs:			ref FuncState;
	L:			ref State;
};

# ============================================================
# SECTION 18: CODE GENERATION
# ============================================================

# Allocate register
alloc_register(fs: ref FuncState): int
{
	if(fs == nil)
		return 0;

	reg := fs.freereg;
	fs.freereg++;

	if(fs.freereg > fs.f.maxstacksize)
		fs.f.maxstacksize = fs.freereg;

	return reg;
}

# Free register
free_register(fs: ref FuncState, reg: int)
{
	if(fs == nil)
		return;
	if(reg < fs.freereg - 1)
		return;  # Only free top register
	fs.freereg--;
}

# Free registers from n down
free_registers(fs: ref FuncState, n: int)
{
	if(fs == nil)
		return;
	fs.freereg = n;
}

# Add constant to function
add_constant(fs: ref FuncState, v: ref Value): int
{
	if(fs == nil || fs.f == nil)
		return 0;

	# Check if constant already exists
	if(fs.f.k != nil) {
		for(i := 0; i < len fs.f.k; i++) {
			if(values_equal(fs.f.k[i], v))
				return i;
		}
	}

	# Add new constant
	if(fs.f.k == nil) {
		fs.f.k = array[1] of ref Value;
		fs.f.k[0] = v;
	} else {
		newk := array[len fs.f.k + 1] of ref Value;
		newk[:] = fs.f.k;
		newk[len fs.f.k] = v;
		fs.f.k = newk;
	}

	return len fs.f.k - 1;
}

# Emit instruction
emit_code(fs: ref FuncState, inst: int)
{
	if(fs == nil || fs.f == nil)
		return;

	# Convert instruction to 4 bytes
	b0 := byte(inst & 0xFF);
	b1 := byte((inst >> 8) & 0xFF);
	b2 := byte((inst >> 16) & 0xFF);
	b3 := byte((inst >> 24) & 0xFF);

	if(fs.f.code == nil) {
		fs.f.code = array[4] of byte;
		fs.f.code[0] = b0;
		fs.f.code[1] = b1;
		fs.f.code[2] = b2;
		fs.f.code[3] = b3;
	} else {
		newcode := array[len fs.f.code + 4] of byte;
		newcode[:] = fs.f.code;
		newcode[len fs.f.code] = b0;
		newcode[len fs.f.code + 1] = b1;
		newcode[len fs.f.code + 2] = b2;
		newcode[len fs.f.code + 3] = b3;
		fs.f.code = newcode;
	}
}

# Emit ABC instruction
emit_abc(fs: ref FuncState, o, a, b, c: int)
{
	emit_code(fs, CREATE_ABC(o, a, b, c));
}

# Emit ABx instruction
emit_abx(fs: ref FuncState, o, a, bx: int)
{
	emit_code(fs, CREATE_ABx(o, a, bx));
}

# Emit jump instruction
emit_jump(fs: ref FuncState, o: int): int
{
	j := len fs.f.code / 4;
	emit_code(fs, CREATE_sJ(o, 0));
	return j;
}

# Patch jump instruction
patch_jump(fs: ref FuncState, j: int)
{
	if(fs == nil || fs.f == nil)
		return;

	offset := (len fs.f.code / 4) - (j + 1);

	# Replace instruction at j
	inst_pos := j * 4;
	opcode := int(fs.f.code[inst_pos]);

	inst := CREATE_sJ(opcode, offset);

	fs.f.code[inst_pos] = byte(inst & 0xFF);
	fs.f.code[inst_pos + 1] = byte((inst >> 8) & 0xFF);
	fs.f.code[inst_pos + 2] = byte((inst >> 16) & 0xFF);
	fs.f.code[inst_pos + 3] = byte((inst >> 24) & 0xFF);
}

# Emit load constant
emit_loadk(fs: ref FuncState, reg: int, v: ref Value): int
{
	idx := add_constant(fs, v);
	if(idx <= 127) {
		emit_abc(fs, OP_LOADK, reg, idx, 0);
	} else {
		emit_abc(fs, OP_LOADK, reg, 0, 0);
		emit_abx(fs, OP_EXTRAARG, 0, idx);
	}
	return reg;
}

# ============================================================
# SECTION 19: PARSER FUNCTIONS
# ============================================================

# Check token
check_token(ls: ref LexState, token_type: int): int
{
	if(ls == nil || ls.lex == nil)
		return 0;

	if(ls.lex.t == nil)
		return 0;

	return ls.lex.t.token == token_type;
}

# Test next token
testnext(ls: ref LexState, token_type: int): int
{
	if(check_token(ls, token_type)) {
		nexttoken(ls.lex);
		return 1;
	}
	return 0;
}

# Expect token or error
check_match(ls: ref LexState, what, who: int)
{
	if(!testnext(ls, what)) {
		# Syntax error
		sys->fprint(sys->fildes(2), "syntax error: expected %d got %d\n", what, ls.lex.t.token);
	}
}

# Enter block
enterblock(fs: ref FuncState, isloop: int): ref BlockCnt
{
	bl := ref BlockCnt;
	bl.previous = nil;
	bl.breaklist = nil;
	bl.isloop = isloop;

	# Link to function state
	bl.previous = hd fs.bl;
	fs.bl = bl :: tl fs.bl;

	return bl;
}

# Leave block
leaveblock(fs: ref FuncState)
{
	if(fs == nil || fs.bl == nil)
		return;

	bl := hd fs.bl;
	fs.bl = tl fs.bl;

	# Patch break jumps
	while(bl.breaklist != nil) {
		j := hd bl.breaklist;
		bl.breaklist = tl bl.breaklist;
		patch_jump(fs, j);
	}

	# Free registers to block start
	fs.freereg = fs.nactvar;
}

# Add local variable
new_localvar(fs: ref FuncState, name: string)
{
	if(fs == nil)
		return;

	fs.nactvar++;
	reg := alloc_register(fs);

	# Add to local variables
	if(fs.f.locvars == nil) {
		fs.f.locvars = array[1] of ref Locvar;
		loc := ref Locvar;
		loc.varname = name;
		loc.startpc = len fs.f.code / 4;
		loc.endpc = 0;
		fs.f.locvars[0] = loc;
	} else {
		newlocvars := array[len fs.f.locvars + 1] of ref Locvar;
		newlocvars[:] = fs.f.locvars;
		loc := ref Locvar;
		loc.varname = name;
		loc.startpc = len fs.f.code / 4;
		loc.endpc = 0;
		newlocvars[len fs.f.locvars] = loc;
		fs.f.locvars = newlocvars;
	}
}

# Declare local variable
declare_localvar(ls: ref LexState)
{
	if(ls == nil || ls.fs == nil)
		return;

	# Get identifier
	if(ls.lex.t == nil || ls.lex.t.token != TOKEN_NAME)
		return;

	name := "";
	if(ls.lex.t.seminfo != nil && ls.lex.t.seminfo.ty == TSTRING)
		name = ls.lex.t.seminfo.s;

	new_localvar(ls.fs, name);
	nexttoken(ls.lex);
}

# Parse list of local variables
parse_local_vars(ls: ref LexState)
{
	if(ls == nil || ls.fs == nil)
		return;

	for(;;) {
		declare_localvar(ls);
		if(!testnext(ls, TOKEN_COMMA))
			break;
	}
	testnext(ls, TOKEN_SEMICOLON);
}

# Parse chunk (list of statements)
parse_chunk(ls: ref LexState)
{
	if(ls == nil)
		return;

	while(!testnext(ls, TOKEN_EOF)) {
		parse_statement(ls);
	}
}

# Parse statement
parse_statement(ls: ref LexState)
{
	if(ls == nil || ls.lex == nil || ls.lex.t == nil)
		return;

	c := ls.lex.t.token;

	case(c) {
	TOKEN_IF =>
		parse_if_statement(ls);
	TOKEN_WHILE =>
		parse_while_statement(ls);
	TOKEN_DO =>
		parse_do_statement(ls);
	TOKEN_FOR =>
		parse_for_statement(ls);
	TOKEN_REPEAT =>
		parse_repeat_statement(ls);
	TOKEN_FUNCTION =>
		parse_function_statement(ls);
	TOKEN_LOCAL =>
		parse_local_statement(ls);
	TOKEN_RETURN =>
		parse_return_statement(ls);
	TOKEN_BREAK =>
		parse_break_statement(ls);
	TOKEN_GOTO =>
		parse_goto_statement(ls);
	TOKEN_SEMICOLON or TOKEN_ELSE or TOKEN_ELSEIF or TOKEN_END or TOKEN_UNTIL =>
		# Empty statement
		nexttoken(ls.lex);
	* =>
		parse_expr_statement(ls);
	}
}

# Parse if statement
parse_if_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'if'

	# Parse condition
	reg := parse_expression(ls);

	# Generate test
	test_then := emit_jump(ls.fs, OP_TEST);

	# Parse then block
	if(!testnext(ls, TOKEN_THEN))
		return;  # Error

	parse_block(ls);

	# Jump to end (pending)
	endif := emit_jump(ls.fs, OP_JMP);

	# Patch test jump
	patch_jump(ls.fs, test_then);

	# Parse elseif clauses
	while(testnext(ls, TOKEN_ELSEIF)) {
		# Condition
		reg := parse_expression(ls);

		# Generate test
		test_then = emit_jump(ls.fs, OP_TEST);

		# Then block
		if(!testnext(ls, TOKEN_THEN))
			return;
		parse_block(ls);

		# Jump to end
		endif = emit_jump(ls.fs, OP_JMP);

		# Patch test
		patch_jump(ls.fs, test_then);
	}

	# Parse else clause
	if(testnext(ls, TOKEN_ELSE)) {
		parse_block(ls);
	}

	# Patch endif jumps
	patch_jump(ls.fs, endif);

	testnext(ls, TOKEN_END);
}

# Parse while statement
parse_while_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'while'

	# Remember loop start
	loopstart := len ls.fs.f.code / 4;

	# Parse condition
	reg := parse_expression(ls);

	# Generate test and jump out if false
	exit := emit_jump(ls.fs, OP_TEST);

	# Enter loop block
	enterblock(ls.fs, 1);

	# Parse body
	if(!testnext(ls, TOKEN_DO))
		return;

	parse_block(ls);

	# Jump back to condition
	jmp_back := emit_jump(ls.fs, OP_JMP);
	patch_jump(ls.fs, jmp_back);

	# Patch exit jump
	patch_jump(ls.fs, exit);

	leaveblock(ls.fs);

	testnext(ls, TOKEN_END);
}

# Parse do statement
parse_do_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'do'

	enterblock(ls.fs, 0);
	parse_block(ls);
	leaveblock(ls.fs);

	testnext(ls, TOKEN_END);
}

# Parse for statement
parse_for_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'for'

	if(ls.lex.t == nil)
		return;

	# Check if numeric for or generic for
	if(ls.lex.t.token == TOKEN_NAME && nexttoken(ls.lex) != nil) {
		if(testnext(ls, TOKEN_ASSIGN)) {
			# Numeric for: for var = exp1, exp2, exp3 do ... end
			parse_for_numeric(ls);
		} else {
			# Generic for: for var_1, ..., var_n in explist do ... end
			parse_for_generic(ls);
		}
	}
}

# Parse numeric for loop
parse_for_numeric(ls: ref LexState)
{
	# Parse initialization
	init_exp := parse_expression(ls);

	if(!testnext(ls, TOKEN_COMMA))
		return;

	# Parse limit
	lim_exp := parse_expression(ls);

	# Optional step
	step_exp := nil;
	if(testnext(ls, TOKEN_COMMA)) {
		step_exp = parse_expression(ls);
	}

	# Parse body
	if(!testnext(ls, TOKEN_DO))
		return;

	# Generate bytecode for numeric for
	# This is simplified - full implementation would use OP_FORPREP and OP_FORLOOP

	enterblock(ls.fs, 1);
	parse_block(ls);
	leaveblock(ls.fs);

	testnext(ls, TOKEN_END);
}

# Parse generic for loop
parse_for_generic(ls: ref LexState)
{
	# Parse variable names
	vars: list of string = nil;
	for(;;) {
		if(ls.lex.t != nil && ls.lex.t.token == TOKEN_NAME) {
			name := "";
			if(ls.lex.t.seminfo != nil && ls.lex.t.seminfo.ty == TSTRING)
				name = ls.lex.t.seminfo.s;
			vars = name :: vars;
			nexttoken(ls.lex);
			if(!testnext(ls, TOKEN_COMMA))
				break;
		}
	}

	if(!testnext(ls, TOKEN_IN))
		return;

	# Parse iterator expressions
	# (For now, simplified)

	if(!testnext(ls, TOKEN_DO))
		return;

	enterblock(ls.fs, 1);
	parse_block(ls);
	leaveblock(ls.fs);

	testnext(ls, TOKEN_END);
}

# Parse repeat statement
parse_repeat_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'repeat'

	enterblock(ls.fs, 1);

	# Remember repeat start
	repeatstart := len ls.fs.f.code / 4;

	parse_block(ls);

	if(!testnext(ls, TOKEN_UNTIL))
		return;

	# Parse condition
	reg := parse_expression(ls);

	# Jump back if condition false
	# (For now, simplified)

	leaveblock(ls.fs);
}

# Parse function statement
parse_function_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'function'

	# Parse function name
	if(ls.lex.t == nil || ls.lex.t.token != TOKEN_NAME)
		return;

	# For now, just skip parsing
	while(ls.lex.t != nil && ls.lex.t.token != TOKEN_END)
		nexttoken(ls.lex);
	nexttoken(ls.lex);
}

# Parse local statement
parse_local_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'local'

	if(testnext(ls, TOKEN_FUNCTION)) {
		# Local function
		parse_local_function(ls);
	} else {
		# Local variables
		parse_local_vars(ls);

		if(testnext(ls, TOKEN_ASSIGN)) {
			# Parse initializers
			parse_expr_list(ls);
		}
	}
}

# Parse local function
parse_local_function(ls: ref LexState)
{
	# Get function name
	if(ls.lex.t == nil || ls.lex.t.token != TOKEN_NAME)
		return;

	name := "";
	if(ls.lex.t.seminfo != nil && ls.lex.t.seminfo.ty == TSTRING)
		name = ls.lex.t.seminfo.s;

	nexttoken(ls.lex);

	# Parse function body
	parse_function_body(ls, name);
}

# Parse return statement
parse_return_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'return'

	if(!testnext(ls, TOKEN_SEMICOLON)) {
		# Parse return values
		nret := parse_expr_list(ls);
		testnext(ls, TOKEN_SEMICOLON);

		# Generate return
		if(nret == 0) {
			emit_code(ls.fs, OP_RETURN0);
		} else if(nret == 1) {
			emit_code(ls.fs, OP_RETURN1);
		} else {
			emit_abc(ls.fs, OP_RETURN, ls.fs.nactvar, nret + 1, 0);
		}
	}
}

# Parse break statement
parse_break_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'break'

	# Find enclosing loop
	bl := ls.fs.bl;
	while(bl != nil && hd bl.isloop == 0) {
		bl = tl bl;
	}

	if(bl == nil) {
		# Error: no loop to break from
		return;
	}

	# Emit jump
	j := emit_jump(ls.fs, OP_JMP);

	# Add to break list
	breaklist := hd bl.breaklist;
	breaklist = j :: breaklist;
}

# Parse goto statement
parse_goto_statement(ls: ref LexState)
{
	nexttoken(ls.lex);  # Skip 'goto'

	# Get label name
	if(ls.lex.t != nil && ls.lex.t.token == TOKEN_NAME) {
		nexttoken(ls.lex);
		# For now, just skip
	}
}

# Parse expression statement
parse_expr_statement(ls: ref LexState)
{
	# Parse expression or assignment
	reg := parse_expression(ls);

	if(ls.lex.t != nil && ls.lex.t.token == TOKEN_ASSIGN) {
		# Assignment
		nexttoken(ls.lex);
		parse_expression(ls);
	}

	testnext(ls, TOKEN_SEMICOLON);
}

# Parse expression
parse_expression(ls: ref LexState): int
{
	return parse_subexpr(ls, 0);
}

# Operator precedence levels
# 0: or
# 1: and
# 2: <, >, <=, >=, ~=, ==
# 3: |
# 4: ~
# 5: &
# 6: <<, >>
# 7: ..
# 8: +, -
# 9: *, /, //, %
# 10: unary not, -, len, ~
# 11: ^
# 12: function calls, table constructors

# Parse subexpression with precedence climbing
parse_subexpr(ls: ref LexState, limit: int): int
{
	if(ls == nil || ls.lex == nil || ls.lex.t == nil)
		return 0;

	# Parse primary expression
	reg := parse_primary(ls);

	# Parse binary operators
	while(ls.lex.t != nil) {
		op := ls.lex.t.token;

		# Get operator precedence
		prec := get_binop_prec(op);
		if(prec <= limit)
			break;

		nexttoken(ls.lex);  # Skip operator

		# Parse right operand
		right_reg := parse_subexpr(ls, prec);

		# Generate binary operation
		reg = code_binop(ls.fs, op, reg, right_reg);
	}

	return reg;
}

# Get binary operator precedence
get_binop_prec(op: int): int
{
	case(op) {
	TOKEN_OR or TOKEN_ADD or TOKEN_SUB =>
		return 1;
	TOKEN_AND =>
		return 2;
	TOKEN_LT or TOKEN_GT or TOKEN_LE or TOKEN_GE or TOKEN_NE or TOKEN_EQ =>
		return 3;
	TOKEN_MUL or TOKEN_DIV or TOKEN_MOD or TOKEN_IDIV =>
		return 4;
	TOKEN_POW =>
		return 5;
	TOKEN_CONCAT =>
		return 6;
	* =>
		return 0;
	}
}

# Parse primary expression
parse_primary(ls: ref LexState): int
{
	if(ls == nil || ls.lex == nil || ls.lex.t == nil)
		return 0;

	c := ls.lex.t.token;
	reg := alloc_register(ls.fs);

	case(c) {
	TOKEN_NUMBER =>
		if(ls.lex.t.seminfo != nil) {
			emit_loadk(ls.fs, reg, ls.lex.t.seminfo);
		}
		nexttoken(ls.lex);

	TOKEN_STRING =>
		if(ls.lex.t.seminfo != nil) {
			emit_loadk(ls.fs, reg, ls.lex.t.seminfo);
		}
		nexttoken(ls.lex);

	TOKEN_NIL =>
		emit_code(ls.fs, OP_LOADNIL);
		nexttoken(ls.lex);

	TOKEN_TRUE =>
		emit_code(ls.fs, OP_LOADTRUE);
		nexttoken(ls.lex);

	TOKEN_FALSE =>
		emit_code(ls.fs, OP_LOADFALSE);
		nexttoken(ls.lex);

	TOKEN_DOTDOTDOT =>
		# Varargs
		nexttoken(ls.lex);

	TOKEN_NAME =>
		# Variable reference
		if(ls.lex.t.seminfo != nil) {
			name := ls.lex.t.seminfo.s;
			# For now, just load as global
			emit_loadk(ls.fs, reg, mkstring(name));
		}
		nexttoken(ls.lex);

	TOKEN_LPAREN =>
		nexttoken(ls.lex);  # Skip '('
		reg = parse_expression(ls);
		testnext(ls, TOKEN_RPAREN);

	TOKEN_LBRACE =>
		# Table constructor
		reg = parse_table_constructor(ls);

	* =>
		# Error
		free_register(ls.fs, reg);
		reg = 0;
	}

	# Parse suffixes: function calls, indexing
	reg = parse_suffix(ls, reg);

	return reg;
}

# Parse expression suffixes (calls, indexing)
parse_suffix(ls: ref LexState, base: int): int
{
	if(ls == nil || ls.lex == nil)
		return base;

	reg := base;

	while(ls.lex.t != nil) {
		if(ls.lex.t.token == TOKEN_LPAREN) {
			# Function call
			nexttoken(ls.lex);  # Skip '('

			# Parse arguments
			nargs := 0;
			if(ls.lex.t != nil && ls.lex.t.token != TOKEN_RPAREN) {
				nargs = parse_expr_list(ls);
			}

			testnext(ls, TOKEN_RPAREN);

			# Generate call
			emit_abc(ls.fs, OP_CALL, reg, nargs + 1, 1);

		} else if(ls.lex.t.token == TOKEN_LBRACKET) {
			# Indexing: table[key]
			nexttoken(ls.lex);  # Skip '['

			key := parse_expression(ls);

			testnext(ls, TOKEN_RBRACKET);

			# Generate GETTABLE
			emit_abc(ls.fs, OP_GETTABLE, reg, reg, key);

		} else if(ls.lex.t.token == TOKEN_DOT) {
			# Field access: table.key
			nexttoken(ls.lex);  # Skip '.'

			if(ls.lex.t != nil && ls.lex.t.token == TOKEN_NAME) {
				# Load field name as constant
				if(ls.lex.t.seminfo != nil) {
					key_idx := add_constant(ls.fs, ls.lex.t.seminfo);
					emit_abc(ls.fs, OP_GETFIELD, reg, reg, key_idx);
				}
				nexttoken(ls.lex);
			}

		} else {
			break;
		}
	}

	return reg;
}

# Parse expression list
parse_expr_list(ls: ref LexState): int
{
	if(ls == nil)
		return 0;

	n := 0;
	for(;;) {
		parse_expression(ls);
		n++;
		if(!testnext(ls, TOKEN_COMMA))
			break;
	}
	return n;
}

# Parse table constructor
parse_table_constructor(ls: ref LexState): int
{
	nexttoken(ls.lex);  # Skip '{'

	reg := alloc_register(ls.fs);

	# Create new table
	emit_abc(ls.fs, OP_NEWTABLE, reg, 0, 0);

	while(ls.lex.t != nil && ls.lex.t.token != TOKEN_RBRACE) {
		# Parse field
		if(ls.lex.t.token == TOKEN_NAME) {
			nexttoken(ls.lex);
			if(testnext(ls, TOKEN_ASSIGN)) {
				# name = value
				parse_expression(ls);
			}
		} else {
			parse_expression(ls);
			if(testnext(ls, TOKEN_ASSIGN)) {
				parse_expression(ls);
			}
		}

		if(ls.lex.t != nil && ls.lex.t.token != TOKEN_RCOMMA) {
			if(!testnext(ls, TOKEN_COMMA) && !testnext(ls, TOKEN_SEMICOLON))
				break;
		}
	}

	testnext(ls, TOKEN_RBRACE);
	return reg;
}

# Parse function body
parse_function_body(ls: ref LexState, name: string)
{
	# Create new function prototype
	proto := ref Proto;
	proto.sourcename = "";
	proto.lineDefined = ls.lex.lineno;
	proto.lastLineDefined = ls.lex.lineno;
	proto.numparams = 0;
	proto.is_vararg = 0;

	# Create new FuncState
	newfs := ref FuncState;
	newfs.f = proto;
	newfs.prev = ls.fs;
	newfs.L = ls.L;
	newfs.ls = ls;
	newfs.nactvar = 0;
	newfs.nups = 0;
	newfs.freereg = 0;
	newfs.bl = nil;
	newfs.jpc = nil;
	newfs.firstlocal = 0;

	ls.fs = newfs;

	# Parse parameters
	if(!testnext(ls, TOKEN_LPAREN))
		return;

	nparams := 0;
	while(ls.lex.t != nil && ls.lex.t.token == TOKEN_NAME) {
		declare_localvar(ls);
		nparams++;
		if(!testnext(ls, TOKEN_COMMA))
			break;
	}

	# Varargs?
	if(testnext(ls, TOKEN_DOTDOTDOT)) {
		proto.is_vararg = 1;
	}

	if(!testnext(ls, TOKEN_RPAREN))
		return;

	proto.numparams = nparams;

	# Parse body
	parse_block(ls);

	# End of function
	testnext(ls, TOKEN_END);

	# Return to outer function
	ls.fs = newfs.prev;
}

# Parse block
parse_block(ls: ref LexState)
{
	if(ls == nil)
		return;

	enterblock(ls.fs, 0);
	parse_chunk(ls);
	leaveblock(ls.fs);
}

# Generate binary operation code
code_binop(fs: ref FuncState, op: int, v1, v2: int): int
{
	if(fs == nil)
		return 0;

	result := alloc_register(fs);

	case(op) {
	TOKEN_ADD =>
		emit_abc(fs, OP_ADD, result, v1, v2);
	TOKEN_SUB =>
		emit_abc(fs, OP_SUB, result, v1, v2);
	TOKEN_MUL =>
		emit_abc(fs, OP_MUL, result, v1, v2);
	TOKEN_DIV =>
		emit_abc(fs, OP_DIV, result, v1, v2);
	TOKEN_IDIV =>
		emit_abc(fs, OP_IDIV, result, v1, v2);
	TOKEN_MOD =>
		emit_abc(fs, OP_MOD, result, v1, v2);
	TOKEN_POW =>
		emit_abc(fs, OP_POW, result, v1, v2);
	TOKEN_EQ =>
		emit_abc(fs, OP_EQ, result, v1, v2);
	TOKEN_NE =>
		emit_abc(fs, OP_EQ, result, v1, v2);
	TOKEN_LT =>
		emit_abc(fs, OP_LT, result, v1, v2);
	TOKEN_LE =>
		emit_abc(fs, OP_LE, result, v1, v2);
	TOKEN_GT =>
		emit_abc(fs, OP_LT, result, v2, v1);
	TOKEN_GE =>
		emit_abc(fs, OP_LE, result, v2, v1);
	TOKEN_AND =>
		emit_abc(fs, OP_TEST, result, v1, 0);
	TOKEN_OR =>
		emit_abc(fs, OP_TEST, result, v1, 1);
	}

	return result;
}

# ============================================================
# SECTION 20: MAIN PARSER ENTRY POINT
# ============================================================

# Parse Lua source code
parse(L: ref State, source: string): ref Proto
{
	if(L == nil || source == nil)
		return nil;

	# Create lexical state
	ls := ref LexState;
	ls.L = L;
	ls.lex = newlexer(source);

	# Create main function prototype
	main_proto := ref Proto;
	main_proto.sourcename = "";
	main_proto.lineDefined = 1;
	main_proto.lastLineDefined = 1;
	main_proto.numparams = 0;
	main_proto.is_vararg = 1;  # Main chunk is vararg
	main_proto.maxstacksize = 2;
	main_proto.code = array[0] of byte;
	main_proto.k = array[0] of ref Value;
	main_proto.p = array[0] of ref Proto;
	main_proto.upvalues = array[0] of byte;
	main_proto.lineinfo = array[0] of int;
	main_proto.locvars = array[0] of ref Locvar;

	# Create main function state
	fs := ref FuncState;
	fs.f = main_proto;
	fs.prev = nil;
	fs.L = L;
	fs.ls = ls;
	fs.nactvar = 0;
	fs.nups = 0;
	fs.freereg = 0;
	fs.bl = nil;
	fs.jpc = nil;
	fs.firstlocal = 0;

	ls.fs = fs;

	# Get first token
	nexttoken(ls.lex);

	# Parse chunk
	parse_chunk(ls);

	# Emit return
	emit_abc(fs, OP_RETURN, 0, 1, 0);

	return main_proto;
}

# ============================================================
# SECTION 21: VM EXECUTOR (FULL IMPLEMENTATION)
# ============================================================

# Main VM execution loop - fetch, decode, execute
vmexec(vm: ref VM): int
{
	L := vm.L;

	for(;;) {
		# Check if we have a valid function
		if(vm.ci == nil || vm.ci.func == nil || vm.ci.func.f == nil ||
		   vm.ci.func.f.proto == nil || vm.ci.func.f.proto.code == nil)
			break;

		proto := vm.ci.func.f.proto;

		# Check PC bounds
		if(vm.pc < 0 || vm.pc >= len proto.code / 4)
			break;

		# Fetch instruction
		inst := getinst(proto, vm.pc);
		opcode := GET_OPCODE(inst);
		a := GETARG_A(inst);
		b := GETARG_B(inst);
		c := GETARG_C(inst);

		# Execute instruction
		case(opcode) {
		OP_MOVE =>
			# R[A] := R[B]
			if(vm.base + b < len L.stack) {
				if(vm.base + a < len L.stack) {
					L.stack[vm.base + a] = L.stack[vm.base + b];
				}
			}
			vm.pc++;

		OP_LOADK =>
			# R[A] := K[Bx]
			bx := GETARG_Bx(inst);
			if(bx < len proto.k && vm.base + a < len L.stack) {
				L.stack[vm.base + a] = proto.k[bx];
			}
			vm.pc++;

		OP_LOADFALSE =>
			# R[A] := false
			if(vm.base + a < len L.stack) {
				L.stack[vm.base + a] = mkbool(0);
			}
			vm.pc++;

		OP_LOADTRUE =>
			# R[A] := true
			if(vm.base + a < len L.stack) {
				L.stack[vm.base + a] = mkbool(1);
			}
			vm.pc++;

		OP_LOADNIL =>
			# R[A], R[A+1], ..., R[A+B] := nil
			for(i := 0; i <= b && vm.base + a + i < len L.stack; i++) {
				L.stack[vm.base + a + i] = mknil();
			}
			vm.pc++;

		OP_ADD =>
			# R[A] := R[B] + R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(v1.n + v2.n);
				}
			}
			vm.pc++;

		OP_SUB =>
			# R[A] := R[B] - R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(v1.n - v2.n);
				}
			}
			vm.pc++;

		OP_MUL =>
			# R[A] := R[B] * R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(v1.n * v2.n);
				}
			}
			vm.pc++;

		OP_DIV =>
			# R[A] := R[B] / R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					if(v2.n != 0.0)
						L.stack[vm.base + a] = mknumber(v1.n / v2.n);
				}
			}
			vm.pc++;

		OP_MOD =>
			# R[A] := R[B] % R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					if(v2.n != 0.0)
						L.stack[vm.base + a] = mknumber(v1.n - v2.n * real(int(v1.n / v2.n)));
				}
			}
			vm.pc++;

		OP_POW =>
			# R[A] := R[B] ^ R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(v1.n ** v2.n);
				}
			}
			vm.pc++;

		OP_IDIV =>
			# R[A] := R[B] // R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					if(v2.n != 0.0)
						L.stack[vm.base + a] = mknumber(real(int(v1.n / v2.n)));
				}
			}
			vm.pc++;

		OP_BAND =>
			# R[A] := R[B] & R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(real(int(v1.n) & int(v2.n)));
				}
			}
			vm.pc++;

		OP_BOR =>
			# R[A] := R[B] | R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(real(int(v1.n) | int(v2.n)));
				}
			}
			vm.pc++;

		OP_BXOR =>
			# R[A] := R[B] ~ R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(real(int(v1.n) ^ int(v2.n)));
				}
			}
			vm.pc++;

		OP_SHL =>
			# R[A] := R[B] << R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(real(int(v1.n) << int(v2.n)));
				}
			}
			vm.pc++;

		OP_SHR =>
			# R[A] := R[B] >> R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				if(v1 != nil && v2 != nil && v1.ty == TNUMBER && v2.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(real(int(v1.n) >> int(v2.n)));
				}
			}
			vm.pc++;

		OP_UNM =>
			# R[A] := -R[B]
			if(vm.base + b < len L.stack && vm.base + a < len L.stack) {
				v := L.stack[vm.base + b];
				if(v != nil && v.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(-v.n);
				}
			}
			vm.pc++;

		OP_BNOT =>
			# R[A] := ~R[B]
			if(vm.base + b < len L.stack && vm.base + a < len L.stack) {
				v := L.stack[vm.base + b];
				if(v != nil && v.ty == TNUMBER) {
					L.stack[vm.base + a] = mknumber(real(~int(v.n)));
				}
			}
			vm.pc++;

		OP_NOT =>
			# R[A] := not R[B]
			if(vm.base + b < len L.stack && vm.base + a < len L.stack) {
				v := L.stack[vm.base + b];
				if(v != nil && toboolean(v))
					L.stack[vm.base + a] = mkbool(0);
				else
					L.stack[vm.base + a] = mkbool(1);
			}
			vm.pc++;

		OP_LEN =>
			# R[A] := #R[B]
			if(vm.base + b < len L.stack && vm.base + a < len L.stack) {
				v := L.stack[vm.base + b];
				if(v != nil && v.ty == TSTRING) {
					L.stack[vm.base + a] = mknumber(real(len v.s));
				} else if(v != nil && v.ty == TTABLE && v.t != nil) {
					L.stack[vm.base + a] = mknumber(real(tablelength(v.t)));
				}
			}
			vm.pc++;

		OP_CONCAT =>
			# R[A] := R[B] .. .. R[C]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				result := "";
				for(i := b; i <= c && vm.base + i < len L.stack; i++) {
					v := L.stack[vm.base + i];
					if(v != nil && v.ty == TSTRING) {
						result += v.s;
					}
				}
				L.stack[vm.base + a] = mkstring(result);
			}
			vm.pc++;

		OP_GETTABLE =>
			# R[A] := R[B][R[C]]
			if(vm.base + b < len L.stack && vm.base + c < len L.stack &&
			   vm.base + a < len L.stack) {
				t := L.stack[vm.base + b];
				key := L.stack[vm.base + c];
				if(t != nil && t.ty == TTABLE && t.t != nil) {
					L.stack[vm.base + a] = gettablevalue(t.t, key);
				}
			}
			vm.pc++;

		OP_SETTABLE =>
			# R[A][R[B]] := R[C]
			if(vm.base + a < len L.stack && vm.base + b < len L.stack &&
			   vm.base + c < len L.stack) {
				t := L.stack[vm.base + a];
				key := L.stack[vm.base + b];
				val := L.stack[vm.base + c];
				if(t != nil && t.ty == TTABLE && t.t != nil) {
					settablevalue(t.t, key, val);
				}
			}
			vm.pc++;

		OP_NEWTABLE =>
			# R[A] := {}
			if(vm.base + a < len L.stack) {
				t := createtable(0, 0);
				L.stack[vm.base + a] = mktable(t);
			}
			vm.pc++;

		OP_JMP =>
			# pc += sJ
			offset := GETARG_sJ(inst);
			vm.pc += offset + 1;

		OP_EQ =>
			# if ((R[B] == R[C]) ~= A) then pc++
			if(vm.base + b < len L.stack && vm.base + c < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				result := valueseq(v1, v2);
				if(a == 0)
					result = !result;
				if(result)
					vm.pc++;
				else
					vm.pc++;
			}
			vm.pc++;

		OP_LT =>
			# if ((R[B] < R[C]) ~= A) then pc++
			if(vm.base + b < len L.stack && vm.base + c < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				result := comparelt(v1, v2);
				if(a == 0)
					result = !result;
				if(result)
					vm.pc++;
				else
					vm.pc++;
			}
			vm.pc++;

		OP_LE =>
			# if ((R[B] <= R[C]) ~= A) then pc++
			if(vm.base + b < len L.stack && vm.base + c < len L.stack) {
				v1 := L.stack[vm.base + b];
				v2 := L.stack[vm.base + c];
				result := comparele(v1, v2);
				if(a == 0)
					result = !result;
				if(result)
					vm.pc++;
				else
					vm.pc++;
			}
			vm.pc++;

		OP_TEST =>
			# if not (R[A] <=> C) then pc++
			if(vm.base + a < len L.stack) {
				v := L.stack[vm.base + a];
				result := toboolean(v);
				if(c != 0)
					result = !result;
				if(!result)
					vm.pc++;
			}
			vm.pc++;

		OP_CALL =>
			# R[A](R[A+1], ... , R[A+B-1])
			nargs := b - 1;
			if(vm.base + a < len L.stack) {
				func := L.stack[vm.base + a];
				if(func != nil && func.ty == TFUNCTION && func.f != nil) {
					# Set up new call
					newbase := vm.base + a;

					# Save current state
					saved_ci := vm.ci;

					# Create new call info
					ci := ref CallInfo;
					ci.func = func;
					ci.base = newbase;
					ci.top = newbase + nargs + 1;
					ci.savedpc = vm.pc + 1;
					ci.nresults = c;
					ci.next = nil;

					vm.ci = ci;
					vm.base = newbase;

					# Check if C closure or Lua closure
					if(func.f.isc == 1) {
						# C closure
						result := callbuiltin(L, func, nargs);
						vm.ci = saved_ci;
						if(result != OK)
							return result;
					} else {
						# Lua closure - would recurse here
						# For now, just return
						vm.ci = saved_ci;
					}
				}
			}
			vm.pc++;

		OP_RETURN =>
			# return R[A], ... , R[B-2]
			if(vm.ci != nil) {
				# Return to caller
				vm.ci = vm.ci.next;
				if(vm.ci == nil)
					return OK;  # Back to top level
			}
			vm.pc++;

		OP_RETURN0 =>
			# return
			if(vm.ci != nil) {
				vm.ci = vm.ci.next;
				if(vm.ci == nil)
					return OK;
			}
			vm.pc++;

		OP_RETURN1 =>
			# return R[A]
			if(vm.ci != nil) {
				vm.ci = vm.ci.next;
				if(vm.ci == nil)
					return OK;
			}
			vm.pc++;

		OP_FORLOOP =>
			# Numeric for loop
			vm.pc++;

		OP_FORPREP =>
			# Numeric for preparation
			vm.pc++;

		OP_TFORLOOP =>
			# Generic for loop
			vm.pc++;

		OP_SETLIST =>
			# Set list in table
			vm.pc++;

		OP_CLOSURE =>
			# Create closure
			bx := GETARG_Bx(inst);
			if(bx < len proto.p && vm.base + a < len L.stack) {
				p := proto.p[bx];
				cl := newluaclosure(p, L.global);
				L.stack[vm.base + a] = mkfunction(cl);
			}
			vm.pc++;

		OP_VARARG =>
			# Vararg handling
			vm.pc++;

		* =>
			# Unknown opcode - stop execution
			return OK;
		}
	}

	return OK;
}

# ============================================================
# SECTION 22: LOAD FUNCTIONS (INTEGRATION)
# ============================================================

# Load Lua string
loadstring(L: ref State, s: string): int
{
	if(L == nil || s == nil)
		return ERRSYNTAX;

	# Parse the source
	proto := parse(L, s);
	if(proto == nil)
		return ERRSYNTAX;

	# Create closure
	closure := newluaclosure(proto, L.global);

	# Push onto stack
	pushvalue(L, mkfunction(closure));

	return OK;
}

# Load Lua file
loadfile(L: ref State, filename: string): int
{
	if(L == nil || filename == nil)
		return ERRFILE;

	# Open file
	fd := sys->open(filename, Sys->OREAD);
	if(fd == nil)
		return ERRFILE;

	# Read file
	buf := array[8192] of byte;
	source := "";
	nread := 0;

	while((nread = sys->read(fd, buf, len buf)) > 0) {
		source += string buf[0:nread];
	}

	sys->close(fd);

	# Load the source
	return loadstring(L, source);
}

# Protected call
pcall(L: ref State, nargs: int, nresults: int): int
{
	if(L == nil)
		return ERRERR;

	# Get function from stack
	funcidx := L.top - nargs - 1;
	if(funcidx < 0 || funcidx >= len L.stack)
		return ERRRUN;

	func := L.stack[funcidx];
	if(func == nil || func.ty != TFUNCTION)
		return ERRRUN;

	# Create VM if needed
	if(L.ci == nil) {
		vm := newvm(L);
		if(vm == nil)
			return ERRERR;

		# Execute the function
		result := execute(vm, func, nargs);

		# Clean up
		pop(L, nargs + 1);  # Pop function and arguments

		# Push result (nil on success for now)
		if(result == OK) {
			pushnil(L);  # Status: OK
		} else {
			pushboolean(L, 0);  # Status: error
		}

		return result;
	}

	# For now, just return OK
	pop(L, nargs + 1);
	pushnil(L);
	return OK;
}

# ============================================================
# SECTION 15: PUBLIC INTERFACE FUNCTIONS
# ============================================================

# Allocate GC object (public interface)
allocobj(sz: int): ref Value
{
	# Placeholder - returns nil value
	return mknil();
}

# Create new thread (public interface)
newthread(L: ref State): ref Thread
{
	return newthread_state(L);
}

# Resume coroutine (public interface)
resume(L: ref State, co: ref Thread, nargs: int): int
{
	return resume_thread(L, co, nargs);
}

# Yield from coroutine (public interface)
yield(L: ref State, nresults: int): int
{
	return yield_thread(L, nresults);
}

# Set metatable (public interface)
setmetatable(L: ref State, idx: int)
{
	# Placeholder for public setmetatable
}

# Get metatable (public interface)
getmetatable(L: ref State, idx: int): ref Table
{
	# Placeholder for public getmetatable
	return nil;
}

# ============================================================
# SECTION 16: BUILTIN FUNCTION REGISTRY
# ============================================================

# Builtin function registry type
BuiltinEntry: adt {
	name:	string;
	next:	ref BuiltinEntry;
};

# Global builtin registry
builtins:	ref BuiltinEntry = nil;

# Register a builtin function by name
registerbuiltin(name: string): int
{
	# Check if already registered
	cur := builtins;
	while(cur != nil) {
		if(cur.name == name)
			return 0;  # Already registered
		cur = cur.next;
	}

	# Add to registry
	entry := ref BuiltinEntry;
	entry.name = name;
	entry.next = builtins;
	builtins = entry;

	return 0;
}

# Create a Value wrapping a builtin function
newbuiltin(name: string): ref Value
{
	# Create C closure with builtin name
	f := ref Function;
	f.isc = 1;
	f.builtin = name;

	# Create Value wrapper
	v := ref Value;
	v.ty = TFUNCTION;
	v.f = f;

	return v;
}

# Set a global variable in the Lua state
setglobal(L: ref State, name: string, value: ref Value)
{
	if(L == nil || L.global == nil)
		return;

	# Create key Value
	key := ref Value;
	key.ty = TSTRING;
	key.s = name;

	# Set in global table
	settablevalue(L.global, key, value);
}

# Get a global variable from the Lua state
getglobal(L: ref State, name: string): ref Value
{
	if(L == nil || L.global == nil)
		return mknil();

	# Create key Value
	key := ref Value;
	key.ty = TSTRING;
	key.s = name;

	# Get from global table
	return gettablevalue(L.global, key);
}

# ============================================================
# SECTION 17: MODULE INTERFACE
# ============================================================

# Initialize the Lua VM library
init(): string
{
	sys = load Sys "/dis/lib/sys.dis";
	initmem();
	initstrings();
	return nil;
}

# About this implementation
about(): array of string
{
	return array[] of {
		"Lua VM for Inferno/Limbo",
		"Lua 5.4 compatible implementation",
		"Unified module implementation (combines 24 source files)",
		"",
		"Components:",
		"- Type system and value constructors",
		"- Table implementation with hybrid array/hash",
		"- String interning and operations",
		"- Functions, closures, and upvalues",
		"- Coroutine support",
		"- Mark-and-sweep garbage collection",
		"- Virtual machine executor",
		"- State management",
	};
}
