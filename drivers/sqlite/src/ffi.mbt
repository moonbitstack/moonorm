// Low-level C FFI over the vendored SQLite amalgamation (`sqlite/sqlite3.c` /
// `sqlite/sqlite3.h`, public domain). Opaque `sqlite3*` / `sqlite3_stmt*` handles are
// carried as `Int64` (the pointer bits) rather than an extern MoonBit type: the
// native runtime must not reference-count or free a foreign pointer, and an integer
// is inert to the GC. A returned handle of `0` signals failure. `#borrow` marks
// arguments the C side only reads, so MoonBit keeps ownership.

///|
#borrow(path)
extern "c" fn ffi_open(path : Bytes) -> Int64 = "orm_open"

///|
extern "c" fn ffi_errmsg(db : Int64) -> Bytes = "orm_errmsg"

///|
#borrow(sql)
extern "c" fn ffi_exec(db : Int64, sql : Bytes) -> Int32 = "orm_exec"

///|
#borrow(sql)
extern "c" fn ffi_prepare(db : Int64, sql : Bytes) -> Int64 = "orm_prepare"

///|
extern "c" fn ffi_bind_int(st : Int64, i : Int32, v : Int32) -> Int32 = "orm_bind_int"

///|
extern "c" fn ffi_bind_int64(st : Int64, i : Int32, v : Int64) -> Int32 = "orm_bind_int64"

///|
extern "c" fn ffi_bind_double(st : Int64, i : Int32, v : Double) -> Int32 = "orm_bind_double"

///|
#borrow(v)
extern "c" fn ffi_bind_text(st : Int64, i : Int32, v : Bytes) -> Int32 = "orm_bind_text"

///|
#borrow(v)
extern "c" fn ffi_bind_blob(st : Int64, i : Int32, v : Bytes) -> Int32 = "orm_bind_blob"

///|
extern "c" fn ffi_bind_null(st : Int64, i : Int32) -> Int32 = "orm_bind_null"

///|
extern "c" fn ffi_step(st : Int64) -> Int32 = "orm_step"

///|
extern "c" fn ffi_col_count(st : Int64) -> Int32 = "orm_col_count"

///|
extern "c" fn ffi_col_type(st : Int64, i : Int32) -> Int32 = "orm_col_type"

///|
extern "c" fn ffi_col_int64(st : Int64, i : Int32) -> Int64 = "orm_col_int64"

///|
extern "c" fn ffi_col_double(st : Int64, i : Int32) -> Double = "orm_col_double"

///|
extern "c" fn ffi_col_text(st : Int64, i : Int32) -> Bytes = "orm_col_text"

///|
extern "c" fn ffi_col_blob(st : Int64, i : Int32) -> Bytes = "orm_col_blob"

///|
extern "c" fn ffi_col_name(st : Int64, i : Int32) -> Bytes = "orm_col_name"

///|
extern "c" fn ffi_finalize(st : Int64) -> Int32 = "orm_finalize"

///|
extern "c" fn ffi_changes(db : Int64) -> Int32 = "orm_changes"

///|
extern "c" fn ffi_last_id(db : Int64) -> Int64 = "orm_last_id"

///|
extern "c" fn ffi_close(db : Int64) -> Int32 = "orm_close"

///|
/// SQLite `sqlite3_step` return codes we distinguish.
let sqlite_row : Int32 = 100

///|
let sqlite_done : Int32 = 101
