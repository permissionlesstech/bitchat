/* Copyright (c) 2002, Christopher Clark.
 * Copyright (c) 2005-2006, Nick Mathewson.
 * Copyright (c) 2007-2019, The Tor Project, Inc. */
/* See license at end. */

/* Based on ideas by Christopher Clark and interfaces from Niels Provos. */

/*
  These macros provide an intrustive implementation for a typesafe chaining
  hash table, loosely based on the BSD tree.h and queue.h macros.  Here's
  how to use them.

  First, pick a the structure that you'll be storing in the hashtable. Let's
  say that's  "struct dinosaur".  To this structure, you add an HT_ENTRY()
  member, as such:

      struct dinosaur {
          HT_ENTRY(dinosaur) node; // The name inside the () must match the
                                   // struct.

          // These are just fields from the dinosaur structure...
          long dinosaur_id;
          char *name;
          long age;
          int is_ornithischian;
          int is_herbivorous;
      };

  You can declare the hashtable itself as:

      HT_HEAD(dinosaur_ht, dinosaur);

  This declares a new 'struct dinosaur_ht' type.

  Now you need to declare two functions to help implement the hashtable: one
  compares two dinosaurs for equality, and one computes the hash of a
  dinosaur.  Let's say that two dinosaurs are equal if they have the same ID
  and name.

     int
     dinosaurs_equal(const struct dinosaur *d1, const struct dinosaur *d2)
     {
        return d1->dinosaur_id == d2->dinosaur_id &&
               0 == strcmp(d1->name, d2->name);
     }

     unsigned
     dinosaur_hash(const struct dinosaur *d)
     {
        // This is a very bad hash function. Use siphash24g instead.
        return (d->dinosaur_id + d->name[0] ) * 1337 + d->name[1] * 1337;
     }

  Now you'll need to declare the functions that manipulate the hash table.
  To do this, you put this declaration either in a header file, or inside
  a regular module, depending on what visibility you want.

     HT_PROTOTYPE(dinosaur_ht, // The name of the hashtable struct
                  dinosaur,    // The name of the element struct,
                  node,        // The name of HT_ENTRY member
                  dinosaur_hash, dinosaurs_equal);

  Later, inside a C function, you use this macro to declare the hashtable
  functions.

     HT_GENERATE2(dinosaur_ht, dinosaur, node, dinosaur_hash, dinosaurs_equal,
                  0.6, tor_reallocarray, tor_free_);

  Note the use of tor_free_, not tor_free.  The 0.6 is magic.

  Now you can use the hashtable!  You can initialize one with

     struct dinosaur_ht my_dinos = HT_INITIALIZER();

  Or create one in core with

     struct dinosaur_ht *dinos = tor_malloc(sizeof(dinosaur_ht));
     HT_INIT(dinosaur_ht, dinos);

  To the hashtable, you use the HT_FOO(dinosaur_ht, ...) macros.  For
  example, to put new_dino into dinos, you say:

     HT_REPLACE(dinosaur_ht, dinos, new_dino);

  If you're searching for an element, you need to use a dummy 'key' element in
  the search.  For example.

     struct dinosaur dino_key;
     dino_key.dinosaur_id = 12345;
     dino_key.name = tor_strdup("Atrociraptor");

     struct dinosaur *found = HT_FIND(dinosaurs_ht, dinos, &dino_key);

  Have fun with your hash table!

 */

#ifndef HT_H_INCLUDED_
#define HT_H_INCLUDED_

#define HT_HEAD(name, type)                                             \
  struct name {                                                         \
    /* The hash table itself. */                                        \
    struct type **hth_table;                                            \
    /* How long is the hash table? */                                   \
    unsigned hth_table_length;                                          \
    /* How many elements does the table contain? */                     \
    unsigned hth_n_entries;                                             \
    /* How many elements will we allow in the table before resizing it? */ \
    unsigned hth_load_limit;                                            \
    /* Position of hth_table_length in the primes table. */             \
    int hth_prime_idx;                                                  \
  }

#define HT_INITIALIZER()                        \
  { NULL, 0, 0, 0, -1 }

#ifdef HT_NO_CACHE_HASH_VALUES
#define HT_ENTRY(type)                          \
  struct {                                      \
    struct type *hte_next;                      \
  }
#else
#define HT_ENTRY(type)                          \
  struct {                                      \
    struct type *hte_next;                      \
    unsigned hte_hash;                          \
  }
#endif

/* || 0 is for -Wparentheses-equality (-Wall?) appeasement under clang */
#define HT_EMPTY(head)                          \
  (((head)->hth_n_entries == 0) || 0)

/* How many elements in 'head'? */
#define HT_SIZE(head)                           \
  ((head)->hth_n_entries)

/* Return memory usage for a hashtable (not counting the entries themselves) */
#define HT_MEM_USAGE(head)                         \
  (sizeof(*head) + (head)->hth_table_length * sizeof(void*))

#define HT_FIND(name, head, elm)     name##_HT_FIND((head), (elm))
#define HT_INSERT(name, head, elm)   name##_HT_INSERT((head), (elm))
#define HT_REPLACE(name, head, elm)  name##_HT_REPLACE((head), (elm))
#define HT_REMOVE(name, head, elm)   name##_HT_REMOVE((head), (elm))
#define HT_START(name, head)         name##_HT_START(head)
#define HT_NEXT(name, head, elm)     name##_HT_NEXT((head), (elm))
#define HT_NEXT_RMV(name, head, elm) name##_HT_NEXT_RMV((head), (elm))
#define HT_CLEAR(name, head)         name##_HT_CLEAR(head)
#define HT_INIT(name, head)          name##_HT_INIT(head)
#define HT_REP_IS_BAD_(name, head)    name##_HT_REP_IS_BAD_(head)
#define HT_FOREACH_FN(name, head, fn, data) \
   name##_HT_FOREACH_FN((head), (fn), (data))
/* Helper: */
static inline unsigned
ht_improve_hash(unsigned h)
{
  /* Aim to protect against poor hash functions by adding logic here
   * - logic taken from java 1.4 hashtable source */
  h += ~(h << 9);
  h ^=  ((h >> 14) | (h << 18)); /* >>> */
  h +=  (h << 4);
  h ^=  ((h >> 10) | (h << 22)); /* >>> */
  return h;
}

#if 0
/** Basic string hash function, from Java standard String.hashCode(). */
static inline unsigned
ht_string_hash(const char *s)
{
  unsigned h = 0;
  int m = 1;
  while (*s) {
    h += ((signed char)*s++)*m;
    m = (m<<5)-1; /* m *= 31 */
  }
  return h;
}
#endif

#if 0
/** Basic string hash function, from Python's str.__hash__() */
static inline unsigned
ht_string_hash(const char *s)
{
  unsigned h;
  const unsigned char *cp = (const unsigned char *)s;
  h = *cp << 7;
  while (*cp) {
    h = (1000003*h) ^ *cp++;
  }
  /* This conversion truncates the length of the string, but that's ok. */
  h ^= (unsigned)(cp-(const unsigned char*)s);
  return h;
}
#endif

#ifndef HT_NO_CACHE_HASH_VALUES
#define HT_SET_HASH_(elm, field, hashfn)        \
    do { (elm)->field.hte_hash = hashfn(elm); } while (0)
#define HT_SET_HASHVAL_(elm, field, val)        \
    do { (elm)->field.hte_hash = (val); } while (0)
#define HT_ELT_HASH_(elm, field, hashfn)        \
    ((elm)->field.hte_hash)
#else
#define HT_SET_HASH_(elm, field, hashfn)        \
    ((void)0)
#define HT_ELT_HASH_(elm, field, hashfn)        \
    (hashfn(elm))
#define HT_SET_HASHVAL_(elm, field, val)        \
        ((void)0)
#endif

#define HT_BUCKET_NUM_(head, field, elm, hashfn)                        \
  (HT_ELT_HASH_(elm,field,hashfn) % head->hth_table_length)

/* Helper: alias for the bucket containing 'elm'. */
#define HT_BUCKET_(head, field, elm, hashfn)                            \
  ((head)->hth_table[HT_BUCKET_NUM_(head, field, elm, hashfn)])

#define HT_FOREACH(x, name, head)                 \
  for ((x) = HT_START(name, head);                \
       (x) != NULL;                               \
       (x) = HT_NEXT(name, head, x))

#ifndef HT_NDEBUG
#include "lib/err/torerr.h"
#define HT_ASSERT_(x) raw_assert(x)
#else
#define HT_ASSERT_(x) (void)0
#endif

/* Macro put at the end of the end of a macro definition so that it
 * consumes the following semicolon at file scope. Used only inside ht.h. */
#define HT_EAT_SEMICOLON__ struct ht_semicolon_eater

#define HT_PROTOTYPE(name, type, field, hashfn, eqfn)                   \
  int name##_HT_GROW(struct name *ht, unsigned min_capacity);           \
  void name##_HT_CLEAR(struct name *ht);                                \
  int name##_HT_REP_IS_BAD_(const struct name *ht);                     \
  static inline void                                                    \
  name##_HT_INIT(struct name *head) {                                   \
    head->hth_table_length = 0;                                         \
    head->hth_table = NULL;                                             \
    head->hth_n_entries = 0;                                            \
    head->hth_load_limit = 0;                                           \
    head->hth_prime_idx = -1;                                           \
  }                                                                     \
  /* Helper: returns a pointer to the right location in the table       \
   * 'head' to find or insert the element 'elm'. */                     \
  static inline struct type **                                          \
  name##_HT_FIND_P_(struct name *head, struct type *elm)                \
  {                                                                     \
    struct type **p;                                                    \
    if (!head->hth_table)                                               \
      return NULL;                                                      \
    p = &HT_BUCKET_(head, field, elm, hashfn);                          \
    while (*p) {                                                        \
      if (eqfn(*p, elm))                                                \
        return p;                                                       \
      p = &(*p)->field.hte_next;                                        \
    }                                                                   \
    return p;                                                           \
  }                                                                     \
  /* Return a pointer to the element in the table 'head' matching 'elm', \
   * or NULL if no such element exists */                               \
  ATTR_UNUSED static inline struct type *                               \
  name##_HT_FIND(const struct name *head, struct type *elm)             \
  {                                                                     \
    struct type **p;                                                    \
    struct name *h = (struct name *) head;                              \
    HT_SET_HASH_(elm, field, hashfn);                                   \
    p = name##_HT_FIND_P_(h, elm);                                      \
    return p ? *p : NULL;                                               \
  }                                                                     \
  /* Insert the element 'elm' into the table 'head'.  Do not call this  \
   * function if the table might already contain a matching element. */ \
  ATTR_UNUSED static inline void                                        \
  name##_HT_INSERT(struct name *head, struct type *elm)                 \
  {                                                                     \
    struct type **p;                                                    \
    if (!head->hth_table || head->hth_n_entries >= head->hth_load_limit) \
      name##_HT_GROW(head, head->hth_n_entries+1);                      \
    ++head->hth_n_entries;                                              \
    HT_SET_HASH_(elm, field, hashfn);                                   \
    p = &HT_BUCKET_(head, field, elm, hashfn);                          \
    elm->field.hte_next = *p;                                           \
    *p = elm;                                                           \
  }                                                                     \
  /* Insert the element 'elm' into the table 'head'. If there already   \
   * a matching element in the table, replace that element and return   \
   * it. */                                                             \
  ATTR_UNUSED static inline struct type *                               \
  name##_HT_REPLACE(struct name *head, struct type *elm)                \
  {                                                                     \
    struct type **p, *r;                                                \
    if (!head->hth_table || head->hth_n_entries >= head->hth_load_limit) \
      name##_HT_GROW(head, head->hth_n_entries+1);                      \
    HT_SET_HASH_(elm, field, hashfn);                                   \
    p = name##_HT_FIND_P_(head, elm);                                   \
    HT_ASSERT_(p != NULL); /* this holds because we called HT_GROW */   \
    r = *p;                                                             \
    *p = elm;                                                           \
    if (r && (r!=elm)) {                                                \
      elm->field.hte_next = r->field.hte_next;                          \
      r->field.hte_next = NULL;                                         \
      return r;                                                         \
    } else {                                                            \
      ++head->hth_n_entries;                                            \
      return NULL;                                                      \
    }                                                                   \
  }                                                                     \
  /* Remove any element matching 'elm' from the table 'head'.  If such  \
   * an element is found, return it; otherwise return NULL. */          \
  ATTR_UNUSED static inline struct type *                               \
  name##_HT_REMOVE(struct name *head, struct type *elm)                 \
  {                                                                     \
    struct type **p, *r;                                                \
    HT_SET_HASH_(elm, field, hashfn);                                   \
    p = name##_HT_FIND_P_(head,elm);                                    \
    if (!p || !*p)                                                      \
      return NULL;                                                      \
    r = *p;                                                             \
    *p = r->field.hte_next;                                             \
    r->field.hte_next = NULL;                                           \
    --head->hth_n_entries;                                              \
    return r;                                                           \
  }                                                                     \
  /* Invoke the function 'fn' on every element of the table 'head',     \
   * using 'data' as its second argument.  If the function returns      \
   * nonzero, remove the most recently examined element before invoking \
   * the function again. */                                             \
  ATTR_UNUSED static inline void                                        \
  name##_HT_FOREACH_FN(struct name *head,                               \
                       int (*fn)(struct type *, void *),                \
                       void *data)                                      \
{                                                                       \
    unsigned idx;                                                       \
    struct type **p, **nextp, *next;                                    \
    if (!head->hth_table)                                               \
      return;                                                           \
    for (idx=0; idx < head->hth_table_length; ++idx) {                  \
      p = &head->hth_table[idx];                                        \
      while (*p) {                                                      \
        nextp = &(*p)->field.hte_next;                                  \
        next = *nextp;                                                  \
        if (fn(*p, data)) {                                             \
          --head->hth_n_entries;                                        \
          *p = next;                                                    \
        } else {                                                        \
          p = nextp;                                                    \
        }                                                               \
      }                                                                 \
    }                                                                   \
  }                                                                     \
  /* Return a pointer to the first element in the table 'head', under   \
   * an arbitrary order.  This order is stable under remove operations, \
   * but not under others. If the table is empty, return NULL. */       \
  ATTR_UNUSED static inline struct type **                              \
  name##_HT_START(struct name *head)                                    \
  {                                                                     \
    unsigned b = 0;                                                     \
    while (b < head->hth_table_length) {                                \
      if (head->hth_table[b]) {                                         \
        HT_ASSERT_(b ==                                                 \
                HT_BUCKET_NUM_(head,field,head->hth_table[b],hashfn));  \
        return &head->hth_table[b];                                     \
      }                                                                 \
      ++b;                                                              \
    }                                                                   \
    return NULL;                                                        \
  }                                                                     \
  /* Return the next element in 'head' after 'elm', under the arbitrary \
   * order used by HT_START.  If there are no more elements, return     \
   * NULL.  If 'elm' is to be removed from the table, you must call     \
   * this function for the next value before you remove it, or use      \
   * HT_NEXT_RMV instead.                                               \
   */                                                                   \
  ATTR_UNUSED static inline struct type **                              \
  name##_HT_NEXT(struct name *head, struct type **elm)                  \
  {                                                                     \
    if ((*elm)->field.hte_next) {                                       \
      HT_ASSERT_(HT_BUCKET_NUM_(head,field,*elm,hashfn) ==              \
             HT_BUCKET_NUM_(head,field,(*elm)->field.hte_next,hashfn)); \
      return &(*elm)->field.hte_next;                                   \
    } else {                                                            \
      unsigned b = HT_BUCKET_NUM_(head,field,*elm,hashfn)+1;            \
      while (b < head->hth_table_length) {                              \
        if (head->hth_table[b]) {                                       \
          HT_ASSERT_(b ==                                               \
                 HT_BUCKET_NUM_(head,field,head->hth_table[b],hashfn)); \
          return &head->hth_table[b];                                   \
        }                                                               \
        ++b;                                                            \
      }                                                                 \
      return NULL;                                                      \
    }                                                                   \
  }                                                                     \
  /* As HT_NEXT, but also remove the current element 'elm' from the     \
   * table. */                                                          \
  ATTR_UNUSED static inline struct type **                              \
  name##_HT_NEXT_RMV(struct name *head, struct type **elm)              \
  {                                                                     \
    unsigned h = HT_ELT_HASH_(*elm, field, hashfn);                     \
    *elm = (*elm)->field.hte_next;                                      \
    --head->hth_n_entries;                                              \
    if (*elm) {                                                         \
      return elm;                                                       \
    } else {                                                            \
      unsigned b = (h % head->hth_table_length)+1;                      \
      while (b < head->hth_table_length) {                              \
        if (head->hth_table[b])                                         \
          return &head->hth_table[b];                                   \
        ++b;                                                            \
      }                                                                 \
      return NULL;                                                      \
    }                                                                   \
  }                                                                     \
  HT_EAT_SEMICOLON__

#define HT_GENERATE2(name, type, field, hashfn, eqfn, load, reallocarrayfn, \
                     freefn)                                            \
  /* Primes that aren't too far from powers of two. We stop at */       \
  /* P=402653189 because P*sizeof(void*) is less than SSIZE_MAX */      \
  /* even on a 32-bit platform. */                                      \
  static unsigned name##_PRIMES[] = {                                   \
    53, 97, 193, 389,                                                   \
    769, 1543, 3079, 6151,                                              \
    12289, 24593, 49157, 98317,                                         \
    196613, 393241, 786433, 1572869,                                    \
    3145739, 6291469, 12582917, 25165843,                               \
    50331653, 100663319, 201326611, 402653189                           \
  };                                                                    \
  static unsigned name##_N_PRIMES =                                     \
    (unsigned)(sizeof(name##_PRIMES)/sizeof(name##_PRIMES[0]));         \
  /* Expand the internal table of 'head' until it is large enough to    \
   * hold 'size' elements.  Return 0 on success, -1 on allocation       \
   * failure. */                                                        \
  int                                                                   \
  name##_HT_GROW(struct name *head, unsigned size)                      \
  {                                                                     \
    unsigned new_len, new_load_limit;                                   \
    int prime_idx;                                                      \
    struct type **new_table;                                            \
    if (head->hth_prime_idx == (int)name##_N_PRIMES - 1)                \
      return 0;                                                         \
    if (head->hth_load_limit > size)                                    \
      return 0;                                                         \
    prime_idx = head->hth_prime_idx;                                    \
    do {                                                                \
      new_len = name##_PRIMES[++prime_idx];                             \
      new_load_limit = (unsigned)(load*new_len);                        \
    } while (new_load_limit <= size &&                                  \
             prime_idx < (int)name##_N_PRIMES);                         \
    if ((new_table = reallocarrayfn(NULL, new_len, sizeof(struct type*)))) { \
      unsigned b;                                                       \
      memset(new_table, 0, new_len*sizeof(struct type*));               \
      for (b = 0; b < head->hth_table_length; ++b) {                    \
        struct type *elm, *next;                                        \
        unsigned b2;                                                    \
        elm = head->hth_table[b];                                       \
        while (elm) {                                                   \
          next = elm->field.hte_next;                                   \
          b2 = HT_ELT_HASH_(elm, field, hashfn) % new_len;              \
          elm->field.hte_next = new_table[b2];                          \
          new_table[b2] = elm;                                          \
          elm = next;                                                   \
        }                                                               \
      }                                                                 \
      if (head->hth_table)                                              \
        freefn(head->hth_table);                                        \
      head->hth_table = new_table;                                      \
    } else {                                                            \
      unsigned b, b2;                                                   \
      new_table = reallocarrayfn(head->hth_table, new_len, sizeof(struct type*)); \
      if (!new_table) return -1;                                        \
      memset(new_table + head->hth_table_length, 0,                     \
             (new_len - head->hth_table_length)*sizeof(struct type*));  \
      for (b=0; b < head->hth_table_length; ++b) {                      \
        struct type *e, **pE;                                           \
        for (pE = &new_table[b], e = *pE; e != NULL; e = *pE) {         \
          b2 = HT_ELT_HASH_(e, field, hashfn) % new_len;                \
          if (b2 == b) {                                                \
            pE = &e->field.hte_next;                                    \
          } else {                                                      \
            *pE = e->field.hte_next;                                    \
            e->field.hte_next = new_table[b2];                          \
            new_table[b2] = e;                                          \
          }                                                             \
        }                                                               \
      }                                                                 \
      head->hth_table = new_table;                                      \
    }                                                                   \
    head->hth_table_length = new_len;                                   \
    head->hth_prime_idx = prime_idx;                                    \
    head->hth_load_limit = new_load_limit;                              \
    return 0;                                                           \
  }                                                                     \
  /* Free all storage held by 'head'.  Does not free 'head' itself, or  \
   * individual elements. */                                            \
  void                                                                  \
  name##_HT_CLEAR(struct name *head)                                    \
  {                                                                     \
    if (head->hth_table)                                                \
      freefn(head->hth_table);                                          \
    head->hth_table_length = 0;                                         \
    name##_HT_INIT(head);                                               \
  }                                                                     \
  /* Debugging helper: return false iff the representation of 'head' is \
   * internally consistent. */                                          \
  int                                                                   \
  name##_HT_REP_IS_BAD_(const struct name *head)                        \
  {                                                                     \
    unsigned n, i;                                                      \
    struct type *elm;                                                   \
    if (!head->hth_table_length) {                                      \
      if (!head->hth_table && !head->hth_n_entries &&                   \
          !head->hth_load_limit && head->hth_prime_idx == -1)           \
        return 0;                                                       \
      else                                                              \
        return 1;                                                       \
    }                                                                   \
    if (!head->hth_table || head->hth_prime_idx < 0 ||                  \
        !head->hth_load_limit)                                          \
      return 2;                                                         \
    if (head->hth_n_entries > head->hth_load_limit)                     \
      return 3;                                                         \
    if (head->hth_table_length != name##_PRIMES[head->hth_prime_idx])   \
      return 4;                                                         \
    if (head->hth_load_limit != (unsigned)(load*head->hth_table_length)) \
      return 5;                                                         \
    for (n = i = 0; i < head->hth_table_length; ++i) {                  \
      for (elm = head->hth_table[i]; elm; elm = elm->field.hte_next) {  \
        if (HT_ELT_HASH_(elm, field, hashfn) != hashfn(elm))            \
          return 1000 + i;                                              \
        if (HT_BUCKET_NUM_(head,field,elm,hashfn) != i)                 \
          return 10000 + i;                                             \
        ++n;                                                            \
      }                                                                 \
    }                                                                   \
    if (n != head->hth_n_entries)                                       \
      return 6;                                                         \
    return 0;                                                           \
  }                                                                     \
  HT_EAT_SEMICOLON__

#define HT_GENERATE(name, type, field, hashfn, eqfn, load, mallocfn,    \
                    reallocfn, freefn)                                  \
  static void *                                                         \
  name##_reallocarray(void *arg, size_t a, size_t b)                    \
  {                                                                     \
    if ((b) && (a) > SIZE_MAX / (b))                                    \
      return NULL;                                                      \
    if (arg)                                                            \
      return reallocfn((arg),(a)*(b));                                  \
    else                                                                \
      return mallocfn((a)*(b));                                         \
  }                                                                     \
  HT_GENERATE2(name, type, field, hashfn, eqfn, load,                   \
               name##_reallocarray, freefn)

/** Implements an over-optimized "find and insert if absent" block;
 * not meant for direct usage by typical code, or usage outside the critical
 * path.*/
#define HT_FIND_OR_INSERT_(name, field, hashfn, head, eltype, elm, var, y, n) \
  {                                                                     \
    struct name *var##_head_ = head;                                    \
    struct eltype **var;                                                \
    if (!var##_head_->hth_table ||                                      \
        var##_head_->hth_n_entries >= var##_head_->hth_load_limit)      \
      name##_HT_GROW(var##_head_, var##_head_->hth_n_entries+1);        \
    HT_SET_HASH_((elm), field, hashfn);                                 \
    var = name##_HT_FIND_P_(var##_head_, (elm));                        \
    HT_ASSERT_(var); /* Holds because we called HT_GROW */              \
    if (*var) {                                                         \
      y;                                                                \
    } else {                                                            \
      n;                                                                \
    }                                                                   \
  }
#define HT_FOI_INSERT_(field, head, elm, newent, var)       \
  {                                                         \
    HT_SET_HASHVAL_(newent, field, (elm)->field.hte_hash);  \
    newent->field.hte_next = NULL;                          \
    *var = newent;                                          \
    ++((head)->hth_n_entries);                              \
  }

/*
 * Copyright 2005, Nick Mathewson.  Implementation logic is adapted from code
 * by Christopher Clark, retrofit to allow drop-in memory management, and to
 * use the same interface as Niels Provos's tree.h.  This is probably still
 * a derived work, so the original license below still applies.
 *
 * Copyright (c) 2002, Christopher Clark
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * * Neither the name of the original author; nor the names of any contributors
 * may be used to endorse or promote products derived from this software
 * without specific prior written permission.
 *
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER
 * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#endif
