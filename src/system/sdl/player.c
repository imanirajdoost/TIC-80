// MIT License

// Copyright (c) 2017 Vadim Grigoruk @nesbox

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <SDL.h>
#include <tic80.h>
#include "core/core.h"
#include "vram_crc.h"

#if defined(__APPLE__)
# if MAC_OS_X_VERSION_MIN_REQUIRED < 1060
#    error SDL for Mac OS X only supports deploying on 10.6 and above.
# endif /* MAC_OS_X_VERSION_MIN_REQUIRED < 1060 */
#endif

#define TIC80_WINDOW_SCALE 3
#define TIC80_WINDOW_TITLE "TIC-80"
#define TIC80_DEFAULT_CART "cart.tic"
#define TIC80_EXECUTABLE_NAME "player-sdl"
#define TIC80_DETERMINISTIC_EPOCH 946684800 // 2000-01-01T00:00:00Z

static struct
{
    s32 remaining;
    SDL_mutex *mutex;
    bool quit;
    u64 fastForwardCounter;
} state = {0};

static s32 frameLimit = -1;

/*
 * The studio has a deterministic input generator for unattended runs.  Keep
 * the standalone player compatible with it so headless integration tests can
 * exercise gameplay code instead of only rendering an idle cart.
 */
static int dummy_input_rand(int n)
{
    static unsigned int random = 0x2026;
    random ^= random << 7;
    random ^= random >> 9;
    random ^= random << 8;
    return (int)(random % (unsigned int)n);
}

static void get_dummy_inputs(char buttons[8])
{
    static struct
    {
        int delay;
        char up, down, left, right, a, b, x, y;
    } state;

    if(state.delay)
        state.delay--;
    else
    {
        state.up = dummy_input_rand(10) < 6;
        state.down = !state.up && dummy_input_rand(10) < 4;
        state.left = dummy_input_rand(10) < 2;
        state.right = !state.left && dummy_input_rand(10) < 7;
        state.a = dummy_input_rand(10) < 6;
        state.b = dummy_input_rand(10) < 2;
        state.x = dummy_input_rand(10) < 3;
        state.y = dummy_input_rand(10) < 2;
        state.delay = dummy_input_rand(20) + 10;
    }

    buttons[0] = state.up;
    buttons[1] = state.down;
    buttons[2] = state.left;
    buttons[3] = state.right;
    buttons[4] = state.a;
    buttons[5] = state.b;
    buttons[6] = state.x;
    buttons[7] = state.y;
}

static void onExit()
{
    state.quit = true;
}

static u64 tic_sys_counter_get()
{
    return SDL_GetPerformanceCounter();
}

static u64 tic_sys_freq_get()
{
    return SDL_GetPerformanceFrequency();
}

/*
 * Checksum capture is an automated-test mode: it has no window or audio
 * device, so waiting for real time only makes the test suite slower.  Advance
 * a virtual 60 Hz clock instead.  This keeps TIC's time() API aligned with
 * the emulated frame count, rather than changing its behaviour to host CPU
 * speed while running tests.
 */
static u64 tic_fast_forward_counter_get()
{
    return state.fastForwardCounter;
}

static u64 tic_fast_forward_freq_get()
{
    return TIC80_FRAMERATE;
}

/*
 * tstamp() is an observable part of the TIC machine.  Use an epoch that moves
 * with the virtual clock in checksum mode, rather than leaking the host's
 * wall clock into a replay.  Normal interactive player runs still pass NULL
 * for this callback and therefore retain their existing wall-clock semantics.
 */
static s32 tic_fast_forward_timestamp_get()
{
    return TIC80_DETERMINISTIC_EPOCH + (s32)(state.fastForwardCounter / TIC80_FRAMERATE);
}

static void audioCallback(void* userdata, u8* stream, s32 len)
{
    SDL_LockMutex(state.mutex);
    {
        tic80* tic = userdata;

        while(len--)
        {
            if (state.remaining <= 0)
            {
                tic80_sound(tic);
                state.remaining = tic->samples.count * TIC80_SAMPLESIZE;
            }

            *stream++ = ((u8*)tic->samples.buffer)[tic->samples.count * TIC80_SAMPLESIZE - state.remaining--];
        }
    }
    SDL_UnlockMutex(state.mutex);
}

s32 runCart(void* cart, s32 size, const char* vramCrcPath)
{
    s32 output = 0;
    const char* dummyInputEnv = getenv("TIC80_DUMMY_INPUTS");
    const bool dummyInputs = dummyInputEnv && dummyInputEnv[0] && strcmp(dummyInputEnv, "0") != 0;
    const bool fastForward = vramCrcPath != NULL;

    tic80_input input;
    SDL_memset(&input, 0, sizeof input);

    FILE* vramCrcFile = NULL;
    if(vramCrcPath)
    {
        vramCrcFile = fopen(vramCrcPath, "w");
        if(!vramCrcFile)
        {
            fprintf(stderr, "Error: Could not open VRAM checksum output %s.\n", vramCrcPath);
            SDL_free(cart);
            return 1;
        }
    }

    tic80* tic = tic80_create(TIC80_SAMPLERATE, TIC80_PIXEL_COLOR_RGBA8888);

    if(!tic)
    {
        fprintf(stderr, "Failed to load cart data.");
        output = 1;
    }
    else
    {
        tic->callback.exit = onExit;
        tic80_load(tic, cart, size);

        const bool renderEnabled = !fastForward;
        SDL_Window* window = NULL;
        SDL_Renderer* renderer = NULL;
        SDL_Texture* texture = NULL;
        SDL_AudioDeviceID audioDevice = 0;
        SDL_AudioSpec audioSpec;

        if(renderEnabled)
        {
            SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO);

            window = SDL_CreateWindow(TIC80_WINDOW_TITLE, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, TIC80_FULLWIDTH * TIC80_WINDOW_SCALE, TIC80_FULLHEIGHT * TIC80_WINDOW_SCALE, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
            renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
            texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, TIC80_FULLWIDTH, TIC80_FULLHEIGHT);

            if(renderEnabled)
            {
                state.mutex = SDL_CreateMutex();

                SDL_AudioSpec want =
                {
                    .freq = TIC80_SAMPLERATE,
                    .format = AUDIO_S16,
                    .channels = TIC80_SAMPLE_CHANNELS,
                    .callback = audioCallback,
                    .samples = 1024,
                    .userdata = tic,
                };

                audioDevice = SDL_OpenAudioDevice(NULL, 0, &want, &audioSpec, 0);
            }
        }
        else
        {
            SDL_Init(SDL_INIT_TIMER);
        }

        const u64 Delta = SDL_GetPerformanceFrequency() / TIC80_FRAMERATE;
        u64 nextTick = SDL_GetPerformanceCounter();
        s32 frames = 0;
        state.fastForwardCounter = 0;

        if(audioDevice)
            SDL_PauseAudioDevice(audioDevice, 0);

        while(!state.quit && (frameLimit < 0 || frames < frameLimit))
        {
            input.gamepads.data = 0;

            if(renderEnabled)
            {
                SDL_Event event;

                while(SDL_PollEvent(&event))
                {
                    switch(event.type)
                    {
                    case SDL_QUIT:
                        state.quit = true;
                        break;
                    case SDL_KEYUP:
                        // Quit when pressing the escape button.
                        if(event.key.keysym.sym == SDLK_ESCAPE)
                        {
                            state.quit = true;
                        }
                        break;
                    }
                }

                const uint8_t* keyboard = SDL_GetKeyboardState(NULL);

                static const SDL_Scancode Keys[] =
                {
                    SDL_SCANCODE_UP,
                    SDL_SCANCODE_DOWN,
                    SDL_SCANCODE_LEFT,
                    SDL_SCANCODE_RIGHT,

                    SDL_SCANCODE_Z,
                    SDL_SCANCODE_X,
                    SDL_SCANCODE_A,
                    SDL_SCANCODE_S,
                };

                for (u32 i = 0; i < SDL_arraysize(Keys); i++)
                {
                    if (keyboard[Keys[i]])
                    {
                        input.gamepads.first.data |= (1 << i);
                    }
                }
            }

            if(state.mutex)
                SDL_LockMutex(state.mutex);
            {
                tic80_tick_with_timestamp(tic, input,
                    fastForward ? tic_fast_forward_counter_get : tic_sys_counter_get,
                    fastForward ? tic_fast_forward_freq_get : tic_sys_freq_get,
                    fastForward ? tic_fast_forward_timestamp_get : NULL);
                frames++;
                if(fastForward)
                    state.fastForwardCounter++;

                if(vramCrcFile && tic80_vram_crc_should_capture(frames))
                {
                    const tic_core* core = (const tic_core*)tic;
                    const u32 checksum = tic80_vram_crc32_mapped(
                        &core->memory.ram->vram,
                        &core->state.vbank.mem,
                        core->state.vbank.id);

                    if(fprintf(vramCrcFile, "%08x\n", (unsigned int)checksum) < 0)
                    {
                        fprintf(stderr, "Error: Failed writing VRAM checksum output %s.\n", vramCrcPath);
                        output = 1;
                        state.quit = true;
                    }
                }
            }

            if(dummyInputs)
            {
                char buttons[8];
                get_dummy_inputs(buttons);
                input.gamepads.first.up = buttons[0];
                input.gamepads.first.down = buttons[1];
                input.gamepads.first.left = buttons[2];
                input.gamepads.first.right = buttons[3];
                input.gamepads.first.a = buttons[4];
                input.gamepads.first.b = buttons[5];
                input.gamepads.first.x = buttons[6];
                input.gamepads.first.y = buttons[7];
            }
            if(state.mutex)
                SDL_UnlockMutex(state.mutex);

            if(renderEnabled)
            {
                SDL_RenderClear(renderer);

                {
                    void* pixels = NULL;
                    s32 pitch = 0;
                    SDL_Rect destination;
                    SDL_LockTexture(texture, NULL, &pixels, &pitch);
                    SDL_memcpy(pixels, tic->screen, pitch * TIC80_FULLHEIGHT);
                    SDL_UnlockTexture(texture);

                    // Render the image in the proper aspect ratio.
                    {
                        s32 windowWidth, windowHeight;
                        SDL_GetWindowSize(window, &windowWidth, &windowHeight);
                        float widthRatio = (float)windowWidth / TIC80_FULLWIDTH;
                        float heightRatio = (float)windowHeight / TIC80_FULLHEIGHT;
                        float optimalSize = widthRatio < heightRatio ? widthRatio : heightRatio;
                        destination.w = (s32)(TIC80_FULLWIDTH * optimalSize);
                        destination.h = (s32)(TIC80_FULLHEIGHT * optimalSize);
                        destination.x = windowWidth / 2 - destination.w / 2;
                        destination.y = windowHeight / 2 - destination.h / 2;
                    }

                    SDL_RenderCopy(renderer, texture, NULL, &destination);
                }

                SDL_RenderPresent(renderer);
            }

            if(!fastForward)
            {
                s64 delay = (nextTick += Delta) - SDL_GetPerformanceCounter();

                if(delay > 0)
                    SDL_Delay((u32)(delay * 1000 / SDL_GetPerformanceFrequency()));
            }
        }

        tic80_delete(tic);

        if(renderEnabled)
        {
            if(audioDevice)
                SDL_CloseAudioDevice(audioDevice);
            if(state.mutex)
                SDL_DestroyMutex(state.mutex);
            SDL_DestroyTexture(texture);
            SDL_DestroyRenderer(renderer);
            SDL_DestroyWindow(window);
        }
    }

    if(vramCrcFile && fclose(vramCrcFile) != 0)
    {
        fprintf(stderr, "Error: Failed closing VRAM checksum output %s.\n", vramCrcPath);
        output = 1;
    }

    SDL_free(cart);
    return output;
}

s32 main(s32 argc, char **argv)
{
    const char* executable = argc > 0 ? argv[0] : TIC80_EXECUTABLE_NAME;
    const char* input = NULL;
    const char* vramCrcPath = NULL;

    for(s32 i = 1; i < argc; i++)
    {
        if(strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
        {
            printf("Usage: %s [--during N] [--vram-crc <output.txt>] [<file>]\n", executable);
            return 0;
        }
        else if(strcmp(argv[i], "--during") == 0)
        {
            char* end = NULL;
            long value;

            if(i + 1 >= argc)
            {
                fprintf(stderr, "Error: --during requires a non-negative frame count.\n");
                return 1;
            }

            errno = 0;
            value = strtol(argv[++i], &end, 10);
            if(errno || end == argv[i] || *end != '\0' || value < 0 || value > INT_MAX)
            {
                fprintf(stderr, "Error: invalid frame count for --during: %s\n", argv[i]);
                return 1;
            }
            frameLimit = (s32)value;
        }
        else if(strcmp(argv[i], "--vram-crc") == 0)
        {
            if(i + 1 >= argc)
            {
                fprintf(stderr, "Error: --vram-crc requires an output file.\n");
                return 1;
            }
            vramCrcPath = argv[++i];
        }
        else if(!input)
        {
            input = argv[i];
        }
        else
        {
            fprintf(stderr, "Error: unexpected argument: %s\n", argv[i]);
            return 1;
        }
    }

    if(!input)
        input = TIC80_DEFAULT_CART;

    // Load the given file.
    FILE* file = fopen(input, "rb");
    if(!file)
    {
        fprintf(stderr, "Error: Could not load %s.\n\nUsage: %s [--during N] [--vram-crc <output.txt>] [<file>]\n", input, executable);
        return 1;
    }

    // Load the file data.
    fseek(file, 0, SEEK_END);
    s32 size = ftell(file);
    fseek(file, 0, SEEK_SET);

    // Read the data into usable memory.
    void* cart = SDL_malloc(size);
    if(cart) fread(cart, size, 1, file);
    fclose(file);

    if (!cart) {
        fprintf(stderr, "Error reading %s.\n", input);
        return 1;
    }

    return runCart(cart, size, vramCrcPath);
}
