# Who am I
Written by Iman IRAJ DOOST for the NERD Emulator Production Engineer test.

# How I did it
I used GPT 5.6 Luna Agent to analyze the code and generate a step by step guide about how each tool can be executed and where variables are.

## Exercise 1
I created a worktree with the given commit.
Installed SDL and gcc.

`git -C $src worktree add --detach $buildRoot f133009adfac866c24d8259b6b4b24ce85abe330`

src being the path to the project and buildRoot being the new path of worktree.

``` 
cmake -S . -B build -G "MinGW Makefiles" `
  -DCMAKE_BUILD_TYPE=Release `
  -DBUILD_SDL=ON `
  -DBUILD_SDLGPU=OFF `
  -DBUILD_EDITORS=OFF `
  -DBUILD_WITH_RUBY=OFF `
  -DBUILD_WITH_ALL=OFF `
  -DBUILD_SURF=ON

```

`cmake --build build --parallel 4`

I set BUILD_WITH_ALL=OFF to avoid enabling other optional scripting runtimes.
I also set DBUILD_SURF=ON. It adds the Surf screen, without this I had an error.

NOTE: Since the build folder is in .gitignore file, I did not add the exported .exe file in my repository.

## Exercise 2
The collection is in testdata/tic80-top50, with the inventory in testdata/tic80-top50/index.tsv.
`01_*.tic` through `50_*.tic`: downloaded cartridges in catalog order.

`tools/download_top_tic80_games.ps1`: repeatable PowerShell collector

The README.md file pointed to `https://tic80.com/play` -> In the website, I looked at HTML code of `https://tic80.com/play/games/top`. Each card links to `/dev/<author>/<slug>`, and the **SHOW MORE** link exposes a `?page=1&partial=1` URL. The catalog of games is `https://tic80.com/js/catalog.js`. Then I opened a game's detail page and inspect its links. The `.tic` cartridge URL is like this: `/cart/<id>/<slug>.tic`. I used PowerShell's `Invoke-WebRequest` to download and `Get-FileHash -Algorithm MD5` for checksums. In TIC-80, enter `help commands` in the console; the command help list is defined by `HELP_CMD_LIST` in `src/studio/screens/console.c`.

## Exercise 3
Set TIC80_DUMMY_INPUTS=1 to generate dummy input.

Added patch to the input handling of the main.c file.

## Exercise 4
I added limit to the game loop and added the parsing of the `--during` command.

Example command to quit after 100 frames : `player-sdl.exe path\to\your-cart.tic --during 100`

## Exercise 5
player-sdl now accepts --vram-crc <output.txt>. It skips the first 200 frames.
This was a little more complicated, I iterated with AI to understand what can be done.

## Exercise 6

Code for build:
`cmake --build build-dummy --target player-sdl --parallel 4`

Running the tests:
`ctest --test-dir build-dummy --output-on-failure`

Running every game for 1 minute:
`.\tools\run_top_tic80_games.ps1`

This powershell script runs `player-sdl.exe --during 3600 --vram-crc <output> <game.tic>`
which runs the games for 3600 frames.

There is also a deterministic dummy input in Player.c file.
The tests capture
summary.json
results.csv
analysis.md
VRAM checksum files
stdout/stderr logs

The game passes tests when all checksum frames pass (200 frames of startup is not counted).

## Exercise 7

Executed tests in headless mode. Instead of rendering each frame, I advance the time headlessly, so there is no SDL delay.
The tests run about 10 times faster now.
The command that does this is `--vram-crc`, same as last exercise.
