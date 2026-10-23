/* clang-build only: gcc inlines these; clang under -ffreestanding calls them. */
#include <stddef.h>
int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (unsigned char)*a - (unsigned char)*b;
}
void *memset(void *d, int c, size_t n)
{
	unsigned char *p = d;
	while (n--) *p++ = (unsigned char)c;
	return d;
}
void *memcpy(void *d, const void *s, size_t n)
{
	unsigned char *p = d; const unsigned char *q = s;
	while (n--) *p++ = *q++;
	return d;
}
