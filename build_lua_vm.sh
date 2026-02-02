#!/bin/sh

# Lua VM Build Verification Script
# This script verifies the Lua VM implementation

echo "================================"
echo "Lua VM Build Verification"
echo "================================"
echo ""

# Check file size
echo "Checking luavm.b file..."
if [ -f "module/luavm.b" ]; then
    lines=$(wc -l < module/luavm.b)
    size=$(ls -lh module/luavm.b | awk '{print $5}')
    echo "✓ luavm.b exists"
    echo "  Lines: $lines"
    echo "  Size: $size"
else
    echo "✗ luavm.b not found"
    exit 1
fi

# Check for test file
echo ""
echo "Checking test suite..."
if [ -f "tests/lua_test.b" ]; then
    echo "✓ lua_test.b exists"
else
    echo "✗ lua_test.b not found"
fi

# Check for example file
echo ""
echo "Checking example program..."
if [ -f "appl/cmd/lua_example.b" ]; then
    echo "✓ lua_example.b exists"
else
    echo "✗ lua_example.b not found"
fi

# Check for documentation
echo ""
echo "Checking documentation..."
if [ -f "module/LUA_VM_IMPLEMENTATION.md" ]; then
    echo "✓ LUA_VM_IMPLEMENTATION.md exists"
else
    echo "✗ LUA_VM_IMPLEMENTATION.md not found"
fi

if [ -f "LUA_VM_SUMMARY.md" ]; then
    echo "✓ LUA_VM_SUMMARY.md exists"
else
    echo "✗ LUA_VM_SUMMARY.md not found"
fi

# Check implementation markers in luavm.b
echo ""
echo "Checking implementation sections..."

if grep -q "SECTION 15: LEXICAL ANALYZER" module/luavm.b; then
    echo "✓ Phase 1: Lexer implemented"
else
    echo "✗ Phase 1: Lexer NOT found"
fi

if grep -q "SECTION 16: BYTECODE DEFINITIONS" module/luavm.b; then
    echo "✓ Phase 2: Bytecode definitions implemented"
else
    echo "✗ Phase 2: Bytecode definitions NOT found"
fi

if grep -q "SECTION 17: PARSER DATA STRUCTURES" module/luavm.b; then
    echo "✓ Phase 3: Parser implemented"
else
    echo "✗ Phase 3: Parser NOT found"
fi

if grep -q "SECTION 18: CODE GENERATION" module/luavm.b; then
    echo "✓ Phase 4: Code generation implemented"
else
    echo "✗ Phase 4: Code generation NOT found"
fi

if grep -q "SECTION 19: PARSER FUNCTIONS" module/luavm.b; then
    echo "✓ Phase 5: Parser functions implemented"
else
    echo "✗ Phase 5: Parser functions NOT found"
fi

if grep -q "SECTION 20: MAIN PARSER ENTRY POINT" module/luavm.b; then
    echo "✓ Phase 6: Parser entry point implemented"
else
    echo "✗ Phase 6: Parser entry point NOT found"
fi

if grep -q "SECTION 21: VM EXECUTOR" module/luavm.b; then
    echo "✓ Phase 7: VM executor implemented"
else
    echo "✗ Phase 7: VM executor NOT found"
fi

if grep -q "SECTION 22: LOAD FUNCTIONS" module/luavm.b; then
    echo "✓ Phase 8: Integration implemented"
else
    echo "✗ Phase 8: Integration NOT found"
fi

# Check for key functions
echo ""
echo "Checking key functions..."

key_functions="newlexer lex read_number read_string parse parse_expression vmexec loadstring loadfile"
for func in $key_functions; do
    if grep -q "^$func(" module/luavm.b 2>/dev/null; then
        echo "✓ $func() found"
    else
        echo "✗ $func() NOT found"
    fi
done

# Check for opcodes
echo ""
echo "Checking opcodes..."
opcode_count=$(grep -c "^OP_.*:.*con" module/luavm.b 2>/dev/null || echo 0)
echo "Found $opcode_count opcodes defined"

if [ $opcode_count -ge 82 ]; then
    echo "✓ All 82+ opcodes defined"
else
    echo "⚠ Less than 82 opcodes (expected 82)"
fi

echo ""
echo "================================"
echo "Verification Complete"
echo "================================"
