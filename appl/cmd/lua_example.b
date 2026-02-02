# Lua Example - Demonstrate Lua VM capabilities
# This program shows how to use the Lua VM from Limbo

implement Luaexample;

include "sys.m";
include "luavm.m";

sys: Sys;
print, sprint, fprint: import sys;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	# Initialize Lua VM
	print("Initializing Lua VM...\n");
	err := Luavm->init();
	if(err != nil) {
		fprint(sys->fildes(2), "Failed to initialize Lua VM: %s\n", err);
		return;
	}

	# Create Lua state
	print("Creating Lua state...\n");
	L := Luavm->newstate();
	if(L == nil) {
		fprint(sys->fildes(2), "Failed to create Lua state\n");
		return;
	}

	# Example 1: Simple arithmetic
	print("\n=== Example 1: Simple Arithmetic ===\n");
	code1 := "return 2 + 3 * 4";
	print("Code: ", code1, "\n");
	status := Luavm->loadstring(L, code1);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 2: Variable declaration
	print("\n=== Example 2: Variables ===\n");
	code2 := "
local x = 10
local y = 20
return x + y
";
	print("Code: ", code2, "\n");
	status = Luavm->loadstring(L, code2);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 3: If statement
	print("\n=== Example 3: If Statement ===\n");
	code3 := "
local x = 15
if x > 10 then
	return \"greater\"
else
	return \"smaller\"
end
";
	print("Code: ", code3, "\n");
	status = Luavm->loadstring(L, code3);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 4: While loop
	print("\n=== Example 4: While Loop ===\n");
	code4 := "
local sum = 0
local i = 1
while i <= 5 do
	sum = sum + i
	i = i + 1
end
return sum
";
	print("Code: ", code4, "\n");
	status = Luavm->loadstring(L, code4);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 5: Function definition
	print("\n=== Example 5: Function Definition ===\n");
	code5 := "
function factorial(n)
	if n <= 1 then
		return 1
	else
		return n * factorial(n - 1)
	end
end
return factorial(5)
";
	print("Code: ", code5, "\n");
	status = Luavm->loadstring(L, code5);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 6: Table operations
	print("\n=== Example 6: Table Constructor ===\n");
	code6 := "
local t = {1, 2, 3, 4, 5}
return t[1] + t[5]
";
	print("Code: ", code6, "\n");
	status = Luavm->loadstring(L, code6);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 7: String operations
	print("\n=== Example 7: String Operations ===\n");
	code7 := "
local s1 = \"Hello\"
local s2 = \"World\"
return s1 .. \" \" .. s2
";
	print("Code: ", code7, "\n");
	status = Luavm->loadstring(L, code7);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 8: Boolean operations
	print("\n=== Example 8: Boolean Operations ===\n");
	code8 := "
local a = true
local b = false
return a and not b
";
	print("Code: ", code8, "\n");
	status = Luavm->loadstring(L, code8);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 9: Comparison operators
	print("\n=== Example 9: Comparison Operators ===\n");
	code9 := "
local a = 5
local b = 10
return a < b and b > a
";
	print("Code: ", code9, "\n");
	status = Luavm->loadstring(L, code9);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Example 10: For loop
	print("\n=== Example 10: For Loop ===\n");
	code10 := "
local sum = 0
for i = 1, 10 do
	sum = sum + i
end
return sum
";
	print("Code: ", code10, "\n");
	status = Luavm->loadstring(L, code10);
	if(status == Luavm->OK) {
		print("Status: OK\n");
	} else {
		print(sprint("Status: Error %d\n", status));
	}

	# Clean up
	print("\nCleaning up...\n");
	Luavm->close(L);

	print("\nAll examples completed!\n");
}
