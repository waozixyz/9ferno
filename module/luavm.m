Luavm : module {
	#
	# Lua VM for Inferno/Limbo - Lua 5.4 compatible
	#

	PATH:	con "/dis/lib/luavm.dis";

	# Lua type constants
	TNIL, TBOOLEAN, TNUMBER, TSTRING, TTABLE, TFUNCTION, TUSERDATA, TTHREAD: con iota;

	# Lua status codes
	OK, YIELD, ERRRUN, ERRSYNTAX, ERRMEM, ERRERR, ERRFILE: con iota;

	# Value representation - tagged union
	Value: adt {
		ty:	int;			# Type tag
		b:	int;			# Boolean value
		n:	real;			# Number value
		s:	string;			# String value
		t:	cyclic ref Table;	# Table value
		f:	cyclic ref Function;	# Function value
		u:	cyclic ref Userdata;	# Userdata value
		th:	cyclic ref Thread;	# Thread value
	};

	# Table implementation
	Table: adt {
		metatable:	cyclic ref Table;	# Metatable
		arr:		array of ref Value;	# Array part
		hash:		cyclic ref Hashnode;	# Hash part
		sizearray:	int;			# Size of array part
	};

	# Hash node for table hash part
	Hashnode: adt {
		next:	ref Hashnode;
		key:	ref Value;
		val:	ref Value;
	};

	# Function closure
	Function: adt {
		isc:	int;			# Is C closure (1) or Lua closure (0)
		proto:	cyclic ref Proto;	# Function prototype (Lua functions)
		upvals:	array of ref Upval;	# Upvalues
		env:	cyclic ref Table;	# Environment table
		builtin:	string;		# Builtin function name (for C closures)
	};

	# Function prototype
	Proto: adt {
		code:		array of byte;		# Bytecode
		k:		array of ref Value;	# Constants
		p:		array of ref Proto;	# Prototypes of nested functions
		upvalues:	array of byte;		# Upvalue info
		lineinfo:	array of int;		# Debug info
		locvars:	array of ref Locvar;	# Local variable debug info
		sourcename:	string;			# Source name
		lineDefined:	int;			# Line defined
		lastLineDefined: int;		# Last line defined
		numparams:	int;			# Number of parameters
		is_vararg:	int;			# Vararg flag
		maxstacksize:	int;			# Max stack size needed
	};

	# Local variable debug info
	Locvar: adt {
		varname:	string;
		startpc:	int;
		endpc:		int;
	};

	# Upvalue
	Upval: adt {
		v:		cyclic ref Value;	# Value pointer (open: points to stack, closed: points to value)
		refcount:	int;			# Reference count
	};

	# Userdata
	Userdata: adt {
		env:	cyclic ref Table;	# Environment table
		metatable:	cyclic ref Table;	# Metatable
		data:	array of byte;		# User data
		length:	int;			# Length of data
	};

	# Thread (coroutine)
	Thread: adt {
		status:	int;			# Thread status
		stack:	array of ref Value;	# Stack
		ci:	ref CallInfo;		# Call info list
		base:	int;			# Stack base
		top:	int;			# Stack top
	};

	# Call info for function calls
	CallInfo: adt {
		next:		ref CallInfo;
		func:		ref Value;		# Function being called
		base:		int;			# Base stack index
		top:		int;			# Top stack index
		savedpc:	int;			# Saved program counter
		nresults:	int;			# Number of results
	};

	# Lua state
	State: adt {
		stack:		array of ref Value;	# Lua stack
		top:		int;			# Stack top
		base:		int;			# Stack base for current function
		ci:		ref CallInfo;		# Call info
		global:		ref Table;		# Global table
		registry:	ref Table;		# Registry table
		upvalhead:	ref Upval;		# Head of open upvalue list
		errorjmp:	ref Errorjmp;		# Error recovery
	};

	# Error recovery for longjmp
	Errorjmp: adt {
		old:	ref Errorjmp;
		status:	int;
		buffer:	array of byte;		# Jump buffer
	};

	# String table for interning
	Stringtable: adt {
		hash:	array of ref TString;	# Hash table
		size:	int;			# Size of hash table
		nuse:	int;			# Number of elements in use
	};

	# String with hash
	TString: adt {
		next:	ref TString;
		hash:	int;			# String hash
		s:	string;			# String value
		length:	int;			# String length
		reserved:	int;		# Reserved word flag
	};

	# Global state
	Global: adt {
		strings:	ref Stringtable;	# String table
		registry:	ref Table;		# Registry table
		malloc:	big;			# Memory allocated
		gcthreshold:	big;		# GC threshold
	};

	# Initialize the Lua VM library
	# Returns error string or nil on success
	init:	fn(): string;

	# Create a new Lua state
	newstate:	fn(): ref State;

	# Close a Lua state
	close:	fn(L: ref State);

	# Load a Lua string
	loadstring:	fn(L: ref State, s: string): int;

	# Load a Lua file
	loadfile:	fn(L: ref State, filename: string): int;

	# Protected call
	pcall:	fn(L: ref State, nargs: int, nresults: int): int;

	# Get value from stack
	getvalue:	fn(L: ref State, idx: int): ref Value;

	# Push value onto stack
	pushvalue:	fn(L: ref State, v: ref Value);

	# Push nil
	pushnil:	fn(L: ref State);

	# Push boolean
	pushboolean:	fn(L: ref State, b: int);

	# Push number
	pushnumber:	fn(L: ref State, n: real);

	# Push string
	pushstring:	fn(L: ref State, s: string);

	# Pop values from stack
	pop:	fn(L: ref State, n: int);

	# Get top of stack
	gettop:	fn(L: ref State): int;

	# Set top of stack
	settop:	fn(L: ref State, idx: int);

	# Create new table
	newtable:	fn(L: ref State): ref Table;

	# Get table field
	getfield:	fn(L: ref State, idx: int, k: string);

	# Set table field
	setfield:	fn(L: ref State, idx: int, k: string);

	# Get table
	gettable:	fn(L: ref State, idx: int);

	# Set table
	settable:	fn(L: ref State, idx: int);

	# Create new thread
	newthread:	fn(L: ref State): ref Thread;

	# Resume coroutine
	resume:	fn(L: ref State, co: ref Thread, nargs: int): int;

	# Yield from coroutine
	yield:	fn(L: ref State, nresults: int): int;

	# Get string length (fast)
	objlen:	fn(v: ref Value): int;

	# Get type name
	typeName:	fn(v: ref Value): string;

	# Check if value is nil
	isnil:	fn(v: ref Value): int;

	# Check if value is boolean
	isboolean:	fn(v: ref Value): int;

	# Check if value is number
	isnumber:	fn(v: ref Value): int;

	# Check if value is string
	isstring:	fn(v: ref Value): int;

	# Check if value is table
	istable:	fn(v: ref Value): int;

	# Check if value is function
	isfunction:	fn(v: ref Value): int;

	# Check if value is userdata
	isuserdata:	fn(v: ref Value): int;

	# Check if value is thread
	isthread:	fn(v: ref Value): int;

	# Convert value to boolean
	toboolean:	fn(v: ref Value): int;

	# Convert value to number
	tonumber:	fn(v: ref Value): real;

	# Convert value to string
	tostring:	fn(v: ref Value): string;

	# Create a new table with preallocated size
	createtable:	fn(narr: int, nrec: int): ref Table;

	# Get table value
	gettablevalue:	fn(t: ref Table, key: ref Value): ref Value;

	# Set table value
	settablevalue:	fn(t: ref Table, key: ref Value, val: ref Value);

	# Create string hash
	strhash:	fn(s: string): int;

	# Intern string
	internstring:	fn(s: string): ref TString;

	# Allocate GC object
	allocobj:fn(sz: int): ref Value;

	# Garbage collection
	gc:	fn(L: ref State, what: int, data: real): real;

	# Constants for gc()
	GCSTOP, GCRESTART, GCCOLLECT, GCCOUNT, GCCOUNTB, GCSTEP, GCSETPAUSE, GCSETSTEPMUL: con iota;

	# About this implementation
	about:	fn(): array of string;

	# ============================================================
	# Builtin Function Registration API
	# ============================================================

	# Register a builtin function handler
	# name: name of the builtin function
	# Returns 0 on success, -1 on failure
	registerbuiltin:	fn(name: string): int;

	# Create a C closure referencing a builtin function
	# name: name of the registered builtin
	# Returns the function value
	newbuiltin:	fn(name: string): ref Value;

	# Set a global variable
	# name: global variable name
	# value: value to set
	setglobal:	fn(L: ref State, name: string, value: ref Value);

	# Get a global variable
	# name: global variable name
	# Returns the value
	getglobal:	fn(L: ref State, name: string): ref Value;
};
