# Quick Start: Multiple Isolated Instances

## TL;DR

Run any app in its own isolated emu instance:

```bash
./run-app.sh <app.dis> [args...]
```

## Examples

```bash
# Simple console app
./run-app.sh hello.dis

# Simple Tk app
./run-app.sh simpletk.dis

# Bouncing balls (if WM compatible)
./run-app.sh wm/bounce.dis 8

# Clock (if WM compatible)
./run-app.sh wm/clock.dis
```

## Run Multiple Instances

```bash
# Terminal 1
./run-app.sh simpletk.dis

# Terminal 2
./run-app.sh simpletk.dis

# Terminal 3
./run-app.sh hello.dis
```

Each creates a separate window!

## What's Happening

```
./run-app.sh simpletk.dis
    ↓
Starts emu with wminit.dis
    ↓
wminit creates display + minimal WM
    ↓
wminit loads simpletk.dis
    ↓
simpletk runs in emu's X11 window
```

## Create Your Own App

### Simple Console App

```limbo
# myapp.b
implement Myapp;

include "sys.m";
    sys: Sys;

Myapp: module {
    init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
    sys = load Sys Sys->PATH;

    sys->print("Hello from my app!\n");
}
```

Compile and run:
```bash
cd appl/cmd
mk myapp.dis
./run-app.sh myapp.dis
```

### Simple Tk App

```limbo
# mytkapp.b
implement Mytkapp;

include "sys.m";
    sys: Sys;
include "draw.m";
    draw: Draw;
include "tk.m";
    tk: Tk;

Mytkapp: module {
    init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;
    tk = load Tk Tk->PATH;

    # Create window
    top := tk->toplevel(ctxt.display, "");

    # Add UI
    tk->cmd(top, "label .l -text {My App}");
    tk->cmd(top, "button .b -text Exit -command {send cmd exit}");
    tk->cmd(top, "pack .l .b");

    # Wait for exit
    cmdch := chan of string;
    tk->namechan(top, cmdch, "cmd");
    <-cmdch;
}
```

## Troubleshooting

### "cannot load app.dis"
```bash
# Build the app first
cd appl/<dir>
mk <app>.dis
```

### "cannot open display"
```bash
# Make sure X11 is running
echo $DISPLAY

# If empty, set it (Linux)
export DISPLAY=:0
```

### Windows stacked on top
- Manually move windows with host WM
- Use tiling mode in host WM
- Each window is independent (that's a feature!)

## Architecture

**Key Point:** Each emu instance = One process = One X11 window

```
Host Linux/NixOS
├── emu #1 → simpletk.dis → Window 1
├── emu #2 → simpletk.dis → Window 2
└── emu #3 → hello.dis     → Window 3
```

Perfect isolation!
