implement Syntax;

include "sys.m";
include "env.m";
include "syntax.m";

sys : Sys;
env : Env;

init()
{
	sys = load Sys Sys->PATH;
	env = load Env Env->PATH;
}

# Extension mapping ADT
Extmap : adt {
	ext : string;
	lang : string;
};

# Extension map for language detection
extmap := array[] of {
	Extmap(".c", "c"),
	Extmap(".h", "c"),
	Extmap(".m", "limbo"),
	Extmap(".lim", "limbo"),
	Extmap(".kry", "kryon"),
	Extmap(".kryon", "kryon"),
	Extmap(".b", "limbo"),
	Extmap(".lua", "lua"),
	Extmap(".tcl", "tcl"),
	Extmap(".sh", "shell"),
};

# Check if syntax highlighting is enabled
enabled() : int
{
	s := env->getenv("syntax-highlight");
	if (s == nil)
		s = env->getenv("syntax");
	return (s != nil && s != "0");
}

# Detect language from filename and optional content
detect(filename : string, content : string) : string
{
	# Check extension
	(_, ext) := splitext(filename);
	if (ext != nil) {
		for (i := 0; i < len extmap; i++) {
			if (ext == extmap[i].ext)
				return extmap[i].lang;
		}
	}

	# Check content for shebang
	if (content != nil && len content > 2) {
		if (content[0] == '#' && content[1] == '!') {
			if (contains(content, "lua"))
				return "lua";
			if (contains(content, "tcl") || contains(content, "wish"))
				return "tcl";
			if (contains(content, "sh"))
				return "shell";
		}
	}

	return nil;
}

splitext(s : string) : (string, string)
{
	for (i := len s - 1; i >= 0; i--) {
		if (s[i] == '.') {
			if (i > 0 && s[i-1] == '/')
				return (s, "");
			return (s[0:i], s[i:]);
		}
		if (s[i] == '/')
			break;
	}
	return (s, "");
}

contains(s, substr : string) : int
{
	n := len substr;
	for (i := 0; i <= len s - n; i++) {
		if (s[i:i+n] == substr)
			return 1;
	}
	return 0;
}

# Get tokens for language
gettokens(lang : string, text : string, max : int) : array of (int, int, int)
{
	case lang {
	"c" => return tokenize_c(text, max);
	"limbo" => return tokenize_limbo(text, max);
	"kryon" => return tokenize_kryon(text, max);
	"lua" => return tokenize_lua(text, max);
	"tcl" => return tokenize_tcl(text, max);
	"shell" => return tokenize_shell(text, max);
	* => return array[0] of (int, int, int);
	}
}

# C tokenizer
tokenize_c(text : string, max : int) : array of (int, int, int)
{
	if (max <= 0 || max > len text)
		max = len text;

	result : list of (int, int, int);
	i := 0;
	n := len text;

	while (i < n && i < max) {
		# Skip whitespace
		while (i < n && i < max && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r'))
			i++;

		if (i >= n || i >= max)
			break;

		start := i;

		# Single line comment
		if (i+1 < n && text[i] == '/' && text[i+1] == '/') {
			while (i < n && i < max && text[i] != '\n')
				i++;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# Multi-line comment
		if (i+1 < n && text[i] == '/' && text[i+1] == '*') {
			i += 2;
			while (i+1 < n && i < max && !(text[i] == '*' && text[i+1] == '/'))
				i++;
			if (i < n)
				i += 2;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# Preprocessor directive
		if (text[i] == '#') {
			while (i < n && i < max && text[i] != '\n')
				i++;
			result = (start, i, TPRE) :: result;
			continue;
		}

		# String literal
		if (text[i] == '"') {
			i++;
			while (i < n && i < max && text[i] != '"') {
				if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Character literal
		if (text[i] == '\'') {
			i++;
			while (i < n && i < max && text[i] != '\'') {
				if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
			result = (start, i, TCHR) :: result;
			continue;
		}

		# Number (digit)
		if (text[i] >= '0' && text[i] <= '9') {
			while (i < n && i < max && ((text[i] >= '0' && text[i] <= '9') ||
				text[i] == '.' || text[i] == 'x' || text[i] == 'X' ||
				(text[i] >= 'a' && text[i] <= 'f') ||
				(text[i] >= 'A' && text[i] <= 'F') ||
				text[i] == 'l' || text[i] == 'L' ||
				text[i] == 'u' || text[i] == 'U'))
				i++;
			result = (start, i, TNUM) :: result;
			continue;
		}

		# Identifier or keyword
		if ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || text[i] == '_') {
			while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
				(text[i] >= 'A' && text[i] <= 'Z') ||
				(text[i] >= '0' && text[i] <= '9') ||
				text[i] == '_'))
				i++;
			word := text[start:i];
			if (is_c_keyword(word))
				result = (start, i, TKWD) :: result;
			else if (is_c_type(word))
				result = (start, i, TTYPE) :: result;
			else
				result = (start, i, TID) :: result;
			continue;
		}

		# Operators
		if (is_c_operator(text, i)) {
			if (i+1 < n && ((text[i] == '=' && text[i+1] == '=') ||
				(text[i] == '!' && text[i+1] == '=') ||
				(text[i] == '<' && text[i+1] == '=') ||
				(text[i] == '>' && text[i+1] == '=') ||
				(text[i] == '+' && (text[i+1] == '+' || text[i+1] == '=')) ||
				(text[i] == '-' && (text[i+1] == '-' || text[i+1] == '=')) ||
				(text[i] == '&' && (text[i+1] == '&' || text[i+1] == '=')) ||
				(text[i] == '|' && (text[i+1] == '|' || text[i+1] == '=')) ||
				(text[i] == '*' && text[i+1] == '=') ||
				(text[i] == '/' && text[i+1] == '=') ||
				(text[i] == '%' && text[i+1] == '=') ||
				(text[i] == '^' && text[i+1] == '=') ||
				(text[i] == '<' && text[i+1] == '<') ||
				(text[i] == '>' && text[i+1] == '>')))
				i++;
			i++;
			result = (start, i, TOP) :: result;
			continue;
		}

		# Default: advance one character
		i++;
	}

	return revlist(result);
}

is_c_keyword(word : string) : int
{
	keywords := "auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|int|long|register|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while";
	return contains_pattern(keywords, word);
}

is_c_type(word : string) : int
{
	types := "int|char|short|long|float|double|void|unsigned|signed|bool|size_t|uint8_t|int8_t|uint16_t|int16_t|uint32_t|int32_t|uint64_t|int64_t";
	return contains_pattern(types, word);
}

contains_pattern(pattern : string, word : string) : int
{
	(_, parts) := sys->tokenize(pattern, "|");
	for (; parts != nil; parts = tl parts) {
		if (hd parts == word)
			return 1;
	}
	return 0;
}

is_c_operator(text : string, i : int) : int
{
	c := text[i];
	return c == '+' || c == '-' || c == '*' || c == '/' || c == '%' ||
		c == '=' || c == '!' || c == '<' || c == '>' ||
		c == '&' || c == '|' || c == '^' || c == '?';
}

# Limbo tokenizer (similar to C but with Limbo keywords)
tokenize_limbo(text : string, max : int) : array of (int, int, int)
{
	if (max <= 0 || max > len text)
		max = len text;

	result : list of (int, int, int);
	i := 0;
	n := len text;

	while (i < n && i < max) {
		# Skip whitespace
		while (i < n && i < max && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r'))
			i++;

		if (i >= n || i >= max)
			break;

		start := i;

		# Single line comment (# or #)
		if (i+1 < n && ((text[i] == '/' && text[i+1] == '/') || text[i] == '#')) {
			while (i < n && i < max && text[i] != '\n')
				i++;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# Multi-line comment
		if (i+1 < n && text[i] == '/' && text[i+1] == '*') {
			i += 2;
			while (i+1 < n && i < max && !(text[i] == '*' && text[i+1] == '/'))
				i++;
			if (i < n)
				i += 2;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# String literal
		if (text[i] == '"') {
			i++;
			while (i < n && i < max && text[i] != '"') {
				if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Number
		if (text[i] >= '0' && text[i] <= '9') {
			while (i < n && i < max && ((text[i] >= '0' && text[i] <= '9') ||
				text[i] == '.' || text[i] == 'x' || text[i] == 'X' ||
				(text[i] >= 'a' && text[i] <= 'f') ||
				(text[i] >= 'A' && text[i] <= 'F') ||
				text[i] == 'i' || text[i] == 'I'))
				i++;
			result = (start, i, TNUM) :: result;
			continue;
		}

		# Identifier or keyword
		if ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || text[i] == '_') {
			while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
				(text[i] >= 'A' && text[i] <= 'Z') ||
				(text[i] >= '0' && text[i] <= '9') ||
				text[i] == '_'))
				i++;
			word := text[start:i];
			if (is_limbo_keyword(word))
				result = (start, i, TKWD) :: result;
			else if (is_limbo_type(word))
				result = (start, i, TTYPE) :: result;
			else
				result = (start, i, TID) :: result;
			continue;
		}

		# Operators
		if (is_c_operator(text, i)) {
			if (i+1 < n && ((text[i] == '=' && text[i+1] == '=') ||
				(text[i] == '!' && text[i+1] == '=') ||
				(text[i] == '<' && text[i+1] == '=') ||
				(text[i] == '>' && text[i+1] == '=') ||
				(text[i] == '+' && (text[i+1] == '+' || text[i+1] == '=')) ||
				(text[i] == '-' && (text[i+1] == '-' || text[i+1] == '=')) ||
				(text[i] == '&' && (text[i+1] == '&' || text[i+1] == '=')) ||
				(text[i] == '|' && (text[i+1] == '|' || text[i+1] == '=')) ||
				(text[i] == '*' && text[i+1] == '=') ||
				(text[i] == '/' && text[i+1] == '=') ||
				(text[i] == '%' && text[i+1] == '=') ||
				(text[i] == '^' && text[i+1] == '=') ||
				(text[i] == '<' && text[i+1] == '<') ||
				(text[i] == '>' && text[i+1] == '>')))
				i++;
			i++;
			result = (start, i, TOP) :: result;
			continue;
		}

		i++;
	}

	return revlist(result);
}

is_limbo_keyword(word : string) : int
{
	keywords := "alt|break|case|con|continue|cyclic|do|else|for|if|implement|import|include|init|len|load|lock|module|return|self|spawn|typeof|while";
	return contains_pattern(keywords, word);
}

is_limbo_type(word : string) : int
{
	types := "int|big|real|string|byte|list|array|chan|fn|ref|adt";
	return contains_pattern(types, word);
}

# Kryon tokenizer (similar to Limbo)
tokenize_kryon(text : string, max : int) : array of (int, int, int)
{
	return tokenize_limbo(text, max);
}

# Lua tokenizer
tokenize_lua(text : string, max : int) : array of (int, int, int)
{
	if (max <= 0 || max > len text)
		max = len text;

	result : list of (int, int, int);
	i := 0;
	n := len text;

	while (i < n && i < max) {
		# Skip whitespace
		while (i < n && i < max && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r'))
			i++;

		if (i >= n || i >= max)
			break;

		start := i;

		# Single line comment
		if (i+1 < n && text[i] == '-' && text[i+1] == '-') {
			while (i < n && i < max && text[i] != '\n')
				i++;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# Multi-line comment
		if (i+3 < n && text[i] == '-' && text[i+1] == '-' && text[i+2] == '[' && text[i+3] == '[') {
			i += 4;
			while (i+1 < n && i < max && !(text[i] == ']' && text[i+1] == ']'))
				i++;
			if (i < n)
				i += 2;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# String literal
		if (text[i] == '"' || text[i] == '\'') {
			quote := text[i];
			i++;
			while (i < n && i < max && text[i] != quote) {
				if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Number
		if (text[i] >= '0' && text[i] <= '9') {
			while (i < n && i < max && ((text[i] >= '0' && text[i] <= '9') ||
				text[i] == '.' || text[i] == 'e' || text[i] == 'E' ||
				text[i] == '+' || text[i] == '-'))
				i++;
			result = (start, i, TNUM) :: result;
			continue;
		}

		# Identifier or keyword
		if ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || text[i] == '_') {
			while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
				(text[i] >= 'A' && text[i] <= 'Z') ||
				(text[i] >= '0' && text[i] <= '9') ||
				text[i] == '_'))
				i++;
			word := text[start:i];
			if (is_lua_keyword(word))
				result = (start, i, TKWD) :: result;
			else if (is_lua_builtin(word))
				result = (start, i, TFN) :: result;
			else
				result = (start, i, TID) :: result;
			continue;
		}

		i++;
	}

	return revlist(result);
}

is_lua_keyword(word : string) : int
{
	keywords := "and|break|do|else|elseif|end|false|for|function|if|in|local|nil|not|or|repeat|return|then|true|until|while";
	return contains_pattern(keywords, word);
}

is_lua_builtin(word : string) : int
{
	builtins := "print|type|tostring|tonumber|ipairs|pairs|table|string|math|io|os|coroutine";
	return contains_pattern(builtins, word);
}

# Tcl tokenizer
tokenize_tcl(text : string, max : int) : array of (int, int, int)
{
	if (max <= 0 || max > len text)
		max = len text;

	result : list of (int, int, int);
	i := 0;
	n := len text;

	while (i < n && i < max) {
		# Skip whitespace
		while (i < n && i < max && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r'))
			i++;

		if (i >= n || i >= max)
			break;

		start := i;

		# Comment
		if (text[i] == '#') {
			while (i < n && i < max && text[i] != '\n')
				i++;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# String literal
		if (text[i] == '"') {
			i++;
			while (i < n && i < max && text[i] != '"') {
				if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Brace group (treat as string)
		if (text[i] == '{') {
			depth := 1;
			i++;
			while (i < n && i < max && depth > 0) {
				if (text[i] == '{')
					depth++;
				else if (text[i] == '}')
					depth--;
				else if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Variable
		if (text[i] == '$') {
			i++;
			if (i < n && text[i] == '{') {
				while (i < n && i < max && text[i] != '}')
					i++;
				if (i < n)
					i++;
			} else {
				while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
					(text[i] >= 'A' && text[i] <= 'Z') ||
					(text[i] >= '0' && text[i] <= '9') ||
					text[i] == '_'))
					i++;
			}
			result = (start, i, TTYPE) :: result;
			continue;
		}

		# Number
		if (text[i] >= '0' && text[i] <= '9') {
			while (i < n && i < max && ((text[i] >= '0' && text[i] <= '9') ||
				text[i] == '.' || text[i] == 'e' || text[i] == 'E'))
				i++;
			result = (start, i, TNUM) :: result;
			continue;
		}

		# Identifier or keyword
		if ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || text[i] == '_') {
			while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
				(text[i] >= 'A' && text[i] <= 'Z') ||
				(text[i] >= '0' && text[i] <= '9') ||
				text[i] == '_'))
				i++;
			word := text[start:i];
			if (is_tcl_keyword(word))
				result = (start, i, TKWD) :: result;
			else
				result = (start, i, TID) :: result;
			continue;
		}

		i++;
	}

	return revlist(result);
}

is_tcl_keyword(word : string) : int
{
	keywords := "if|then|else|elseif|for|foreach|while|break|continue|return|proc|global|upvar|set|incr|append|lappend|lassign|lindex|llength|lrange|lsearch|lreplace|lsort|concat|join|split|format|scan|expr|catch|error|switch|package|namespace|class|inherit|public|private|protected";
	return contains_pattern(keywords, word);
}

# Shell tokenizer
tokenize_shell(text : string, max : int) : array of (int, int, int)
{
	if (max <= 0 || max > len text)
		max = len text;

	result : list of (int, int, int);
	i := 0;
	n := len text;

	while (i < n && i < max) {
		# Skip whitespace
		while (i < n && i < max && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r'))
			i++;

		if (i >= n || i >= max)
			break;

		start := i;

		# Comment
		if (text[i] == '#') {
			while (i < n && i < max && text[i] != '\n')
				i++;
			result = (start, i, TCOM) :: result;
			continue;
		}

		# String literal
		if (text[i] == '"') {
			i++;
			while (i < n && i < max && text[i] != '"') {
				if (text[i] == '\\' && i+1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Single quoted string
		if (text[i] == '\'') {
			i++;
			while (i < n && i < max && text[i] != '\'')
				i++;
			if (i < n)
				i++;
			result = (start, i, TSTR) :: result;
			continue;
		}

		# Variable
		if (text[i] == '$') {
			i++;
			if (i < n && text[i] == '{') {
				while (i < n && i < max && text[i] != '}')
					i++;
				if (i < n)
					i++;
			} else {
				while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
					(text[i] >= 'A' && text[i] <= 'Z') ||
					(text[i] >= '0' && text[i] <= '9') ||
					text[i] == '_'))
					i++;
			}
			result = (start, i, TTYPE) :: result;
			continue;
		}

		# Number
		if (text[i] >= '0' && text[i] <= '9') {
			while (i < n && i < max && ((text[i] >= '0' && text[i] <= '9') ||
				text[i] == '.'))
				i++;
			result = (start, i, TNUM) :: result;
			continue;
		}

		# Identifier or keyword
		if ((text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || text[i] == '_') {
			while (i < n && i < max && ((text[i] >= 'a' && text[i] <= 'z') ||
				(text[i] >= 'A' && text[i] <= 'Z') ||
				(text[i] >= '0' && text[i] <= '9') ||
				text[i] == '_'))
				i++;
			word := text[start:i];
			if (is_shell_keyword(word))
				result = (start, i, TKWD) :: result;
			else
				result = (start, i, TID) :: result;
			continue;
		}

		i++;
	}

	return revlist(result);
}

is_shell_keyword(word : string) : int
{
	keywords := "if|then|else|elif|fi|for|while|do|done|case|esac|function|select|until|in|time|return|break|continue|true|false|local|readonly|export|shift|unset|exec|eval|source|read|echo|printf|test|cd|pwd|exit|trap|wait|jobs|kill|bg|fg|set|unset";
	return contains_pattern(keywords, word);
}

# Helper to reverse a list and convert to array
revlist(l : list of (int, int, int)) : array of (int, int, int)
{
	n := len l;
	if (n == 0)
		return array[0] of (int, int, int);

	result := array[n] of (int, int, int);
	for (i := n - 1; i >= 0; i--) {
		result[i] = hd l;
		l = tl l;
	}
	return result;
}
