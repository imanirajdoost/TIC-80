#include <stdio.h>
#include <time.h>

#include "core/core.h"

#define CHECK(condition) \
    do { \
        if(!(condition)) { \
            fprintf(stderr, "FAIL: %s (line %d)\n", #condition, __LINE__); \
            return 1; \
        } \
    } while(0)

static s32 fixedTimestamp(void* data)
{
    return *(const s32*)data;
}

int main(void)
{
    tic_core core = {0};
    const s32 expected = 946684800;
    tic_tick_data data =
    {
        .data = (void*)&expected,
        .timestamp = fixedTimestamp,
    };

    core.data = &data;
    CHECK(tic_api_tstamp(&core.memory) == expected);

    // A NULL callback is the backwards-compatible public-player behaviour.
    data.timestamp = NULL;
    const s32 before = (s32)time(NULL);
    const s32 actual = tic_api_tstamp(&core.memory);
    const s32 after = (s32)time(NULL);
    CHECK(actual >= before && actual <= after);

    puts("Timestamp source tests passed");
    return 0;
}
