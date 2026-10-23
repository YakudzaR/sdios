#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "pure.h"
#include "sdcard.h"
static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)
/* build a CSD v2 as the SDHCI delivers it: RESP[119:0] = bits 127:8 */
static void put_bits(uint32_t r[4], int hi, int lo, uint64_t v)
{
    for (int b = lo; b <= hi; b++) { int k = b - 8; if ((v >> (b - lo)) & 1) r[k / 32] |= 1u << (k % 32); else r[k / 32] &= ~(1u << (k % 32)); }
}
int main(void)
{
    /* CSD oracle comparison with the already host-tested decoder */
    srand(7);
    for (int i = 0; i < 2000; i++) {
        uint32_t r[4] = { 0, 0, 0, 0 };
        int v = rand() & 1;
        put_bits(r, 127, 126, v);
        if (v) put_bits(r, 69, 48, rand() & 0x3fffff);
        else { put_bits(r, 73, 62, rand() & 0xfff); put_bits(r, 49, 47, rand() & 7); put_bits(r, 83, 80, 9 + (rand() % 3)); }
        uint64_t a = sd_csd_sectors(r), b = sd_csd_capacity_bytes(r, 0) / 512;
        if (a != b) { printf("CSD mismatch v%d: %llu vs %llu\n", v + 1, (unsigned long long)a, (unsigned long long)b); fails++; break; }
    }
    /* the phone's card: 29819 MiB v2 -> C_SIZE+1 = 29819*2 *1024/1024.. : sectors = (csize+1)*1024 */
    { uint32_t r[4] = {0,0,0,0}; put_bits(r,127,126,1); put_bits(r,69,48,59637); CHECK(sd_csd_sectors(r) == 29819ull*2048); }
    /* MBR */
    uint8_t s[512]; memset(s, 0, sizeof s);
    struct sd_mbr_ent e[4];
    CHECK(!sd_mbr_parse(s, e));
    s[510] = 0x55; s[511] = 0xAA;
    uint8_t *p = s + 446; p[4] = 0x0c; p[8] = 0x00; p[9] = 0x08; p[12] = 0xdf; p[13] = 0xcf; p[14] = 0xa3; p[15] = 0x03;   /* the phone's FAT32: lba 2048, 61067231 */
    CHECK(sd_mbr_parse(s, e));
    CHECK(e[0].type == 0x0c && e[0].lba == 2048 && e[0].sectors == 61067231);
    uint64_t lba, n;
    CHECK(sd_pick_partition(e, 0, 61069312, &lba, &n) == -1);          /* no 0xAF: nothing to boot from, never the FAT partition */
    CHECK(sd_pick_partition(e, 1, 61069312, &lba, &n) == 0 && lba == 2048);   /* explicit sdpart=1 */
    p = s + 446 + 16 * 2; p[4] = 0xAF; p[8] = 0x00; p[9] = 0x00; p[10] = 0x10; p[12] = 0x00; p[13] = 0x00; p[14] = 0x00; p[15] = 0x10;
    CHECK(sd_mbr_parse(s, e));
    CHECK(sd_pick_partition(e, 0, 0x7fffffffull, &lba, &n) == 0 && lba == 0x100000 && n == 0x10000000);
    /* the range check: partition running past the card */
    CHECK(sd_pick_partition(e, 3, 1000, &lba, &n) == -1);
    p = s + 446 + 16 * 3; p[4] = 0xEE; p[12] = 1;
    CHECK(sd_mbr_parse(s, e));
    CHECK(sd_pick_partition(e, 4, 61069312, &lba, &n) == -1);          /* protective GPT entry is never a root */
    printf(fails ? "FAILED\n" : "ALL PASS\n");
    return fails != 0;
}
