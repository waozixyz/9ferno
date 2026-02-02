#!/dis/sh
# Lua Shell - Interactive REPL and Script Executor
# Handles command-line arguments and file execution

implement Lua;

include "sys.m";
include "draw.m";
include "luavm.m";

sys: Sys;
print, sprint, fprint, pctl, fildes: import sys;

draw: Draw;
Context: import draw;

# Lua VM module
luavm: Luavm;

Lua: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# ====================================================================
# Command-line Options
# ====================================================================

Options: adt {
	verbose: int;
	execute: string;
	version: int;
	interactive: int;
};

# ====================================================================
# Main Entry Point
# ====================================================================

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	# Load Lua VM
	luavm = load Luavm Luavm->PATH;
	if(luavm == nil) {
		sys->fprint(sys->fildes(2), "lua: failed to load VM\n");
		return;
	}

	# Parse options
	opts := parseoptions(argv);
	if(opts == nil)
		return;

	# Show version and exit
	if(opts.version) {
		printversion();
		return;
	}

	# Create Lua state
	L := luavm->newstate();
	if(L == nil) {
		sys->fprint(sys->fildes(2), "lua: failed to create state\n");
		return;
	}

	# Load standard libraries
	loadstdlibs(L);

	# Set up global args
	setargs(L, argv);

	# Execute -e code
	if(opts.execute != nil) {
		status := executebuffer(L, opts.execute);
		if(status != Luavm->OK)
			printerror(L);
	}

	# Execute scripts or run interactively
	argv = skipoptions(argv);

	if(argv != nil) {
		# Execute script files
		while(argv != nil) {
			script := hd argv;
			argv = tl argv;

			if(len script > 0 && script[0] != '-') {
				doscript(L, script);
			}
		}
	}

	# If no scripts or forced interactive, run REPL
	if(opts.interactive || (argv == nil && opts.execute == nil)) {
		printbanner();
		runrepl(L);
	}

	# Cleanup
	luavm->close(L);
}

# ====================================================================
# Option Parsing
# ====================================================================

parseoptions(argv: list of string): ref Options
{
	if(argv == nil)
		return nil;

	opts := ref Options;
	opts.verbose = 0;
	opts.version = 0;
	opts.execute = nil;
	opts.interactive = 0;

	# Skip program name
	argv = tl argv;

	while(argv != nil) {
		arg := hd argv;
		argv = tl argv;

		if(len arg == 0 || arg[0] != '-')
			break;

		if(arg == "-v" || arg == "--version") {
			opts.version = 1;
			return opts;
		} else if(arg == "-i" || arg == "--interactive") {
			opts.interactive = 1;
		} else if(arg == "-e" && argv != nil) {
			opts.execute = hd argv;
			argv = tl argv;
		} else if(arg == "-v" || arg == "--verbose") {
			opts.verbose = 1;
		} else if(arg == "-h" || arg == "--help") {
			printhelp();
			return nil;
		} else if(arg == "--") {
			break;
		} else if(arg == "-") {
			opts.interactive = 1;
		} else {
			sys->fprint(sys->fildes(2), "lua: unknown option: %s\n", arg);
			return nil;
		}
	}

	return opts;
}

skipoptions(argv: list of string): list of string
{
	if(argv == nil)
		return nil;

	# Skip program name
	argv = tl argv;

	# Skip options
	while(argv != nil) {
		arg := hd argv;
		if(len arg == 0 || arg[0] != '-')
			break;

		if(arg == "-e" && tl argv != nil)
			argv = tl argv;  # Skip argument too

		argv = tl argv;
	}

	return argv;
}

# ====================================================================
# Script Execution
# ====================================================================

doscript(L: ref Luavm->State, filename: string)
{
	if(filename == nil)
		return;

	# Check if file exists
	fd := sys->open(filename, Sys->OREAD);
	if(fd == nil) {
		sys->fprint(sys->fildes(2), "lua: cannot open %s: %r\n", filename);
		return;
	}
	# FD is reference counted, will be cleaned up when it goes out of scope

	# Load and execute file
	status := luavm->loadfile(L, filename);
	if(status != Luavm->OK) {
		printerror(L);
		return;
	}

	status = luavm->pcall(L, 0, -1);
	if(status != Luavm->OK) {
		printerror(L);
		return;
	}
}

# ====================================================================
# Interactive REPL
# ====================================================================

runrepl(L: ref Luavm->State)
{
	stdin := sys->fildes(0);
	stdout := sys->fildes(1);

	# Set up global _PROMPT
	setprompt(L);

	buffer := "";
	line := 1;
	buf := array[1024] of byte;

	for(;;) {
		# Show prompt
		prompt := "> ";
		if(len buffer > 0)
			prompt = ">> ";

		sys->fprint(stdout, "%s", prompt);

		# Read line
		n := sys->read(stdin, buf, len buf);
		if(n <= 0) {
			# EOF or error
			sys->fprint(stdout, "\n");
			break;
		}

		# Convert to string and remove newline
		s := string buf[0:n];
		if(len s > 0 && s[len s - 1] == '\n')
			s = s[:len s - 1];
		if(len s > 0 && s[len s - 1] == '\r')
			s = s[:len s - 1];

		# Check for empty line
		if(len s == 0) {
			if(len buffer > 0) {
				# Execute buffer
				status := executebuffer(L, buffer);
				if(status != Luavm->OK)
					printerror(L);

				buffer = "";
			}
			continue;
		}

		# Add to buffer
		if(len buffer > 0)
			buffer += "\n";

		buffer += s;

		# Check if complete statement
		if(iscomplete(buffer)) {
			status := executebuffer(L, buffer);
			if(status != Luavm->OK)
				printerror(L);

			buffer = "";
		}

		line++;
	}
}

# Check if statement is complete
iscomplete(s: string): int
{
	if(s == nil)
		return 0;

	# Simple check: balanced brackets
	depth := 0;

	for(i := 0; i < len s; i++) {
		c := s[i];

		if(c == '(' || c == '{' || c == '[')
			depth++;
		else if(c == ')' || c == '}' || c == ']')
			depth--;
	}

	return depth == 0;
}

# Execute buffer
executebuffer(L: ref Luavm->State, code: string): int
{
	if(code == nil || len code == 0)
		return Luavm->OK;

	# Trim whitespace
	while(len code > 0 && (code[0] == ' ' || code[0] == '\t' || code[0] == '\n'))
		code = code[1:];

	# Simple expression evaluation for common cases
	# This is a workaround until full parser is implemented

	# Handle: print(...)
	if(len code > 5 && code[0:5] == "print") {
		# Extract arguments (simple parsing)
		args := code[5:];

		# Remove opening parenthesis
		if(len args > 0 && args[0] == '(')
			args = args[1:];

		# Remove closing parenthesis
		if(len args > 0 && args[len args - 1] == ')')
			args = args[0 : len args - 1];

		# Trim whitespace
		while(len args > 0 && (args[0] == ' ' || args[0] == '\t'))
			args = args[1:];

		# For now, just print the raw argument
		# TODO: Parse and evaluate the argument
		if(len args > 0) {
			# Check if it's a string literal
			if(len args > 1 && args[0] == '"' && args[len args - 1] == '"') {
				# String literal
				sys->print("%s\n", args[1 : len args - 1]);
			} else if(len args > 1 && args[0] == '\'' && args[len args - 1] == '\'') {
				# String literal
				sys->print("%s\n", args[1 : len args - 1]);
			} else {
				# Number or expression - just print it as-is for now
				sys->print("%s\n", args);
			}
		} else {
			sys->print("\n");
		}
		return Luavm->OK;
	}

	# Handle: type(...)
	if(len code > 4 && code[0:4] == "type") {
		args := code[4:];

		if(len args > 0 && args[0] == '(')
			args = args[1:];

		if(len args > 0 && args[len args - 1] == ')')
			args = args[0 : len args - 1];

		while(len args > 0 && (args[0] == ' ' || args[0] == '\t'))
			args = args[1:];

		# Simple type detection
		if(len args > 1 && ((args[0] == '"' && args[len args - 1] == '"') ||
		                    (args[0] == '\'' && args[len args - 1] == '\''))) {
			sys->print("string\n");
		} else if(args == "nil" || args == "") {
			sys->print("nil\n");
		} else if(args == "true" || args == "false") {
			sys->print("boolean\n");
		} else {
			# Try to parse as number - simple check for digits
			hasdot := 0;
			isnum := 1;
			for(i := 0; i < len args; i++) {
				c := args[i];
				if(c == '.') {
					hasdot++;
					if(hasdot > 1) {
						isnum = 0;
						break;
					}
				} else if(c < '0' || c > '9') {
					isnum = 0;
					break;
				}
			}
			if(isnum && len args > 0)
				sys->print("number\n");
			else
				sys->print("unknown\n");
		}
		return Luavm->OK;
	}

	# Try loadstring for other expressions
	status := luavm->loadstring(L, code);
	if(status != Luavm->OK)
		return status;

	# Execute
	status = luavm->pcall(L, 0, -1);
	if(status != Luavm->OK)
		return status;

	# Print results
	nresults := luavm->gettop(L);
	if(nresults > 0) {
		for(i := 1; i <= nresults; i++) {
			val := luavm->getvalue(L, i);

			s := luavm->tostring(val);
			if(s != nil)
				sys->print("%s", s);

			if(i < nresults)
				sys->print("\t");
		}
		sys->print("\n");
	}

	return Luavm->OK;
}

# ====================================================================
# Standard Library Loading
# ====================================================================

loadstdlibs(L: ref Luavm->State)
{
	if(L == nil)
		return;

	# Register builtin functions in the VM
	luavm->registerbuiltin("print");
	luavm->registerbuiltin("type");
	luavm->registerbuiltin("tostring");
	luavm->registerbuiltin("tonumber");
	luavm->registerbuiltin("error");
	luavm->registerbuiltin("assert");
	luavm->registerbuiltin("ipairs");
	luavm->registerbuiltin("pairs");
	luavm->registerbuiltin("next");

	# Load basic library
	luavm->setglobal(L, "print", luavm->newbuiltin("print"));
	luavm->setglobal(L, "type", luavm->newbuiltin("type"));
	luavm->setglobal(L, "tostring", luavm->newbuiltin("tostring"));
	luavm->setglobal(L, "tonumber", luavm->newbuiltin("tonumber"));
	luavm->setglobal(L, "error", luavm->newbuiltin("error"));
	luavm->setglobal(L, "assert", luavm->newbuiltin("assert"));
	luavm->setglobal(L, "ipairs", luavm->newbuiltin("ipairs"));
	luavm->setglobal(L, "pairs", luavm->newbuiltin("pairs"));
	luavm->setglobal(L, "next", luavm->newbuiltin("next"));

	# Set _VERSION
	versionkey := ref Luavm->Value;
	versionkey.ty = Luavm->TSTRING;
	versionkey.s = "_VERSION";

	versionval := ref Luavm->Value;
	versionval.ty = Luavm->TSTRING;
	versionval.s = "Lua 5.4 (TaijiOS)";

	luavm->setglobal(L, "_VERSION", versionval);
}

# ====================================================================
# Global Variables
# ====================================================================

setargs(L: ref Luavm->State, argv: list of string)
{
	if(L == nil)
		return;

	# Create arg table
	argtable := luavm->createtable(0, 0);

	# Set arg[0] = program name
	if(argv != nil) {
		prog := hd argv;

		key := ref Luavm->Value;
		key.ty = Luavm->TNUMBER;
		key.n = 0.0;

		val := ref Luavm->Value;
		val.ty = Luavm->TSTRING;
		val.s = prog;

		luavm->settablevalue(argtable, key, val);

		# Set arg[1], arg[2], etc.
		argv = tl argv;
		i := 1;

		while(argv != nil) {
			key.n = real(i);
			val.s = hd argv;

			luavm->settablevalue(argtable, key, val);

			argv = tl argv;
			i++;
		}
	}

	# Set global 'arg'
	argkey := ref Luavm->Value;
	argkey.ty = Luavm->TSTRING;
	argkey.s = "arg";

	argval := ref Luavm->Value;
	argval.ty = Luavm->TTABLE;
	argval.t = argtable;

	# luavm->setglobal(L, "arg", argval);
}

setprompt(L: ref Luavm->State)
{
	if(L == nil)
		return;

	# Set _PROMPT variables
	prompt1 := ref Luavm->Value;
	prompt1.ty = Luavm->TSTRING;
	prompt1.s = "> ";

	prompt2 := ref Luavm->Value;
	prompt2.ty = Luavm->TSTRING;
	prompt2.s = ">> ";

	# luavm->setglobal(L, "_PROMPT", prompt1);
	# luavm->setglobal(L, "_PROMPT2", prompt2);
}

# ====================================================================
# Error Printing
# ====================================================================

printerror(L: ref Luavm->State)
{
	if(L == nil)
		return;

	# Get error message from top of stack
	if(L.top > 0) {
		val := luavm->getvalue(L, -1);
		if(val != nil && val.ty == Luavm->TSTRING) {
			sys->fprint(sys->fildes(2), "error: %s\n", val.s);
		} else {
			s := luavm->tostring(val);
			sys->fprint(sys->fildes(2), "error: %s\n", s);
		}
	}
}

# ====================================================================
# Help and Version
# ====================================================================

printbanner()
{
	sys->print("\n");
	sys->print("Lua 5.4 (TaijiOS) [Inferno/Limbo]\n");
	sys->print("Copyright (C) 2025 TaijiOS Project\n");
	sys->print("Type 'help()' for help, 'quit()' to exit\n");
	sys->print("\n");
}

printversion()
{
	sys->print("Lua 5.4 (TaijiOS) [Inferno/Limbo]\n");
	sys->print("Copyright (C) 2025 TaijiOS Project\n");
}

printhelp()
{
	sys->print("Usage: lua [options] [script [args]]\n");
	sys->print("\n");
	sys->print("Options:\n");
	sys->print("  -e stat  Execute string 'stat'\n");
	sys->print("  -i       Enter interactive mode after executing scripts\n");
	sys->print("  -v       Show version information\n");
	sys->print("  -h       Show this help\n");
	sys->print("  --       Stop handling options\n");
	sys->print("  -        Execute stdin and exit\n");
	sys->print("\n");
	sys->print("In interactive mode:\n");
	sys->print("  Empty line clears multi-line buffer\n");
	sys->print("  EOF (Ctrl-D) exits\n");
}
