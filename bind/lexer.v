module bind

// The template-expression lexer shared by free_idents (phase 03) and component
// codegen's qualify (phase 04), so both agree on what an identifier is.
//
// It is LOSSLESS: concatenating every token's `text` gives back the input, so a
// rewriter can copy tokens through and only replace the identifiers it
// qualifies. It knows V's literal forms — numbers (`1e5`, `0xff`, `1_000`),
// escaped and `${}`-interpolated strings, `rune`s — and V's keywords and builtin
// type names, so none of those are mistaken for references to the component.

pub enum TokenKind {
	ident    // a free identifier: `count`, `user` in `user.name`
	member   // an identifier right after `.`: `name` in `user.name`
	keyword  // a V keyword or builtin type: `in`, `if`, `none`, `int`, `it`
	number   // a numeric literal
	str      // literal text of a string (quotes and plain parts)
	interp   // the `${` or `}` around an interpolation inside a string
	rune_lit // a `rune` literal
	space    // whitespace
	punct    // any other byte: operators, parens, brackets, commas, dots
}

pub struct Token {
pub:
	kind TokenKind
	text string
}

fn tok(kind TokenKind, text string) Token {
	return Token{
		kind: kind
		text: text
	}
}

// keywords are V's syntax in an expression (`if`, `in`, `none`, …), so they are
// never references to the component, even if it has a field of that name.
const keywords = ['as', 'asm', 'assert', 'atomic', 'break', 'const', 'continue', 'defer', 'else',
	'enum', 'false', 'fn', 'for', 'go', 'goto', 'if', 'import', 'in', 'interface', 'is', 'isreftype',
	'lock', 'match', 'module', 'mut', 'none', 'or', 'pub', 'return', 'rlock', 'select', 'shared',
	'sizeof', 'spawn', 'static', 'struct', 'true', 'typeof', 'union', 'unsafe', 'volatile']

// soft_keywords are names V reserves that are not syntax in an expression, so a
// component may use them as a field or method name: `type`, the builtin type
// names (usable as casts, `int(x)`), and `it` (the implicit param of `filter`,
// `map`, `any`, `all`, `count`). They lex as .keyword; codegen's qualify still
// qualifies one the component defines, unless V reads it as syntax there.
const soft_keywords = ['type', 'bool', 'string', 'rune', 'byte', 'u8', 'u16', 'u32', 'u64', 'usize',
	'i8', 'i16', 'int', 'i32', 'i64', 'isize', 'f32', 'f64', 'voidptr', 'it']

// is_soft_keyword reports whether `name` is one of soft_keywords.
pub fn is_soft_keyword(name string) bool {
	return name in soft_keywords
}

// tokens splits a template expression into lossless tokens (see the module doc).
pub fn tokens(expr string) []Token {
	mut out := []Token{}
	lex_into(expr, 0, expr.len, mut out)
	return out
}

fn lex_into(s string, from int, to int, mut out []Token) {
	mut i := from
	for i < to {
		c := s[i]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
			start := i
			for i < to && (s[i] == ` ` || s[i] == `\t` || s[i] == `\n` || s[i] == `\r`) {
				i++
			}
			out << tok(.space, s[start..i])
		} else if c == `'` || c == `"` {
			i = lex_string(s, i, to, mut out)
		} else if c == `\`` {
			start := i
			i++
			for i < to && s[i] != `\`` {
				if s[i] == `\\` {
					i++
				}
				i++
			}
			i = if i < to { i + 1 } else { to }
			out << tok(.rune_lit, s[start..i])
		} else if is_digit(c) {
			start := i
			i = scan_number(s, i, to)
			out << tok(.number, s[start..i])
		} else if is_ident_start(c) {
			start := i
			for i < to && is_ident_part(s[i]) {
				i++
			}
			name := s[start..i]
			kind := if prev_is_dot(out) {
				TokenKind.member
			} else if name in keywords || name in soft_keywords {
				TokenKind.keyword
			} else {
				TokenKind.ident
			}
			out << tok(kind, name)
		} else {
			out << tok(.punct, s[i..i + 1])
			i++
		}
	}
}

// lex_string emits a quoted string starting at `i` (the quote): its literal
// parts as .str tokens and each `${ expr }` as .interp + the expression's own
// tokens + .interp, so identifiers inside interpolations are seen too. A format
// spec (`${price:.2f}`) is part of the string: a .str token. Returns the index
// just past the closing quote (or `to` if unterminated).
fn lex_string(s string, i0 int, to int, mut out []Token) int {
	q := s[i0]
	mut i := i0 + 1
	mut seg := i0
	for i < to && s[i] != q {
		if s[i] == `\\` {
			i += 2
			continue
		}
		if s[i] == `$` && i + 1 < to && s[i + 1] == `{` {
			out << tok(.str, s[seg..i])
			out << tok(.interp, '\${')
			close := matching_brace(s, i + 2, to)
			spec := format_spec_start(s, i + 2, close)
			lex_into(s, i + 2, spec, mut out)
			if spec < close {
				out << tok(.str, s[spec..close])
			}
			if close < to {
				out << tok(.interp, '}')
				i = close + 1
			} else {
				i = to
			}
			seg = i
			continue
		}
		i++
	}
	end := if i < to { i + 1 } else { to }
	out << tok(.str, s[seg..end])
	return end
}

// matching_brace finds the `}` closing a `${` whose body starts at `from`,
// skipping nested braces, quoted strings and runes; `to` if there is none.
fn matching_brace(s string, from int, to int) int {
	mut depth := 0
	mut i := from
	for i < to {
		c := s[i]
		if c == `'` || c == `"` || c == `\`` {
			i = skip_quoted(s, i, to)
			continue
		}
		if c == `{` {
			depth++
		} else if c == `}` {
			if depth == 0 {
				return i
			}
			depth--
		}
		i++
	}
	return to
}

// format_spec_start finds where a `${…}` body's format spec begins: its first
// `:` outside brackets, braces, parens, strings and runes (V has no `?:`, so
// that `:` can only start one); `to` if there is none.
fn format_spec_start(s string, from int, to int) int {
	mut depth := 0
	mut i := from
	for i < to {
		c := s[i]
		if c == `'` || c == `"` || c == `\`` {
			i = skip_quoted(s, i, to)
			continue
		}
		if c in [`(`, `[`, `{`] {
			depth++
		} else if c in [`)`, `]`, `}`] {
			depth--
		} else if c == `:` && depth == 0 {
			return i
		}
		i++
	}
	return to
}

// skip_quoted returns the index just past the string or rune literal starting
// at `i` (its quote), honouring backslash escapes.
fn skip_quoted(s string, i int, to int) int {
	q := s[i]
	mut j := i + 1
	for j < to && s[j] != q {
		if s[j] == `\\` {
			j++
		}
		j++
	}
	return if j < to { j + 1 } else { to }
}

// scan_number consumes a V numeric literal: decimal with `_` separators, an
// optional fraction and exponent, or a 0x/0o/0b-prefixed integer.
fn scan_number(s string, i0 int, to int) int {
	mut i := i0
	if s[i] == `0` && i + 1 < to && s[i + 1] in [`x`, `X`, `o`, `O`, `b`, `B`] {
		i += 2
		for i < to && (is_ident_part(s[i])) {
			i++
		}
		return i
	}
	for i < to && (is_digit(s[i]) || s[i] == `_`) {
		i++
	}
	// a fraction, but not a range (`0..n`) or a method call on an int (`1.str()`)
	if i + 1 < to && s[i] == `.` && is_digit(s[i + 1]) {
		i++
		for i < to && (is_digit(s[i]) || s[i] == `_`) {
			i++
		}
	}
	if i < to && (s[i] == `e` || s[i] == `E`) {
		mut j := i + 1
		if j < to && (s[j] == `+` || s[j] == `-`) {
			j++
		}
		if j < to && is_digit(s[j]) {
			i = j
			for i < to && is_digit(s[i]) {
				i++
			}
		}
	}
	return i
}

// prev_is_dot reports whether the last non-space token is a lone `.` punct, so
// the identifier about to be emitted is a member access (`user.name`) — but not
// the end of a range (`0..n`).
fn prev_is_dot(out []Token) bool {
	for k := out.len - 1; k >= 0; k-- {
		if out[k].kind == .space {
			continue
		}
		is_dot := out[k].kind == .punct && out[k].text == '.'
		return is_dot && !(k > 0 && out[k - 1].kind == .punct && out[k - 1].text == '.')
	}
	return false
}

fn is_digit(c u8) bool {
	return c >= `0` && c <= `9`
}

pub fn is_ident_start(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

pub fn is_ident_part(c u8) bool {
	return is_ident_start(c) || is_digit(c)
}
