# Lua VM Test Suite
# Tests for the complete Lua 5.4 parser and bytecode compiler

implement LuaTest;

include "sys.m";
include "luavm.m";
include "draw.m";

sys: Sys;
print, fprint: import sys;

# Test result structure
TestResult: adt {
	name: string;
	passed: int;
	message: string;
};

# Run a single test
run_test(name: string, test_code: string, expected: int): ref TestResult
{
	result := ref TestResult;
	result.name = name;

	# Initialize Lua VM
	err := Luavm->init();
	if(err != nil) {
		result.passed = 0;
		result.message = "Failed to initialize VM";
		return result;
	}

	# Create Lua state
	L := Luavm->newstate();
	if(L == nil) {
		result.passed = 0;
		result.message = "Failed to create state";
		return result;
	}

	# Load and execute the test code
	status := Luavm->loadstring(L, test_code);
	if(status != Luavm->OK) {
		result.passed = 0;
		result.message = "Failed to load code";
		return result;
	}

	# For now, just check if load succeeded
	result.passed = 1;
	result.message = "Test passed";

	# Clean up
	Luavm->close(L);

	return result;
}

# Test basic expressions
test_basic_expressions(): ref TestResult
{
	code := "
return 1 + 2
";

	return run_test("basic expressions", code, 1);
}

# Test number parsing
test_numbers(): ref TestResult
{
	code := "
local x = 42
local y = 3.14
local z = 0xFF
return x + y + z
";

	return run_test("numbers", code, 1);
}

# Test string parsing
test_strings(): ref TestResult
{
	code := "
local s = \"Hello\"
local t = 'World'
return s .. t
";

	return run_test("strings", code, 1);
}

# Test if statement
test_if_statement(): ref TestResult
{
	code := "
local x = 10
if x > 5 then
	return 1
else
	return 0
end
";

	return run_test("if statement", code, 1);
}

# Test while loop
test_while_loop(): ref TestResult
{
	code := "
local sum = 0
local i = 1
while i <= 10 do
	sum = sum + i
	i = i + 1
end
return sum
";

	return run_test("while loop", code, 1);
}

# Test table constructor
test_table_constructor(): ref TestResult
{
	code := "
local t = {1, 2, 3}
return t[1]
";

	return run_test("table constructor", code, 1);
}

# Test function definition
test_function_definition(): ref TestResult
{
	code := "
function add(a, b)
	return a + b
end
return add(5, 3)
";

	return run_test("function definition", code, 1);
}

# Test local variables
test_local_variables(): ref TestResult
{
	code := "
local x = 10
local y = 20
return x + y
";

	return run_test("local variables", code, 1);
}

# Test boolean operations
test_booleans(): ref TestResult
{
	code := "
local a = true
local b = false
return a and not b
";

	return run_test("booleans", code, 1);
}

# Test comparison operators
test_comparisons(): ref TestResult
{
	code := "
local a = 5
local b = 10
return a < b
";

	return run_test("comparisons", code, 1);
}

# Main test runner
main()
{
	sys = load Sys "/dis/lib/sys.dis";

	print("Lua VM Test Suite\n");
	print("================\n\n");

	tests := array[] of {
		test_basic_expressions,
		test_numbers,
		test_strings,
		test_if_statement,
		test_while_loop,
		test_table_constructor,
		test_function_definition,
		test_local_variables,
		test_booleans,
		test_comparisons
	};

	passed := 0;
	failed := 0;

	for(i := 0; i < len tests; i++) {
		result := tests[i]();
		if(result.passed) {
			print(sprint("PASS: %s\n", result.name));
			passed++;
		} else {
			print(sprint("FAIL: %s - %s\n", result.name, result.message));
			failed++;
		}
	}

	print(sprint("\nResults: %d passed, %d failed\n", passed, failed));

	if(failed == 0)
		print("All tests passed!\n");
	else
		print("Some tests failed.\n");
}
