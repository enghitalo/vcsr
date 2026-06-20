// app.c — the "vcsr console" dashboard, compiled to a freestanding wasm32
// browser module (no WASI). State lives in linear memory; the DOM is driven
// through the integer-handle host substrate (src/loader.js); events come back
// via dispatch(); fetch is async via a callback. This is the runtime model
// docs/WASM-ABI.md calls the handle-table bridge — what vcsr ships today, since
// a C/clang module cannot persist `externref`.
//
// Build (see ../README or the build step): a single clang invocation,
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-table
// with each entry point marked __attribute__((export_name(...))).

#define IMPORT(n) __attribute__((import_module("env"), import_name(n)))
IMPORT("host_log")  void host_log(int, int);
IMPORT("el_body")   int  el_body(void);
IMPORT("el_create") int  el_create(int, int);
IMPORT("el_text")   void el_text(int, int, int);
IMPORT("el_attr")   void el_attr(int, int, int, int, int);
IMPORT("el_class")  void el_class(int, int, int);
IMPORT("el_append") void el_append(int, int);
IMPORT("el_clear")  void el_clear(int);
IMPORT("el_on")     void el_on(int, int, int, int, int);
IMPORT("el_value")  int  el_value(int, int);
IMPORT("ls_set")    void ls_set(int, int, int, int);
IMPORT("ls_get")    int  ls_get(int, int, int);
IMPORT("time_str")  int  time_str(int);
IMPORT("fetch_text") void fetch_text(int, int, int);

#define EXPORT(n) __attribute__((export_name(n)))

// ---- address-of helper + string-literal macros ----------------------------
static int A(const void *p) { return (int)(__SIZE_TYPE__)p; }
#define S(s)   A(s), ((int) sizeof(s) - 1)   // -> (ptr, len) for a literal
#define LIT(s) (s), ((int) sizeof(s) - 1)    // -> (const char*, len) for cat()

// ---- tiny formatting into static buffers (no libc) -------------------------
static char strbuf[192], status[96], valbuf[64];
static char fetchbuf[8192];

static int itoa(int n, char *o) {
  char t[16]; int i = 0, len = 0;
  if (n < 0) { o[len++] = '-'; n = -n; }
  if (n == 0) t[i++] = '0';
  while (n) { t[i++] = (char)('0' + n % 10); n /= 10; }
  while (i) o[len++] = t[--i];
  return len;
}
static int cat(char *d, int o, const char *s, int l) {
  for (int i = 0; i < l; i++) d[o + i] = s[i];
  return o + l;
}
static int cati(char *d, int o, int n) { return o + itoa(n, d + o); }

// ---- thin DOM helpers ------------------------------------------------------
static int E(int parent, int tagp, int tagl) {        // create + append
  int h = el_create(tagp, tagl);
  el_append(parent, h);
  return h;
}
static void settext(int h, int p, int l) { el_text(h, p, l); }
static void setclass(int h, int p, int l) { el_class(h, p, l); }

// ---- event ids -------------------------------------------------------------
enum { CB_THEME = 1, CB_TAB, CB_DEC, CB_INC, CB_ADD, CB_TOGGLE, CB_REMOVE, CB_FETCH };

// ---- state -----------------------------------------------------------------
typedef struct { char text[48]; int len; int done; int alive; } Todo;
static Todo todos[32];
static int  ntodo;
static int  counter;
static int  dark;
static int  view;          // 0 = dashboard, 1 = about
static int  status_len;
static int  body, input_h; // live handles for the current render

// ---- render (immediate-mode: rebuild from state) ---------------------------
static void render(void) {
  el_clear(body);
  if (dark) el_class(body, S("app dark")); else el_class(body, S("app light"));

  int header = E(body, S("header"));
  setclass(header, S("bar"));
  settext(E(header, S("h1")), S("vcsr console"));
  int theme = E(header, S("button"));
  setclass(theme, S("ghost"));
  if (dark) settext(theme, S("\xe2\x98\x80 light")); else settext(theme, S("\xf0\x9f\x8c\x99 dark"));
  el_on(theme, S("click"), CB_THEME, 0);

  int tabs = E(body, S("nav"));
  setclass(tabs, S("tabs"));
  int t0 = E(tabs, S("button"));
  settext(t0, S("Dashboard"));
  if (view == 0) setclass(t0, S("tab on")); else setclass(t0, S("tab"));
  el_on(t0, S("click"), CB_TAB, 0);
  int t1 = E(tabs, S("button"));
  settext(t1, S("About"));
  if (view == 1) setclass(t1, S("tab on")); else setclass(t1, S("tab"));
  el_on(t1, S("click"), CB_TAB, 1);

  int main_ = E(body, S("main"));
  setclass(main_, S("grid"));

  if (view == 1) {
    int card = E(main_, S("section"));
    setclass(card, S("card"));
    settext(E(card, S("h2")), S("About"));
    int p = E(card, S("p"));
    settext(p, S("A hand-authored C\xe2\x86\x92wasm app on vcsr's integer-handle DOM runtime: "
                 "state in linear memory, events via a shared dispatch, async fetch, and a "
                 "localStorage-persisted theme. Freestanding wasm32 \xe2\x80\x94 no WASI."));
    return;
  }

  // --- counter card ---
  int c = E(main_, S("section"));
  setclass(c, S("card"));
  settext(E(c, S("h2")), S("Counter"));
  int crow = E(c, S("div"));
  setclass(crow, S("row"));
  int dec = E(crow, S("button"));
  settext(dec, S("\xe2\x88\x92")); // minus
  el_on(dec, S("click"), CB_DEC, 0);
  int val = E(crow, S("span"));
  setclass(val, S("num"));
  { int o = itoa(counter, strbuf); el_text(val, A(strbuf), o); }
  int inc = E(crow, S("button"));
  settext(inc, S("+"));
  el_on(inc, S("click"), CB_INC, 0);
  int comp = E(c, S("p"));
  setclass(comp, S("muted"));
  { int o = 0; o = cat(strbuf, o, LIT("\xc3\x97 2 = ")); o = cati(strbuf, o, counter * 2);
    el_text(comp, A(strbuf), o); }

  // --- todos card ---
  int tc = E(main_, S("section"));
  setclass(tc, S("card"));
  settext(E(tc, S("h2")), S("Todos"));
  int form = E(tc, S("div"));
  setclass(form, S("row"));
  input_h = E(form, S("input"));
  el_attr(input_h, S("placeholder"), S("Add a task\xe2\x80\xa6"));
  int add = E(form, S("button"));
  settext(add, S("Add"));
  el_on(add, S("click"), CB_ADD, 0);
  int list = E(tc, S("ul"));
  setclass(list, S("list"));
  int done = 0, total = 0;
  for (int i = 0; i < ntodo; i++) {
    if (!todos[i].alive) continue;
    total++;
    if (todos[i].done) done++;
    int li = E(list, S("li"));
    setclass(li, S("item"));
    int label = E(li, S("span"));
    if (todos[i].done) setclass(label, S("txt done")); else setclass(label, S("txt"));
    el_text(label, A(todos[i].text), todos[i].len);
    el_on(label, S("click"), CB_TOGGLE, i);
    int x = E(li, S("button"));
    setclass(x, S("x"));
    settext(x, S("\xc3\x97")); // ×
    el_on(x, S("click"), CB_REMOVE, i);
  }
  int foot = E(tc, S("p"));
  setclass(foot, S("muted"));
  { int o = 0; o = cati(strbuf, o, done); o = cat(strbuf, o, LIT(" done / "));
    o = cati(strbuf, o, total); o = cat(strbuf, o, LIT(" total")); el_text(foot, A(strbuf), o); }

  // --- async fetch card ---
  int fc = E(main_, S("section"));
  setclass(fc, S("card"));
  settext(E(fc, S("h2")), S("Async fetch"));
  int pf = E(fc, S("button"));
  settext(pf, S("GET /manifest.json"));
  el_on(pf, S("click"), CB_FETCH, 0);
  int st = E(fc, S("p"));
  setclass(st, S("muted"));
  if (status_len > 0) el_text(st, A(status), status_len); else settext(st, S("(idle \xe2\x80\x94 click to fetch)"));
}

// ---- exports ---------------------------------------------------------------
EXPORT("mount") void mount(void) {
  body = el_body();
  int l = ls_get(S("vcsr.theme"), A(valbuf));
  dark = (l == 4 && valbuf[0] == 'd'); // "dark"
  render();
}

EXPORT("dispatch") void dispatch(int cb, int data) {
  if (cb == CB_THEME) {
    dark ^= 1;
    if (dark) ls_set(S("vcsr.theme"), S("dark")); else ls_set(S("vcsr.theme"), S("light"));
  } else if (cb == CB_TAB) {
    view = data;
  } else if (cb == CB_DEC) {
    counter--;
  } else if (cb == CB_INC) {
    counter++;
  } else if (cb == CB_ADD) {
    int len = el_value(input_h, A(valbuf));
    if (len > 0 && ntodo < 32) {
      if (len > 47) len = 47;
      for (int i = 0; i < len; i++) todos[ntodo].text[i] = valbuf[i];
      todos[ntodo].len = len;
      todos[ntodo].done = 0;
      todos[ntodo].alive = 1;
      ntodo++;
    }
  } else if (cb == CB_TOGGLE) {
    if (data >= 0 && data < ntodo) todos[data].done ^= 1;
  } else if (cb == CB_REMOVE) {
    if (data >= 0 && data < ntodo) todos[data].alive = 0;
  } else if (cb == CB_FETCH) {
    fetch_text(S("/manifest.json"), CB_FETCH); // async — re-render in on_fetch
    return;
  }
  render();
}

EXPORT("on_fetch") void on_fetch(int cb, int ptr, int len) {
  (void) cb; (void) ptr;
  int o = 0;
  o = cat(status, o, LIT("fetched "));
  o = cati(status, o, len);
  o = cat(status, o, LIT(" bytes @ "));
  o += time_str(A(status) + o);
  status_len = o;
  render();
}

EXPORT("fetch_buf") int fetch_buf(void) { return A(fetchbuf); }
EXPORT("fetch_cap") int fetch_cap(void) { return (int) sizeof(fetchbuf); }
