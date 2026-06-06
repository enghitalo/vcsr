# V performance toolbox

vcsr is written in V, and a compiler is a hot loop over bytes (lexing, building
the AST, emitting code). These are the V performance facts that matter for the
parser/codegen, adapted from the
[vanilla](https://github.com/enghitalo/vanilla) project's toolbox. The guiding
rule: **settle codegen/perf questions by reading the generated C, not by
guessing.**

## Inspecting what V actually emits

- `v -prod -o out.c .` — write the C without compiling; `grep` it.
- `v -show-c-output …` — full C-compiler output on error.
- `v -showcc …` — the exact C compiler command.

Use this to confirm, e.g., that a `[]u8{cap:N}` scratch buffer is already
noscan/uninitialized (so a big-cap regression is GC pressure, not zeroing), or
that a hot helper actually inlined.

## Attributes (functions / structs)

| Attribute | Effect | Use for |
|---|---|---|
| `@[inline]` | force inline | tiny hot helpers (`is_component_name`, byte tests) |
| `@[direct_array_access]` | skip bounds checks in the fn | verified-safe index loops (the parser's scan) |
| `@[manualfree]` | opt out of autofree | deterministic `defer { x.free() }` |
| `@[heap]` | struct always heap-allocated | long-lived shared structs |
| `@[packed]` | no padding | wire/ABI structs |
| `@[markused]` | keep an unused symbol in the build | reference impls |

`@[direct_array_access]` removes a real cost but also a real safety net — only on
loops you've proven in-bounds (e.g. the parser's `for p.pos < p.src.len` scans,
where every index is guarded).

## Array flags  `unsafe { arr.flags.set(.x | .y) }`

From `vlib/builtin/array.v`:

- `.noslices` — on `<<`, free the old data block immediately (only if no slices reference it).
- `.noshrink` — `.delete` won't realloc+free; with `.noslices` it moves in place.
- `.nogrow` — never grow past `cap`. `.nogrow` + `.noshrink` → a truly fixed heap array.
- `.nofree` — `.data` is never freed.
- `.noscan_data` — data sits in a no-scan (atomic) GC block; stays atomic across clone/resize.

Useful for fixed-size working sets — e.g. a reusable token/slot buffer sized once
per compile (`.noslices | .noshrink | .nogrow`).

## Allocation facts (the ones that bite)

- `[]u8{len: 0, cap: N}` → `__new_array_with_default_noscan` → `GC_MALLOC_ATOMIC(N)`:
  **uninitialized (not zeroed), not scanned.** V auto-picks noscan for
  pointer-free element types.
- A big working `cap` costs via **GC allocation pressure** (bytes/sec churn → more
  collections), not zeroing. Size buffers to the realistic template, not the
  worst case; better, reuse one buffer across a compile (zero per-node allocation).
- `grow_cap` re-allocates via the **scan** variant — growing a `[]u8` past `cap`
  loses the atomic property.
- A fixed-size stack array `[N]u8{}` **does** zero N bytes per call — don't make
  big ones inside a hot recursion (e.g. `serialize`).
- Prefer slicing the source string (`src[a..b]`) over copying — see
  [BEST_PRACTICES.md §2](BEST_PRACTICES.md).

## Codegen string building

Emitting `*.gen.v` is the codegen hot path. Building it with `${}`
interpolation allocates a fresh `string` per fragment (and calls `.str()` on
non-strings). Use `strings.new_builder(estimate)` and `write_string` /
`write_decimal` instead — details and the do/don't in
[BEST_PRACTICES.md §3](BEST_PRACTICES.md).

## Pure C escape hatch

Allowed when it doesn't introduce a safety problem. Good for: precise allocation
(`C.malloc` = unzeroed, unmanaged, manual free), tight byte/bit ops, and
sidestepping codegen quirks. Reach for it rarely and keep it local.

## Beyond `[]u8`

Arrays aren't the only structure. Consider `map` (e.g. interning template
skeletons by content hash so identical `<h1></h1>` skeletons share one entry),
fixed `[N]T` (stack), and arenas — when array alloc/grow semantics don't fit. A
compiler's natural target is a **per-compile arena / reusable buffer** so the hot
path allocates almost nothing.
