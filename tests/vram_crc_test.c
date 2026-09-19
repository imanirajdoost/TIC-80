#include <stdio.h>
#include <string.h>

#include "vram_crc.h"

#define CHECK(condition) \
    do { \
        if(!(condition)) { \
            fprintf(stderr, "FAIL: %s (line %d)\n", #condition, __LINE__); \
            return 1; \
        } \
    } while(0)

int main(void)
{
    static const u8 vector[] = "123456789";
    CHECK(tic80_crc32(vector, sizeof(vector) - 1) == 0xcbf43926u);
    CHECK(tic80_crc32(NULL, 0) == 0u);

    static tic_vram bank0;
    static tic_vram bank1;

    memset(&bank0, 0, sizeof(bank0));
    memset(&bank1, 0, sizeof(bank1));
    bank0.data[0] = 0x11;
    bank0.data[TIC_VRAM_SIZE - 1] = 0x22;
    bank1.data[0] = 0x33;
    bank1.data[TIC_VRAM_SIZE - 1] = 0x44;
    CHECK(tic80_vram_crc32(&bank0, &bank1) == 0x1485ffa3u);
    CHECK(tic80_vram_crc32_mapped(&bank0, &bank1, 0) == 0x1485ffa3u);
    CHECK(tic80_vram_crc32_mapped(&bank1, &bank0, 1) == 0x1485ffa3u);

    CHECK(!tic80_vram_crc_should_capture(0));
    CHECK(!tic80_vram_crc_should_capture(TIC80_VRAM_CRC_STARTUP_FRAMES));
    CHECK(tic80_vram_crc_should_capture(TIC80_VRAM_CRC_STARTUP_FRAMES + 1));

    puts("VRAM CRC32 tests passed");
    return 0;
}
