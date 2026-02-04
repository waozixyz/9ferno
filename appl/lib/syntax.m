Syntax : module {
	PATH : con "/dis/lib/syntax.dis";

	# Token type constants
	TKWD, TSTR, TCHR, TNUM, TCOM, TTYPE, TFN, TOP, TPRE, TID : con iota;

	# Initialization
	init : fn();

	# Language detection
	detect : fn(filename : string, content : string) : string;

	# Tokenization - returns array of (start, end, type)
	gettokens : fn(lang : string, text : string, max : int) : array of (int, int, int);

	# Configuration check
	enabled : fn() : int;
};
