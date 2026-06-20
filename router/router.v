// Phase 06 — Router + code splitting: route table → chunk plan.
//
// From the route table we derive a chunk plan: what lands in core.wasm (the
// runtime + shared components + the non-lazy landing route) versus a per-route
// side chunk (a lazy route's own component + its route-local components).
// Param routes (`/users/:id`) expose their parameter names; a `/*` route is the
// fallback. The plan is the input to phase 07's linking.
//
// Plain V, pure functions over the route table. See ../docs/SCALING.md.
module router

// Route is one entry of the route table. `params` is derived from the path's
// `:name` segments by `plan`; callers construct a Route without it.
pub struct Route {
pub:
	path      string
	component string
	lazy      bool
pub mut:
	params []string
}

// Chunk is a lazily-loaded side bundle: the components that live in it.
pub struct Chunk {
pub:
	components []string
}

// Plan is the computed chunk layout: the (param-resolved) route table, the
// core component set, and the per-route side chunks.
pub struct Plan {
pub:
	routes []Route
mut:
	core     []string
	chunks   map[string]Chunk
	fallback_route Route
	has_fallback   bool
}

// PlanInput carries the optional component-usage signal: for each component, the
// list of route paths that use it. A component used by ≥2 routes is shared and
// hoisted to core; one used by a single route stays route-local.
@[params]
pub struct PlanInput {
pub:
	component_usage map[string][]string
}

// plan builds a chunk plan from the route table alone (no extra usage signal).
pub fn plan(routes []Route) !Plan {
	return plan_with_usage(routes, PlanInput{})!
}

// plan_with_usage builds a chunk plan, folding in per-component route usage so
// shared components are hoisted to core and route-local ones stay in chunks.
pub fn plan_with_usage(routes []Route, opt PlanInput) !Plan {
	mut resolved := []Route{cap: routes.len}
	mut fallback_route := Route{}
	mut has_fallback := false
	for r in routes {
		mut rr := r
		rr.params = parse_params(r.path)
		resolved << rr
		if r.path == '/*' {
			fallback_route = rr
			has_fallback = true
		}
	}

	// shared components: used by ≥2 distinct routes → hoisted to core.
	mut is_shared := map[string]bool{}
	for comp, paths in opt.component_usage {
		mut seen := map[string]bool{}
		for p in paths {
			seen[p] = true
		}
		if seen.len >= 2 {
			is_shared[comp] = true
		}
	}

	// core: the non-lazy landing route's component + every shared component.
	mut core := []string{}
	for r in resolved {
		if r.path == '/' && !r.lazy && r.component != '' {
			push_unique(mut core, r.component)
		}
	}
	for comp, _ in is_shared {
		push_unique(mut core, comp)
	}

	// chunks: each lazy route → a chunk named by its last path segment, carrying
	// its own component plus its route-local (non-shared) components.
	mut chunks := map[string]Chunk{}
	for r in resolved {
		if !r.lazy {
			continue
		}
		name := chunk_name(r.path)
		mut comps := []string{}
		if r.component != '' && r.component !in is_shared {
			push_unique(mut comps, r.component)
		}
		for comp, paths in opt.component_usage {
			if comp in is_shared {
				continue
			}
			if r.path in paths {
				push_unique(mut comps, comp)
			}
		}
		chunks[name] = Chunk{
			components: comps
		}
	}

	return Plan{
		routes:         resolved
		core:           core
		chunks:         chunks
		fallback_route: fallback_route
		has_fallback:   has_fallback
	}
}

// route returns the route registered at `path`, or a zero Route if none.
pub fn (p &Plan) route(path string) Route {
	for r in p.routes {
		if r.path == path {
			return r
		}
	}
	return Route{}
}

// core_components returns the components that live in core.wasm: the landing
// route plus every component shared across ≥2 routes.
pub fn (p &Plan) core_components() []string {
	return p.core
}

// has_chunk reports whether a side chunk named `name` exists.
pub fn (p &Plan) has_chunk(name string) bool {
	return name in p.chunks
}

// chunk returns the named side chunk, or an empty Chunk if absent.
pub fn (p &Plan) chunk(name string) Chunk {
	return p.chunks[name] or { Chunk{} }
}

// fallback returns the `/*` wildcard route, or a zero Route if none is defined.
pub fn (p &Plan) fallback() Route {
	return p.fallback_route
}

// --- helpers ----------------------------------------------------------------

// parse_params extracts the `:name` parameter segments from a path, in order.
fn parse_params(path string) []string {
	mut out := []string{}
	for seg in path.split('/') {
		if seg.starts_with(':') && seg.len > 1 {
			out << seg[1..]
		}
	}
	return out
}

// chunk_name derives a chunk's name from its route's last non-empty segment
// (`/reports` → 'reports').
fn chunk_name(path string) string {
	segs := path.split('/').filter(it != '')
	if segs.len == 0 {
		return ''
	}
	return segs[segs.len - 1]
}

fn push_unique(mut list []string, v string) {
	if v !in list {
		list << v
	}
}
