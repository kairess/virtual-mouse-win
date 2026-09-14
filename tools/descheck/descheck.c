/*
 * descheck.c
 *
 * Validates driver/ReportDescriptor.h. Runs on the host with nothing but the
 * Windows SDK, so the single most important artifact of this project can be
 * checked before the WDK is even installed.
 *
 * It asserts the things that actually decide whether Windows binds mouclass:
 *   - MOUSE_REPORT_DESCRIPTOR_SIZE matches the real array length
 *   - sizeof(MOUSE_INPUT_REPORT) matches MOUSE_INPUT_REPORT_SIZE_CB
 *   - the top-level collection is Generic Desktop (0x01) / Mouse (0x02)
 *   - collections are balanced
 *   - the declared input bits are byte aligned and add up to the struct size
 *
 * The driver enforces the first two again with C_ASSERT at build time; this
 * tool covers the rest and gives a readable hex dump when something is off.
 *
 * Build+run: scripts\Build-Tool.ps1
 */
#include <windows.h>
#include <stdio.h>
#include "ReportDescriptor.h"

static unsigned char desc[] = MOUSE_REPORT_DESCRIPTOR;

int main(void)
{
    size_t i;
    int depth = 0, maxdepth = 0;
    int inputBits = 0;
    int reportSize = 0, reportCount = 0;
    int sawMouseTlc = 0;
    int fail = 0;

    printf("sizeof(desc)                 = %zu\n", sizeof(desc));
    printf("MOUSE_REPORT_DESCRIPTOR_SIZE = %d\n", MOUSE_REPORT_DESCRIPTOR_SIZE);
    if (sizeof(desc) != MOUSE_REPORT_DESCRIPTOR_SIZE) {
        printf("  FAIL: size macro mismatch\n"); fail = 1;
    } else {
        printf("  OK\n");
    }

    printf("sizeof(MOUSE_INPUT_REPORT)   = %zu (macro says %d)\n",
           sizeof(MOUSE_INPUT_REPORT), MOUSE_INPUT_REPORT_SIZE_CB);
    if (sizeof(MOUSE_INPUT_REPORT) != MOUSE_INPUT_REPORT_SIZE_CB) {
        printf("  FAIL: report struct size mismatch\n"); fail = 1;
    } else {
        printf("  OK\n");
    }

    /* Top-level collection must be Generic Desktop / Mouse. */
    if (sizeof(desc) >= 6 &&
        desc[0] == 0x05 && desc[1] == 0x01 &&   /* Usage Page (Generic Desktop) */
        desc[2] == 0x09 && desc[3] == 0x02 &&   /* Usage (Mouse) */
        desc[4] == 0xA1 && desc[5] == 0x01) {   /* Collection (Application) */
        sawMouseTlc = 1;
    }
    printf("top-level collection = Generic Desktop / Mouse : %s\n",
           sawMouseTlc ? "OK" : "FAIL");
    if (!sawMouseTlc) fail = 1;

    /* Walk short items: bTag|bType|bSize, then bSize data bytes (3 => 4). */
    for (i = 0; i < sizeof(desc); ) {
        unsigned char b = desc[i];
        int bSize = b & 0x03;
        int bType = (b >> 2) & 0x03;
        int bTag  = (b >> 4) & 0x0F;
        int len   = (bSize == 3) ? 4 : bSize;
        unsigned int data = 0;
        int k;

        if (b == 0xFE) { printf("  FAIL: long items not supported here\n"); fail = 1; break; }
        if (i + 1 + len > sizeof(desc)) {
            printf("  FAIL: item at offset %zu runs past end of descriptor\n", i);
            fail = 1; break;
        }
        for (k = 0; k < len; k++) data |= ((unsigned int)desc[i + 1 + k]) << (8 * k);

        if (bType == 0) {                      /* Main */
            if (bTag == 0xA) { depth++; if (depth > maxdepth) maxdepth = depth; }
            else if (bTag == 0xC) { depth--; }
            else if (bTag == 0x8) {            /* Input */
                inputBits += reportSize * reportCount;
            }
        } else if (bType == 1) {               /* Global */
            if (bTag == 0x7) reportSize = (int)data;
            if (bTag == 0x9) reportCount = (int)data;
        }

        i += 1 + len;
    }

    printf("collection depth balanced    : %s (depth=%d, max=%d)\n",
           depth == 0 ? "OK" : "FAIL", depth, maxdepth);
    if (depth != 0) fail = 1;

    printf("total input bits             = %d (%d bytes)\n", inputBits, inputBits / 8);
    if (inputBits % 8 != 0) {
        printf("  FAIL: input report is not byte aligned\n"); fail = 1;
    } else if (inputBits / 8 != (int)sizeof(MOUSE_INPUT_REPORT)) {
        printf("  FAIL: descriptor says %d bytes but struct is %zu bytes\n",
               inputBits / 8, sizeof(MOUSE_INPUT_REPORT));
        fail = 1;
    } else {
        printf("  OK: matches MOUSE_INPUT_REPORT\n");
    }

    printf("\nbytes:\n");
    for (i = 0; i < sizeof(desc); i++) {
        printf("%02X ", desc[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    printf("\n\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
    return fail;
}
