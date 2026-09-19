// MIT License

// Copyright (c) 2017 Vadim Grigoruk @nesbox

#pragma once

#include <stddef.h>

#include "tic.h"

#define TIC80_VRAM_CRC_STARTUP_FRAMES 200

static inline u32 tic80_crc32_update(u32 crc, const u8* data, size_t size)
{
    while(size--)
    {
        crc ^= *data++;

        for(s32 bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }

    return crc;
}

static inline u32 tic80_crc32(const u8* data, size_t size)
{
    return ~tic80_crc32_update(0xffffffffu, data, size);
}

static inline u32 tic80_vram_crc32(const tic_vram* bank0, const tic_vram* bank1)
{
    u32 crc = tic80_crc32_update(0xffffffffu, bank0->data, TIC_VRAM_SIZE);
    crc = tic80_crc32_update(crc, bank1->data, TIC_VRAM_SIZE);
    return ~crc;
}

static inline u32 tic80_vram_crc32_mapped(const tic_vram* mappedBank, const tic_vram* otherBank, s32 mappedBankId)
{
    return mappedBankId == 0
        ? tic80_vram_crc32(mappedBank, otherBank)
        : tic80_vram_crc32(otherBank, mappedBank);
}

static inline bool tic80_vram_crc_should_capture(s32 completedFrames)
{
    return completedFrames > TIC80_VRAM_CRC_STARTUP_FRAMES;
}
