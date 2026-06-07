# Front-end benchmark

`parse_bench.v` measures the vcsr front end (phases 01–03: parse → slots → bind)
to answer a concrete question: **is a zero-copy `Slice {start, len}`
representation (vanilla-style) worth adopting over the current string-allocating
parser?**

```sh
ln -s "$PWD" ~/.vmodules/vcsr        # once, so `import vcsr.*` resolves
v -prod run bench/parse_bench.v
```

## Results (V 0.5.1, x86_64 linux, `-prod`)

| input | parse | slots | bind | **total** |
|---|---|---|---|---|
| **realistic component (192 B)** | 8.6 µs | 2.9 µs | 2.0 µs | **13.5 µs** |
| large, 500 inlined rows (54 KB) | 2.2 ms | 2.4 ms | 0.08 ms | 4.6 ms |

Allocation on the large template: **~13.8 MB/pass, ≈261× amplification**
(allocated bytes ÷ input bytes).

## What the data says

1. **At realistic sizes the front end is ~13 µs per component.** A 200-component
   project is ~3 ms total — dwarfed by the downstream `v -b wasm` + `wasm-opt`
   (seconds). Parsing is **not** the bottleneck of a build, and a single changed
   component re-parses in microseconds (fine for `vcsr watch`).

2. **`Slice` is not worth it (yet).** It would remove the per-token string
   allocations, but those cost microseconds at realistic sizes, while `Slice`
   adds lifetime coupling (every span borrows its source buffer) and ergonomics
   cost (helpers instead of `==`/`match`). That trades real complexity
   (BEST_PRACTICES rules 2 & 3) for an unmeasurable win on a per-build operation.

3. **The scary "261×" is almost all the 54 KB pathological case.** It comes from
   `slots.serialize` building the skeleton with `+=` (O(n²) on one giant
   template). Real apps don't write 54 KB templates — lists are one `@for` row,
   not 500 inlined ones — so this case doesn't occur today.

4. **Cautionary tale — measure, don't guess.** The "obvious" fix (build the
   skeleton with `strings.Builder` instead of `+=`) made `slots` **~16× slower**
   in this V version (≈38 ms vs 2.4 ms on the large template): a `Builder` passed
   as a `mut` array through recursion appears not to grow geometrically, so it
   reallocates almost per write — O(n²) with a worse constant. It was reverted.
   Shipping it on intuition would have been a real regression.

## Conclusion

Keep the current `+=` serializer; **do not** adopt `Slice`, and **do not** adopt
the naive `Builder`. Both are premature for a per-build front end already running
in microseconds.

**Revisit if** "inline composition" (see `docs/COMPONENTS.md`) starts merging
many child components into one large template — that could make single templates
big enough for the `+=` O(n²) to bite. If so, fix it with a *measured*
geometric-growth builder (e.g. a manually grown `[]u8`, or a `Builder` not
threaded through `mut` recursion), and use this benchmark as the regression
guard.
