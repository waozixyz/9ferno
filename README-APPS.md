# TaijiOS Multiple Isolated Instances

This document describes how to run multiple isolated emu instances, each with its own app and X11 window.

## Architecture

```
Host OS (Linux/NixOS with X11)
├── emu instance #1 → app1.dis → Host Window 1 (X11 window)
├── emu instance #2 → app2.dis → Host Window 2 (X11 window)
├── emu instance #3 → app3.dis → Host Window 3 (X11 window)
└── emu instance #N → appN.dis → Host Window N (X11 window)
```

## Key Features

- **Multiple isolated emu instances** - Each app runs in its own emu process
- **Separate host windows** - Each emu creates its own X11 window on the host
- **Shared kernel** - All instances use the same Inferno/TaijiOS binaries
- **Perfect isolation** - Apps don't know about each other, completely isolated
- **Mix of apps** - Both existing Inferno apps and new custom apps

## Usage

### Basic Usage

```bash
# Run bouncing balls with 8 balls
./run-app.sh wm/bounce.dis 8

# Run clock
./run-app.sh wm/clock.dis

# Run snake game
./run-app.sh wm/snake.dis

# Run with custom app
./run-app.sh myapp.dis arg1 arg2
```

### Multiple Instances

```bash
# Terminal 1
./run-app.sh wm/bounce.dis 8

# Terminal 2 (different number of balls)
./run-app.sh wm/bounce.dis 16

# Terminal 3
./run-app.sh wm/clock.dis
```

Each creates a separate emu instance, separate X11 window, completely isolated.

## Implementation

### Files

1. **`/appl/cmd/wminit.b`** - Universal app launcher
   - Initializes display context
   - Starts minimal WM for tkclient compatibility
   - Loads and runs the specified app

2. **`/run-app.sh`** - Launcher script
   - Runs any .dis app in isolated emu instance
   - Auto-builds apps if needed
   - Sets up environment variables

3. **`/dis/wminit.dis`** - Compiled launcher

### How It Works

1. `run-app.sh` builds the app and wminit if needed
2. Starts emu with wminit.dis as the init program
3. wminit creates a display context and minimal WM
4. wminit loads the specified app.dis
5. App runs fullscreen in emu's X11 window
6. Each instance is completely isolated

## Advantages

- ✅ Perfect isolation (process-level)
- ✅ Simple architecture (no complex WM code)
- ✅ Universal compatibility (works with any .dis app)
- ✅ Easy to use (single command)
- ✅ Scalable (unlimited instances)
- ✅ Development friendly (fast iteration)

## App Compatibility

### Tk-based Apps

Apps using `tkclient` (like bounce, clock, etc.) work because wminit starts a minimal WM instance.

### Console Apps

Console apps that don't use graphics also work fine.

### Custom Apps

To create a custom app:

1. Create a Limbo module with `init(ctxt: ref Draw->Context, argv: list of string)`
2. Compile to `.dis`
3. Run with `./run-app.sh myapp.dis`

## Window Management

Each emu instance creates its own X11 window. The host OS window manager handles:
- Window placement (tiling, stacking, etc.)
- Focus management (click to focus)
- Window decorations (if enabled by host WM)
- Resize/move operations

## Troubleshooting

### App fails to load

```bash
# Build the app first
cd appl/wm  # or wherever the app is
mk bounce.dis

# Then run
./run-app.sh wm/bounce.dis 8
```

### Windows stack on top of each other

Use your host OS window manager to arrange windows:
- Manual drag/arrange
- Tiling mode (if available)
- Window positioning tools

### Can't find app.dis

Make sure the app path is relative to `/dis/`:
```bash
# Correct
./run-app.sh wm/bounce.dis

# Incorrect (will not work)
./run-app.sh /dis/wm/bounce.dis
./run-app.sh bounce.dis
```

## Examples

### Development Workflow

```bash
# Edit your app
vim appl/myapp/myapp.b

# Build (automatically done by run-app.sh)
cd appl/myapp
mk myapp.dis

# Test
./run-app.sh myapp.dis

# Run multiple instances for testing
./run-app.sh myapp.dis test1 &
./run-app.sh myapp.dis test2 &
```

### Running Multiple Different Apps

```bash
# Terminal 1: Bouncing balls
./run-app.sh wm/bounce.dis 8

# Terminal 2: Clock
./run-app.sh wm/clock.dis

# Terminal 3: Snake game
./run-app.sh wm/snake.dis

# Terminal 4: Custom app
./run-app.sh myapp.dis
```

## Future Enhancements

Possible additions:
- Window geometry specification (`--geometry 640x480+0+0`)
- Batch launcher script
- Auto-tiling helper
- App-specific configurations

## See Also

- `run.sh` - Main TaijiOS launcher (runs with full WM)
- `appl/wm/` - Window manager apps
- `module/tkclient.m` - Tk client interface
- `module/wmsrv.m` - Window manager service
