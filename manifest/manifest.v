// Phase 09 — Manifest: vcsr's own build record for a dist/ bundle.
//
// dist/manifest.json is NOT consumed by the server. vanilla's
// http_server.static_assets derives Content-Type / Cache-Control / encoding from
// the FILENAMES plus its `*.[hash].*` immutable glob (see
// ../docs/VANILLA-STATIC-ASSETS.md). The manifest is vcsr's record — read by the
// JS loader and by tooling/integrity checks: per-asset content type + cache
// policy, the route→chunk map, preload hints, and the SPA-fallback entrypoint.
//
// This module loads and queries that record. Emitting it is phase 08 (bundle).
module manifest

import os
import x.json2

// Entry is one asset's recorded metadata. `content_type`/`cache` mirror what
// static_assets will derive from the filename — recorded here for tooling, not
// for the server.
pub struct Entry {
pub:
	name         string
	content_type string
	cache        string
}

// Manifest is the parsed dist/manifest.json build record.
pub struct Manifest {
pub:
	spa_fallback string
	preload      []string
	entries      []Entry
}

// load reads and parses a dist/manifest.json.
pub fn load(path string) !Manifest {
	text := os.read_file(path) or { return error('manifest: cannot read ${path}: ${err}') }
	return parse(text)
}

// parse builds a Manifest from manifest.json text.
pub fn parse(text string) !Manifest {
	root := json2.decode[json2.Any](text)!.as_map()
	mut entries := []Entry{}
	if ents := root['entries'] {
		for raw in ents.as_array() {
			m := raw.as_map()
			entries << Entry{
				name:         m['name'] or { json2.Any('') }.str()
				content_type: m['content_type'] or { json2.Any('') }.str()
				cache:        m['cache'] or { json2.Any('') }.str()
			}
		}
	}
	mut preload := []string{}
	if pl := root['preload'] {
		for p in pl.as_array() {
			preload << p.str()
		}
	}
	return Manifest{
		spa_fallback: root['spa_fallback'] or { json2.Any('index.html') }.str()
		preload:      preload
		entries:      entries
	}
}

// entry_for returns the asset matching `pattern`, where `*` matches any run of
// characters (so `core.*.wasm` finds `core.9f3a1c.wasm`). A literal name with no
// `*` matches exactly. Errors if nothing matches.
pub fn (m &Manifest) entry_for(pattern string) !Entry {
	for e in m.entries {
		if glob_match(pattern, e.name) {
			return e
		}
	}
	return error('manifest: no asset matching "${pattern}"')
}

// has reports whether any recorded asset matches `pattern`.
pub fn (m &Manifest) has(pattern string) bool {
	if _ := m.entry_for(pattern) {
		return true
	}
	return false
}

// glob_match matches `name` against a pattern where `*` matches any run of
// characters; all other characters are literal.
fn glob_match(pattern string, name string) bool {
	return match_glob(pattern, 0, name, 0)
}

fn match_glob(p string, pi0 int, s string, si0 int) bool {
	mut pi := pi0
	mut si := si0
	for pi < p.len {
		if p[pi] == `*` {
			for k in si .. s.len + 1 {
				if match_glob(p, pi + 1, s, k) {
					return true
				}
			}
			return false
		}
		if si >= s.len || s[si] != p[pi] {
			return false
		}
		pi++
		si++
	}
	return si == s.len
}
