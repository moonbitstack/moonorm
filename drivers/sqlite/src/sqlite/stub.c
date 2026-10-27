#include "sqlite3.h"
#include <moonbit.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

static char* mb_cstr(moonbit_bytes_t b) {
  int32_t n = Moonbit_array_length(b);
  char* s = (char*)malloc(n + 1);
  memcpy(s, b, n); s[n] = '\0'; return s;
}
static moonbit_bytes_t mb_bytes(const void* p, int32_t n) {
  if (p == NULL || n <= 0) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t o = moonbit_make_bytes(n, 0);
  memcpy(o, p, n); return o;
}

int64_t orm_open(moonbit_bytes_t path) {
  char* p = mb_cstr(path); sqlite3* db = NULL;
  int rc = sqlite3_open(p, &db); free(p);
  if (rc != SQLITE_OK) { if (db) sqlite3_close(db); return 0; }
  return (int64_t)(intptr_t)db;
}
moonbit_bytes_t orm_errmsg(int64_t db) {
  const char* m = sqlite3_errmsg((sqlite3*)(intptr_t)db);
  return mb_bytes(m, m ? (int32_t)strlen(m) : 0);
}
int32_t orm_exec(int64_t db, moonbit_bytes_t sql) {
  char* s = mb_cstr(sql);
  int rc = sqlite3_exec((sqlite3*)(intptr_t)db, s, NULL, NULL, NULL);
  free(s); return rc;
}
int64_t orm_prepare(int64_t db, moonbit_bytes_t sql) {
  char* s = mb_cstr(sql); sqlite3_stmt* st = NULL;
  int rc = sqlite3_prepare_v2((sqlite3*)(intptr_t)db, s, -1, &st, NULL);
  free(s); if (rc != SQLITE_OK) return 0; return (int64_t)(intptr_t)st;
}
int32_t orm_bind_int(int64_t st, int32_t i, int32_t v) { return sqlite3_bind_int((sqlite3_stmt*)(intptr_t)st, i, v); }
int32_t orm_bind_int64(int64_t st, int32_t i, int64_t v) { return sqlite3_bind_int64((sqlite3_stmt*)(intptr_t)st, i, v); }
int32_t orm_bind_double(int64_t st, int32_t i, double v) { return sqlite3_bind_double((sqlite3_stmt*)(intptr_t)st, i, v); }
int32_t orm_bind_text(int64_t st, int32_t i, moonbit_bytes_t v) {
  return sqlite3_bind_text((sqlite3_stmt*)(intptr_t)st, i, (const char*)v, Moonbit_array_length(v), SQLITE_TRANSIENT);
}
int32_t orm_bind_null(int64_t st, int32_t i) { return sqlite3_bind_null((sqlite3_stmt*)(intptr_t)st, i); }
int32_t orm_bind_blob(int64_t st, int32_t i, moonbit_bytes_t v) {
  return sqlite3_bind_blob((sqlite3_stmt*)(intptr_t)st, i, (const void*)v, Moonbit_array_length(v), SQLITE_TRANSIENT);
}
int32_t orm_step(int64_t st) { return sqlite3_step((sqlite3_stmt*)(intptr_t)st); }
int32_t orm_col_count(int64_t st) { return sqlite3_column_count((sqlite3_stmt*)(intptr_t)st); }
int32_t orm_col_type(int64_t st, int32_t i) { return sqlite3_column_type((sqlite3_stmt*)(intptr_t)st, i); }
int64_t orm_col_int64(int64_t st, int32_t i) { return sqlite3_column_int64((sqlite3_stmt*)(intptr_t)st, i); }
double orm_col_double(int64_t st, int32_t i) { return sqlite3_column_double((sqlite3_stmt*)(intptr_t)st, i); }
moonbit_bytes_t orm_col_text(int64_t st, int32_t i) {
  sqlite3_stmt* s = (sqlite3_stmt*)(intptr_t)st;
  return mb_bytes(sqlite3_column_text(s, i), sqlite3_column_bytes(s, i));
}
moonbit_bytes_t orm_col_blob(int64_t st, int32_t i) {
  sqlite3_stmt* s = (sqlite3_stmt*)(intptr_t)st;
  return mb_bytes(sqlite3_column_blob(s, i), sqlite3_column_bytes(s, i));
}
moonbit_bytes_t orm_col_name(int64_t st, int32_t i) {
  const char* n = sqlite3_column_name((sqlite3_stmt*)(intptr_t)st, i);
  return mb_bytes(n, n ? (int32_t)strlen(n) : 0);
}
int32_t orm_finalize(int64_t st) { return sqlite3_finalize((sqlite3_stmt*)(intptr_t)st); }
int32_t orm_changes(int64_t db) { return sqlite3_changes((sqlite3*)(intptr_t)db); }
int64_t orm_last_id(int64_t db) { return sqlite3_last_insert_rowid((sqlite3*)(intptr_t)db); }
/* close_v2 defers the free until any still-live prepared statement (e.g. an
   abandoned streaming cursor) is finalized, so the handle is never leaked. */
int32_t orm_close(int64_t db) { return sqlite3_close_v2((sqlite3*)(intptr_t)db); }
