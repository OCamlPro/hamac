/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> */

/* Liaison OCaml de libclingo (API C de clingo, clingo.h).

   Un contrôle clingo est un bloc personnalisé (custom block) qui pointe vers
   une structure C allouée par malloc : le contrôle lui-même, les messages
   reçus du journal (logger) de clingo, et la résolution en cours. La
   structure ne bouge pas, ce qui permet de la donner à clingo comme donnée
   du journal. Le finaliseur ferme la résolution en cours puis libère le
   contrôle ; une libération explicite (clingo_ml_control_free) le fait
   plus tôt, et toute opération ultérieure lève Error (Logic).

   La résolution n'est jamais exposée comme valeur OCaml : il y en a au plus
   une par contrôle, rangée dans la structure, ouverte par
   clingo_ml_solve_start et fermée par clingo_ml_solve_close. Aucun handle
   ne peut donc survivre à son contrôle. Avec une échéance, la recherche est
   asynchrone (mode async de clingo, son propre thread) : l'attente du
   modèle suivant est bornée, et la recherche annulée à l'échéance.

   Les erreurs de clingo deviennent l'exception OCaml enregistrée sous le
   nom « Hamac_clingo.Clingo.Error », avec le message de clingo complété
   des erreurs que le journal a reçues pendant l'appel (une erreur
   d'analyse n'est détaillée que dans le journal).

   Le verrou du runtime est relâché pendant le grounding et la recherche :
   les arguments sont copiés en C avant, et le journal n'appelle jamais
   OCaml. Un même contrôle ne doit pas être utilisé par deux threads à la
   fois. */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include <clingo.h>

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <caml/threads.h>

#if !defined(CLINGO_VERSION_MAJOR) || CLINGO_VERSION_MAJOR != 5 || CLINGO_VERSION_MINOR < 5
#error "hamac-clingo requires clingo 5.x, x >= 5"
#endif

/* ------------------------------------------------------------------ */
/* Journal                                                            */
/* ------------------------------------------------------------------ */

struct message {
  clingo_warning_t code;
  char *text;
  struct message *next;
};

struct ctl {
  clingo_control_t *control;      /* NULL une fois libéré */
  clingo_solve_handle_t *handle;  /* résolution en cours, ou NULL */
  double deadline;                /* fin de la résolution en cours (horloge
                                     monotone, en s), négative sans limite */
  struct message *first, *last;   /* messages non encore lus */
};

static double now(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void logger(clingo_warning_t code, char const *text, void *data)
{
  struct ctl *c = data;
  struct message *m = malloc(sizeof *m);
  if (m == NULL) return;
  m->text = strdup(text ? text : "");
  if (m->text == NULL) { free(m); return; }
  /* clingo termine ses messages par des fins de ligne : on les ôte. */
  size_t n = strlen(m->text);
  while (n > 0 && (m->text[n - 1] == '\n' || m->text[n - 1] == ' ')) m->text[--n] = '\0';
  m->code = code;
  m->next = NULL;
  if (c->last) c->last->next = m; else c->first = m;
  c->last = m;
}

static void drop_messages(struct ctl *c)
{
  struct message *m = c->first;
  while (m) {
    struct message *n = m->next;
    free(m->text);
    free(m);
    m = n;
  }
  c->first = c->last = NULL;
}

/* ------------------------------------------------------------------ */
/* Erreurs                                                            */
/* ------------------------------------------------------------------ */

/* Constructeurs constants de Clingo.error_code, dans l'ordre du type. */
static int error_code_index(clingo_error_t code)
{
  switch (code) {
  case clingo_error_runtime: return 0;
  case clingo_error_logic: return 1;
  case clingo_error_bad_alloc: return 2;
  default: return 3;
  }
}

/* Lève Error { code; message } pour la dernière erreur de clingo. [since] :
   le dernier message du journal avant l'appel ; les erreurs (runtime_error)
   journalisées depuis sont ajoutées au message. N'appeler qu'avec le
   runtime acquis. */
static void raise_clingo_error(struct ctl *c, struct message *since)
{
  CAMLparam0();
  CAMLlocal2(record, msg);
  const value *exn = caml_named_value("Hamac_clingo.Clingo.Error");
  clingo_error_t code = clingo_error_code();
  char const *base = clingo_error_message();
  if (base == NULL || *base == '\0') base = clingo_error_string(code);
  size_t len = strlen(base) + 1;
  struct message *start = c ? (since ? since->next : c->first) : NULL;
  for (struct message *m = start; m; m = m->next)
    if (m->code == clingo_warning_runtime_error) len += strlen(m->text) + 1;
  char *buf = malloc(len);
  if (buf == NULL) caml_raise_out_of_memory();
  strcpy(buf, base);
  for (struct message *m = start; m; m = m->next)
    if (m->code == clingo_warning_runtime_error) {
      strcat(buf, "\n");
      strcat(buf, m->text);
    }
  msg = caml_copy_string(buf);
  free(buf);
  if (exn == NULL) caml_failwith(String_val(msg));
  record = caml_alloc_small(2, 0);
  Field(record, 0) = Val_int(error_code_index(code));
  Field(record, 1) = msg;
  caml_raise_with_arg(*exn, record);
  CAMLnoreturn;
}

static void raise_logic(char const *text)
{
  clingo_set_error(clingo_error_logic, text);
  raise_clingo_error(NULL, NULL);
}

/* ------------------------------------------------------------------ */
/* Bloc personnalisé du contrôle                                      */
/* ------------------------------------------------------------------ */

#define Ctl_val(v) (*((struct ctl **) Data_custom_val(v)))

/* Mémoire hors tas attribuée à un contrôle pour le rythme du GC : un
   contrôle clingo occupe au moins quelques centaines de Kio, que le GC ne
   voit pas. Sans cette estimation, des contrôles abandonnés sans {!free}
   s'accumulent avant d'être finalisés. */
#define CTL_MEM (1 << 20)

static void release(struct ctl *c)
{
  if (c->handle) { clingo_solve_handle_close(c->handle); c->handle = NULL; }
  if (c->control) { clingo_control_free(c->control); c->control = NULL; }
  drop_messages(c);
}

static void finalize_ctl(value v)
{
  struct ctl *c = Ctl_val(v);
  if (c) { release(c); free(c); Ctl_val(v) = NULL; }
}

static struct custom_operations ctl_ops = {
  "hamac.clingo.control",
  finalize_ctl,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

/* Le contrôle vivant de [v], ou Error (Logic). */
static struct ctl *live(value v)
{
  struct ctl *c = Ctl_val(v);
  if (c == NULL || c->control == NULL) raise_logic("the control has been freed");
  return c;
}

static void check_idle(struct ctl *c)
{
  if (c->handle) raise_logic("a solve call is still running on this control");
}

/* ------------------------------------------------------------------ */
/* Symboles                                                           */
/* ------------------------------------------------------------------ */

/* Clingo.symbol :
     Inf | Sup                                (constantes 0, 1)
     Int of int | Str of string
     Fun of string * symbol list | Neg of string * symbol list (blocs 0..3) */
enum { TAG_INT = 0, TAG_STR = 1, TAG_FUN = 2, TAG_NEG = 3 };

static value ocaml_of_symbol(clingo_symbol_t s)
{
  CAMLparam0();
  CAMLlocal4(res, args, cell, arg);
  switch (clingo_symbol_type(s)) {
  case clingo_symbol_type_infimum: CAMLreturn(Val_int(0));
  case clingo_symbol_type_supremum: CAMLreturn(Val_int(1));
  case clingo_symbol_type_number: {
    int n;
    if (!clingo_symbol_number(s, &n)) raise_clingo_error(NULL, NULL);
    res = caml_alloc_small(1, TAG_INT);
    Field(res, 0) = Val_int(n);
    CAMLreturn(res);
  }
  case clingo_symbol_type_string: {
    char const *str;
    if (!clingo_symbol_string(s, &str)) raise_clingo_error(NULL, NULL);
    arg = caml_copy_string(str);
    res = caml_alloc_small(1, TAG_STR);
    Field(res, 0) = arg;
    CAMLreturn(res);
  }
  case clingo_symbol_type_function: {
    char const *name;
    clingo_symbol_t const *xs;
    size_t n;
    bool positive;
    if (!clingo_symbol_name(s, &name)
        || !clingo_symbol_arguments(s, &xs, &n)
        || !clingo_symbol_is_positive(s, &positive))
      raise_clingo_error(NULL, NULL);
    args = Val_emptylist;
    for (size_t i = n; i > 0; i--) {
      arg = ocaml_of_symbol(xs[i - 1]);
      cell = caml_alloc_small(2, 0);
      Field(cell, 0) = arg;
      Field(cell, 1) = args;
      args = cell;
    }
    arg = caml_copy_string(name);
    res = caml_alloc_small(2, positive ? TAG_FUN : TAG_NEG);
    Field(res, 0) = arg;
    Field(res, 1) = args;
    CAMLreturn(res);
  }
  default:
    raise_logic("unknown kind of clingo symbol");
  }
  CAMLreturn(Val_unit); /* jamais atteint */
}

/* Le symbole clingo de [v] dans [*out] ; false, l'erreur de clingo étant
   positionnée, s'il ne peut être construit. Ne lève pas et n'alloue rien
   dans le tas OCaml : l'appelant libère ses tampons avant de lever. */
static bool symbol_of_ocaml(value v, clingo_symbol_t *out)
{
  if (Is_long(v)) {
    if (Long_val(v) == 0) clingo_symbol_create_infimum(out);
    else clingo_symbol_create_supremum(out);
    return true;
  }
  switch (Tag_val(v)) {
  case TAG_INT: {
    intnat n = Long_val(Field(v, 0));
    if (n < INT32_MIN || n > INT32_MAX) {
      clingo_set_error(clingo_error_runtime, "integer out of the range of clingo numbers");
      return false;
    }
    clingo_symbol_create_number((int)n, out);
    return true;
  }
  case TAG_STR:
    return clingo_symbol_create_string(String_val(Field(v, 0)), out);
  default: {
    /* Fun ou Neg : les arguments d'abord, dans un tableau C (les symboles
       de clingo sont des entiers, que le GC ne déplace pas). */
    size_t n = 0;
    for (value l = Field(v, 1); l != Val_emptylist; l = Field(l, 1)) n++;
    clingo_symbol_t *xs = n ? malloc(n * sizeof *xs) : NULL;
    if (n && xs == NULL) {
      clingo_set_error(clingo_error_bad_alloc, "out of memory");
      return false;
    }
    size_t i = 0;
    bool ok = true;
    for (value l = Field(v, 1); ok && l != Val_emptylist; l = Field(l, 1))
      ok = symbol_of_ocaml(Field(l, 0), &xs[i++]);
    ok = ok && clingo_symbol_create_function(String_val(Field(v, 0)), xs, n,
                                             Tag_val(v) == TAG_FUN, out);
    free(xs);
    return ok;
  }
  }
}

/* ------------------------------------------------------------------ */
/* Tableaux de chaînes copiés en C                                    */
/* ------------------------------------------------------------------ */

static char **copy_strings(value arr, size_t *n)
{
  *n = Wosize_val(arr);
  char **xs = calloc(*n ? *n : 1, sizeof *xs);
  if (xs == NULL) caml_raise_out_of_memory();
  for (size_t i = 0; i < *n; i++) {
    xs[i] = strdup(String_val(Field(arr, i)));
    if (xs[i] == NULL) {
      for (size_t j = 0; j < i; j++) free(xs[j]);
      free(xs);
      caml_raise_out_of_memory();
    }
  }
  return xs;
}

static void free_strings(char **xs, size_t n)
{
  for (size_t i = 0; i < n; i++) free(xs[i]);
  free(xs);
}

/* ------------------------------------------------------------------ */
/* Primitives                                                         */
/* ------------------------------------------------------------------ */

CAMLprim value clingo_ml_version(value unit)
{
  CAMLparam1(unit);
  CAMLlocal1(res);
  int major, minor, revision;
  clingo_version(&major, &minor, &revision);
  res = caml_alloc_tuple(3);
  Store_field(res, 0, Val_int(major));
  Store_field(res, 1, Val_int(minor));
  Store_field(res, 2, Val_int(revision));
  CAMLreturn(res);
}

CAMLprim value clingo_ml_control_new(value args, value limit)
{
  CAMLparam2(args, limit);
  CAMLlocal1(res);
  struct ctl *c = calloc(1, sizeof *c);
  if (c == NULL) caml_raise_out_of_memory();
  size_t n;
  char **argv = copy_strings(args, &n);
  bool ok = clingo_control_new((char const *const *)argv, n, logger, c,
                               (unsigned)Long_val(limit), &c->control);
  free_strings(argv, n);
  if (!ok) {
    /* La structure est confiée à un bloc que le GC libérera : le message
       d'erreur, lu par raise_clingo_error, y reste accessible. */
    c->control = NULL;
    res = caml_alloc_custom_mem(&ctl_ops, sizeof(struct ctl *), CTL_MEM);
    Ctl_val(res) = c;
    raise_clingo_error(c, NULL);
  }
  res = caml_alloc_custom_mem(&ctl_ops, sizeof(struct ctl *), CTL_MEM);
  Ctl_val(res) = c;
  CAMLreturn(res);
}

CAMLprim value clingo_ml_control_free(value v)
{
  CAMLparam1(v);
  struct ctl *c = Ctl_val(v);
  if (c) release(c);
  CAMLreturn(Val_unit);
}

CAMLprim value clingo_ml_control_add(value v, value name, value params, value program)
{
  CAMLparam4(v, name, params, program);
  struct ctl *c = live(v);
  check_idle(c);
  struct message *since = c->last;
  size_t n;
  char **ps = copy_strings(params, &n);
  char *nm = strdup(String_val(name));
  char *prg = strdup(String_val(program));
  if (nm == NULL || prg == NULL) {
    free(nm); free(prg); free_strings(ps, n);
    caml_raise_out_of_memory();
  }
  caml_release_runtime_system();
  bool ok = clingo_control_add(c->control, nm, (char const *const *)ps, n, prg);
  caml_acquire_runtime_system();
  free(nm); free(prg); free_strings(ps, n);
  if (!ok) raise_clingo_error(c, since);
  CAMLreturn(Val_unit);
}

static void free_parts(clingo_part_t *ps, size_t n)
{
  for (size_t i = 0; i < n; i++) { free((void *)ps[i].name); free((void *)ps[i].params); }
  free(ps);
}

/* parts : (string * symbol list) array */
CAMLprim value clingo_ml_control_ground(value v, value parts)
{
  CAMLparam2(v, parts);
  struct ctl *c = live(v);
  check_idle(c);
  struct message *since = c->last;
  size_t n = Wosize_val(parts);
  clingo_part_t *ps = calloc(n ? n : 1, sizeof *ps);
  if (ps == NULL) caml_raise_out_of_memory();
  for (size_t i = 0; i < n; i++) {
    value part = Field(parts, i);
    size_t k = 0;
    for (value l = Field(part, 1); l != Val_emptylist; l = Field(l, 1)) k++;
    clingo_symbol_t *xs = k ? malloc(k * sizeof *xs) : NULL;
    ps[i].params = xs;
    ps[i].size = k;
    ps[i].name = strdup(String_val(Field(part, 0)));
    if ((k && xs == NULL) || ps[i].name == NULL) {
      free_parts(ps, n);
      caml_raise_out_of_memory();
    }
    size_t j = 0;
    for (value l = Field(part, 1); l != Val_emptylist; l = Field(l, 1))
      if (!symbol_of_ocaml(Field(l, 0), &xs[j++])) {
        free_parts(ps, n);
        raise_clingo_error(c, since);
      }
  }
  caml_release_runtime_system();
  bool ok = clingo_control_ground(c->control, ps, n, NULL, NULL);
  caml_acquire_runtime_system();
  free_parts(ps, n);
  if (!ok) raise_clingo_error(c, since);
  CAMLreturn(Val_unit);
}

/* Les messages reçus depuis la dernière lecture, du plus ancien au plus
   récent : (int * string) list, l'entier étant le code clingo_warning_t. */
CAMLprim value clingo_ml_control_messages(value v)
{
  CAMLparam1(v);
  CAMLlocal4(res, cell, pair, text);
  struct ctl *c = Ctl_val(v);
  res = Val_emptylist;
  if (c == NULL) CAMLreturn(res);
  /* Construite à l'envers puis retournée par OCaml : liste simple. */
  for (struct message *m = c->first; m; m = m->next) {
    text = caml_copy_string(m->text);
    pair = caml_alloc_small(2, 0);
    Field(pair, 0) = Val_int(m->code);
    Field(pair, 1) = text;
    cell = caml_alloc_small(2, 0);
    Field(cell, 0) = pair;
    Field(cell, 1) = res;
    res = cell;
  }
  drop_messages(c);
  CAMLreturn(res);
}

/* Ouvre une résolution. [limit] : durée maximale en secondes, négative
   sans limite ; avec une limite, la recherche est asynchrone, pour pouvoir
   l'arrêter à l'échéance (clingo_ml_solve_next). */
CAMLprim value clingo_ml_solve_start(value v, value limit)
{
  CAMLparam2(v, limit);
  struct ctl *c = live(v);
  check_idle(c);
  struct message *since = c->last;
  double l = Double_val(limit);
  clingo_solve_mode_bitset_t mode = clingo_solve_mode_yield;
  if (l >= 0) mode |= clingo_solve_mode_async;
  clingo_solve_handle_t *h = NULL;
  caml_release_runtime_system();
  bool ok = clingo_control_solve(c->control, mode, NULL, 0, NULL, NULL, &h);
  caml_acquire_runtime_system();
  if (!ok) raise_clingo_error(c, since);
  c->handle = h;
  c->deadline = l >= 0 ? now() + l : -1;
  CAMLreturn(Val_unit);
}

/* Le modèle suivant de la résolution en cours : Done (0) quand il n'y en a
   plus, Timeout (1) si l'échéance est passée avant (la recherche est alors
   arrêtée), sinon Model (symbols, costs, number, optimality_proven) ;
   [show] : l'ensemble clingo_show_type_bitset_t des symboles à lire. */
CAMLprim value clingo_ml_solve_next(value v, value show)
{
  CAMLparam2(v, show);
  CAMLlocal5(res, syms, costs, item, cell);
  struct ctl *c = live(v);
  if (c->handle == NULL) raise_logic("no solve call is running on this control");
  struct message *since = c->last;
  clingo_model_t const *m = NULL;
  bool timeout = false;
  double deadline = c->deadline;
  clingo_solve_handle_t *h = c->handle;
  caml_release_runtime_system();
  bool ok = clingo_solve_handle_resume(h);
  if (ok && deadline >= 0) {
    double left = deadline - now();
    bool ready = false;
    if (left > 0) clingo_solve_handle_wait(h, left, &ready);
    if (!ready) { timeout = true; ok = clingo_solve_handle_cancel(h); }
  }
  if (ok && !timeout) ok = clingo_solve_handle_model(h, &m);
  caml_acquire_runtime_system();
  if (!ok) raise_clingo_error(c, since);
  if (timeout) CAMLreturn(Val_int(1));
  if (m == NULL) CAMLreturn(Val_int(0));
  size_t n, k;
  uint64_t number;
  bool proven;
  clingo_show_type_bitset_t sh = (clingo_show_type_bitset_t)Long_val(show);
  if (!clingo_model_symbols_size(m, sh, &n) || !clingo_model_cost_size(m, &k)
      || !clingo_model_number(m, &number) || !clingo_model_optimality_proven(m, &proven))
    raise_clingo_error(c, since);
  clingo_symbol_t *xs = malloc((n ? n : 1) * sizeof *xs);
  int64_t *cs = malloc((k ? k : 1) * sizeof *cs);
  if (xs == NULL || cs == NULL) { free(xs); free(cs); caml_raise_out_of_memory(); }
  if (!clingo_model_symbols(m, sh, xs, n) || !clingo_model_cost(m, cs, k)) {
    free(xs); free(cs);
    raise_clingo_error(c, since);
  }
  /* ocaml_of_symbol ne lève que sur un genre de symbole que clingo 5 ne
     produit pas : xs ne fuit pas en pratique. */
  syms = Val_emptylist;
  for (size_t i = n; i > 0; i--) {
    item = ocaml_of_symbol(xs[i - 1]);
    cell = caml_alloc_small(2, 0);
    Field(cell, 0) = item;
    Field(cell, 1) = syms;
    syms = cell;
  }
  free(xs);
  costs = caml_alloc_tuple(k);
  for (size_t i = 0; i < k; i++) Store_field(costs, i, Val_long((intnat)cs[i]));
  free(cs);
  item = caml_alloc_tuple(4);
  Store_field(item, 0, syms);
  Store_field(item, 1, costs);
  Store_field(item, 2, Val_long((intnat)number));
  Store_field(item, 3, Val_bool(proven));
  res = caml_alloc_small(1, 0);
  Field(res, 0) = item;
  CAMLreturn(res);
}

/* Ferme la résolution en cours et rend son résultat
   (clingo_solve_result_bitset_t) ; sans effet, et rend 0, s'il n'y en a
   pas. */
CAMLprim value clingo_ml_solve_close(value v)
{
  CAMLparam1(v);
  struct ctl *c = Ctl_val(v);
  if (c == NULL || c->handle == NULL) CAMLreturn(Val_int(0));
  struct message *since = c->last;
  clingo_solve_result_bitset_t r = 0;
  clingo_solve_handle_t *h = c->handle;
  c->handle = NULL;
  caml_release_runtime_system();
  bool got = clingo_solve_handle_get(h, &r);
  bool closed = clingo_solve_handle_close(h);
  caml_acquire_runtime_system();
  if (!got || !closed) raise_clingo_error(c, since);
  CAMLreturn(Val_int(r));
}
