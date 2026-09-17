# Who am I
Written by Iman IRAJ DOOST for the NERD Emulator Production Engineer test.

# How I did it
I used GPT 5.6 Luna Agent to analyze the code and generate a step by step guide about how each tool can be executed and where variables are.

## Exercie 1
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