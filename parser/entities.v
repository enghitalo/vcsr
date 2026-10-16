module parser

import strings

// Character references (`&amp;`, `&copy`, `&#169;`, `&#x1F600;`), decoded the way
// a browser's HTML parser decodes them, so text vcsr sets through textContent
// (and the native mock's DOM) reads exactly like the markup the browser parses.
// The names are the full HTML5 table (entity_table.v).

// decode_entities decodes the character references in HTML text: every HTML5
// named reference (the legacy ones, like `&copy`, also without a `;`), and
// numeric ones with the HTML fix-ups (0x80–0x9F read as windows-1252; 0,
// surrogates and anything past U+10FFFF become U+FFFD). Anything else, like
// `&bogus;` or a bare `&`, stays as written.
pub fn decode_entities(s string) string {
	return decode_refs(s, false)
}

// decode_attr_entities is decode_entities for an attribute value, where HTML
// keeps a legacy reference without `;` as written when `=` or a letter or digit
// follows it (`?a=1&copy=2` stays a query string).
pub fn decode_attr_entities(s string) string {
	return decode_refs(s, true)
}

// the longest name in the table, `CounterClockwiseContourIntegral;`
const max_entity_len = 32

// windows-1252 for the C1 controls 0x80–0x9F (0: keep the code point)
const c1_remap = [u32(0x20AC), 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030,
	0x0160, 0x2039, 0x0152, 0, 0x017D, 0, 0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178]

fn decode_refs(s string, in_attr bool) string {
	if !s.contains('&') {
		return s
	}
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		if s[i] == `&` {
			text, next := if i + 1 < s.len && s[i + 1] == `#` {
				numeric_ref(s, i)
			} else {
				named_ref(s, i, in_attr)
			}
			if next > i {
				out.write_string(text)
				i = next
				continue
			}
		}
		out.write_u8(s[i])
		i++
	}
	return out.str()
}

// named_ref decodes the named reference at s[i] (an `&`) and returns it with the
// index after it, or ('', i) when there is none: the longest name in the table
// that matches wins, and only a legacy name may go without its `;`.
fn named_ref(s string, i int, in_attr bool) (string, int) {
	mut j := i + 1
	for j < s.len && j - i <= max_entity_len && is_alnum(s[j]) {
		j++
	}
	if j < s.len && s[j] == `;` {
		v := html5_entities[s[i + 1..j + 1]] or { '' }
		if v != '' {
			return v, j + 1
		}
	}
	for k := j; k > i + 1; k-- {
		v := html5_entities[s[i + 1..k]] or { '' }
		if v == '' {
			continue
		}
		if in_attr && k < s.len && (s[k] == `=` || is_alnum(s[k])) {
			break
		}
		return v, k
	}
	return '', i
}

// numeric_ref decodes the `&#…` at s[i] (`&#169;`, `&#xA9`, the `;` is
// optional) and returns it with the index after it, or ('', i) when no digits
// follow.
fn numeric_ref(s string, i int) (string, int) {
	mut j := i + 2
	hex := j < s.len && (s[j] == `x` || s[j] == `X`)
	if hex {
		j++
	}
	start := j
	mut cp := u32(0)
	for j < s.len {
		d := digit_value(s[j], hex)
		if d < 0 {
			break
		}
		if cp <= 0x10FFFF { // past that it stays invalid; stop before it overflows
			cp = cp * (if hex { u32(16) } else { u32(10) }) + u32(d)
		}
		j++
	}
	if j == start {
		return '', i
	}
	if j < s.len && s[j] == `;` {
		j++
	}
	if cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
		return '�', j
	}
	if cp >= 0x80 && cp <= 0x9F && c1_remap[cp - 0x80] != 0 {
		return rune(c1_remap[cp - 0x80]).str(), j
	}
	return rune(cp).str(), j
}

fn digit_value(c u8, hex bool) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if hex && c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if hex && c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}

fn is_alnum(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}
