#include <regex.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Zig never @cImports regex.h: glibc's regex_t is opaque to translate-c,
 * and NetBSD's headers fail @cImport on pragma / __END_DECLS. Heap
 * allocation also keeps regex_t off the Zig stack on every OS. */

#define VIBE_REGMATCH_MAX 32

typedef struct vibe_regmatch {
    int64_t rm_so;
    int64_t rm_eo;
} vibe_regmatch_t;

regex_t *regex_heap_alloc(void) {
    return (regex_t *)calloc(1, sizeof(regex_t));
}

void regex_heap_free(regex_t *re) {
    free(re);
}

int vibe_regcomp(regex_t *preg, const char *pattern, int cflags) {
    return regcomp(preg, pattern, cflags);
}

int vibe_regexec(
    const regex_t *preg,
    const char *string,
    size_t nmatch,
    vibe_regmatch_t *pmatch,
    int eflags
) {
    size_t n;
    size_t i;
    int rc;
    regmatch_t tmp[VIBE_REGMATCH_MAX];

    if (pmatch == NULL || nmatch == 0) {
        return regexec(preg, string, 0, NULL, eflags);
    }

    n = nmatch;
    if (n > VIBE_REGMATCH_MAX) {
        n = VIBE_REGMATCH_MAX;
    }

    /* REG_NOSUB skips writing pmatch; start from a defined 0/0 so Zig
     * never reads leftover stack as offsets. */
    memset(tmp, 0, sizeof(tmp));
    rc = regexec(preg, string, n, tmp, eflags);
    if (rc != 0) {
        return rc;
    }

    for (i = 0; i < n; i++) {
        pmatch[i].rm_so = (int64_t)tmp[i].rm_so;
        pmatch[i].rm_eo = (int64_t)tmp[i].rm_eo;
    }
    return 0;
}

void vibe_regfree(regex_t *preg) {
    regfree(preg);
}

size_t vibe_regerror(
    int errcode,
    const regex_t *preg,
    char *errbuf,
    size_t errbuf_size
) {
    return regerror(errcode, preg, errbuf, errbuf_size);
}

const int vibe_REG_NOSUB = REG_NOSUB;
const int vibe_REG_ICASE = REG_ICASE;
const int vibe_REG_EXTENDED = REG_EXTENDED;
const int vibe_REG_NOTBOL = REG_NOTBOL;
