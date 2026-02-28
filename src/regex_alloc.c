#include <regex.h>
#include <stdlib.h>

regex_t *regex_heap_alloc(void) {
    return (regex_t *)calloc(1, sizeof(regex_t));
}

void regex_heap_free(regex_t *re) {
    free(re);
}
