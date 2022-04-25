/* --------------------------------------------------- */
/* Inline functions and macros for the Pallene library */
/* --------------------------------------------------- */

#include <math.h>

struct PalleneLib pallene_lib;

static inline
int pallene_is_truthy(const TValue *v)
{
    return !l_isfalse(v);
}

static inline
int pallene_is_record(const TValue *v, const TValue *meta_table)
{
    return ttisfulluserdata(v) && uvalue(v)->metatable == hvalue(meta_table);
}

/* Starting with Lua 5.4-rc1, Lua the boolean type now has two variants, LUA_VTRUE and LUA_VFALSE.
 * The value of the boolean is encoded in the type tag instead of in the `Value` union. */
static inline
int pallene_bvalue(TValue *obj)
{
    return ttistrue(obj);
}

static inline
void pallene_setbvalue(TValue *obj, int b)
{
    if (b) {
        setbtvalue(obj);
    } else {
        setbfvalue(obj);
    }
}

/* We must call a GC write barrier whenever we set "v" as an element of "p", in order to preserve
 * the color invariants of the incremental GC. This function is a specialization of luaC_barrierback
 * for when we already know the type of the child object and have an untagged pointer to it. */
static inline
void pallene_barrierback_unboxed(lua_State *L, GCObject *p, GCObject *v)
{
    if (isblack(p) && iswhite(v)) {
        luaC_barrierback_(L, p);
    }
}

/* Lua and Pallene round integer division towards negative infinity, while C rounds towards zero.
 * Here we inline luaV_div, to allow the C compiler to constant-propagate. For an explanation of the
 * algorithm, see the comments for luaV_div. */
static inline
lua_Integer pallene_int_divi(
    lua_State *L,
    lua_Integer m, lua_Integer n,
    const char* file,
    int line)
{
    if (l_castS2U(n) + 1u <= 1u) {
        if (n == 0){
            pallene_runtime_divide_by_zero_error(L, file, line);
        } else {
            return intop(-, 0, m);
        }
    } else {
        lua_Integer q = m / n;
        if ((m ^ n) < 0 && (m % n) != 0) {
            q -= 1;
        }
        return q;
    }
}

/* Lua and Pallene guarantee that (m == n*(m//n) + (m%n))
 * For details, see gen_int_div, luaV_div, and luaV_mod. */
static inline
lua_Integer pallene_int_modi(
    lua_State *L,
    lua_Integer m,
    lua_Integer n,
    const char* file,
    int line)
{
    if (l_castS2U(n) + 1u <= 1u) {
        if (n == 0){
            pallene_runtime_mod_by_zero_error(L, file, line);
        } else {
            return 0;
        }
    } else {
        lua_Integer r = m % n;
        if (r != 0 && (m ^ n) < 0) {
            r += n;
        }
        return r;
    }
}

/* In C, there is undefined behavior if the shift amount is negative or is larger than the integer
 * width. On the other hand, Lua and Pallene specify the behavior in these cases (negative means
 * shift in the opposite direction, and large shifts saturate at zero).
 *
 * Most of the time, the shift amount is a compile-time constant, in which case the C compiler
 * should be able to simplify this down to a single shift instruction.  In the dynamic case with
 * unknown "y" this implementation is a little bit faster Lua because we put the most common case
 * under a single level of branching. (~20% speedup) */

#define PALLENE_NBITS  (sizeof(lua_Integer) * CHAR_BIT)

static inline
lua_Integer pallene_shiftL(lua_Integer x, lua_Integer y)
{
    if (l_likely(l_castS2U(y) < PALLENE_NBITS)) {
        return intop(<<, x, y);
    } else {
        if (l_castS2U(-y) < PALLENE_NBITS) {
            return intop(>>, x, -y);
        } else {
            return 0;
        }
    }
}
static inline
lua_Integer pallene_shiftR(lua_Integer x, lua_Integer y)
{
    if (l_likely(l_castS2U(y) < PALLENE_NBITS)) {
        return intop(>>, x, y);
    } else {
        if (l_castS2U(-y) < PALLENE_NBITS) {
            return intop(<<, x, -y);
        } else {
            return 0;
        }
    }
}

/* Some Lua math functions return integer if the result fits in integer, or float if it doesn't.
 * In Pallene, we can't return different types, so we instead raise an error if it doesn't fit
 * See also: pushnumint in lmathlib */
static inline
lua_Integer pallene_checked_float_to_int(lua_State *L, const char* file, int line, lua_Number d)
{
    lua_Integer n;
    if (lua_numbertointeger(d, &n)) {
        return n;
    } else {
        pallene_runtime_number_to_integer_error(L, file, line);
    }
}

static inline
lua_Integer pallene_math_ceil(lua_State *L, const char* file, int line, lua_Number n)
{
    lua_Number d = l_mathop(ceil)(n);
    return pallene_checked_float_to_int(L, file, line, d);
}

static inline
lua_Integer pallene_math_floor(lua_State *L, const char* file, int line, lua_Number n)
{
    lua_Number d = l_mathop(floor)(n);
    return pallene_checked_float_to_int(L, file, line, d);
}

/* Based on math_log from lmathlib.c
 * The C compiler should be able to get rid of the if statement if this function is inlined
 * and the base parameter is a compile-time constant */
static inline
lua_Number pallene_math_log(lua_Integer x, lua_Integer base)
{
    if (base == l_mathop(10.0)) {
        return l_mathop(log10)(x);
#if !defined(LUA_USE_C89)
    } else if (base == l_mathop(2.0)) {
        return l_mathop(log2)(x);
#endif
    } else {
        return l_mathop(log)(x)/l_mathop(log)(base);
    }
}

static inline
lua_Integer pallene_math_modf(lua_State *L, const char* file, int line, lua_Number n, lua_Number* out)
{
    /* integer part (rounds toward zero) */
    lua_Number ip = (n < 0) ? l_mathop(ceil)(n) : l_mathop(floor)(n);
    /* fractional part (test needed for inf/-inf) */
    *out = (n == ip) ? l_mathop(0.0) : (n - ip);
    return pallene_checked_float_to_int(L, file, line, ip);
}

/* This version of lua_createtable bypasses the Lua stack, and can be inlined and optimized when the
 * allocation size is known at compilation time. */
static inline
Table *pallene_createtable(lua_State *L, lua_Integer narray, lua_Integer nrec)
{
    Table *t = luaH_new(L);
    if (narray > 0 || nrec > 0) {
        luaH_resize(L, t, narray, nrec);
    }
    return t;
}

/* When reading and writing to a Pallene array, we force everything to fit inside the array part of
 * the table. The optimizer and branch predictor prefer when it is this way. */
static inline
void pallene_renormalize_array(
    lua_State *L,
    Table *arr,
    lua_Integer i,
    const char* file,
    int line
){
    lua_Unsigned ui = (lua_Unsigned) i - 1;
    if (l_unlikely(ui >= arr->alimit)) {
        pallene_grow_array(L, file, line, arr, ui);
    }
}

/* These specializations of luaH_getstr and luaH_getshortstr introduce two optimizations:
 *   - After inlining, the length of the string is a compile-time constant
 *   - getshortstr's table lookup uses an inline cache. */

static const TValue PALLENE_ABSENTKEY = {ABSTKEYCONSTANT};

static inline
TValue *pallene_getshortstr(Table *t, TString *key, int *restrict cache)
{
    if (0 <= *cache && *cache < sizenode(t)) {
       Node *n = gnode(t, *cache);
       if (keyisshrstr(n) && eqshrstr(keystrval(n), key))
           return gval(n);
    }
    Node *n = gnode(t, lmod(key->hash, sizenode(t)));
    for (;;) {
        if (keyisshrstr(n) && eqshrstr(keystrval(n), key)) {
            *cache = n - gnode(t, 0);
            return gval(n);
        }
        else {
            int nx = gnext(n);
            if (nx == 0) {
                /* It is slightly better to have an invalid cache when we don't expect the cache to
                 * hit. The code will be faster because getstr will jump straight to the key search
                 * instead of trying to access a cache that we expect to be a miss. */
                *cache = UINT_MAX;
                return (TValue *)&PALLENE_ABSENTKEY;  /* not found */
            }
            n += nx;
        }
    }
}

static inline
TValue *pallene_getstr(size_t len, Table *t, TString *key, int *cache)
{
    if (len <= LUAI_MAXSHORTLEN) {
        return pallene_getshortstr(t, key, cache);
    } else {
        return cast(TValue *, luaH_getstr(t, key));
    }
}

/* To avoid looping infinitely due to integer overflow, Lua 5.4 carefully computes the number of
 * iterations before starting the loop (see OP_FORPREP). The code that implements this behavior does
 * not look like a regular C for loop, so to help improve the readability of the generated C code we
 * hide it behind the following set of macros. Note that some of the open braces in the BEGIN macro
 * are only closed in the END macro, so they must always be used together. We assume that the C
 * compiler will be able to optimize the common case where the step parameter is a compile-time
 * constant. */

#define PALLENE_INT_FOR_LOOP_BEGIN(i, A, B, C) \
    { \
        lua_Integer _init  = A; \
        lua_Integer _limit = B; \
        lua_Integer _step  = C; \
        if (_step == 0 ) { \
            luaL_error(L, "'for' step is zero"); \
        } \
        if (_step > 0 ? (_init <= _limit) : (_init >= _limit)) {        \
            lua_Unsigned _uinit  = l_castS2U(_init);                    \
            lua_Unsigned _ulimit = l_castS2U(_limit);                   \
            lua_Unsigned _count = ( _step > 0                           \
                ? (_ulimit - _uinit) / _step                            \
                : (_uinit - _ulimit) / (l_castS2U(-(_step + 1)) + 1u)); \
            lua_Integer _loopvar = _init; \
            while (1) { \
                i = _loopvar; \
                {
                    /* Loop body goes here*/

#define PALLENE_INT_FOR_LOOP_END \
                } \
                if (_count == 0) break; \
                _loopvar += _step; \
                _count -= 1; \
            } \
        } \
    }


#define PALLENE_FLT_FOR_LOOP_BEGIN(i, A, B, C) \
    { \
        lua_Number _init  = A; \
        lua_Number _limit = B; \
        lua_Number _step  = C; \
        if (_step == 0.0) { \
            luaL_error(L, "'for' step is zero"); \
        } \
        for ( \
            lua_Number _loopvar = _init; \
            (_step > 0.0 ? (_loopvar <= _limit) : (_loopvar >= _limit)); \
            _loopvar += _step \
        ){ \
            i = _loopvar;
            /* Loop body goes here*/

#define PALLENE_FLT_FOR_LOOP_END \
        } \
    }