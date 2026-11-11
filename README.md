# iSnow ❄️

**It snows on your Mac.** iSnow is a tiny menu bar app that lets snow fall over everything on
your screen. Snow settles on top of your windows, the Dock, desktop icons and widgets, icicles grow
under windows you leave alone, and snowmen build themselves on the Dock.

It is not a wallpaper or a screensaver – it snows on top of whatever you are doing, and every click
goes straight through the snow.

![iSnow – snow drifts on windows, icicles and snowmen on the Dock](media/hero.png)

**Current version: 1.0** · macOS 14 Sonoma or later · Apple silicon and Intel · about 1 MB

## Install

### Download (recommended)

1. Download **`iSnow-v1.0.dmg`** (and `iSnow-v1.0.dmg.sha256`) from the
   [Releases](https://github.com/filiphajduch420/iSnow/releases/latest) page.
2. Verify the download – both files in the same folder:
   ```sh
   shasum -a 256 -c iSnow-v1.0.dmg.sha256
   ```
   It should print `iSnow-v1.0.dmg: OK`. The SHA-256 of `iSnow-v1.0.dmg` is:
   ```
   130416b29b5d53a61c9bcc01a21ef5b09aefe5aad8fca8cbb4d5392237e1e966
   ```
3. Open the DMG and drag **iSnow** onto **Applications**.
4. Open iSnow. Because it isn't signed with an Apple Developer ID certificate, macOS says it can't
   verify the app. Go to **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to the iSnow message, then confirm with **Open**. (Or run
   `xattr -dr com.apple.quarantine /Applications/iSnow.app` in Terminal.) The app is fully open
   source – you can read every line and build it yourself.
5. A snowflake appears in the menu bar and it starts snowing. For snow on the Dock and desktop
   icons, [allow Accessibility](#allowing-accessibility).

### Build from source

You need Xcode or the Xcode Command Line Tools (Swift 6) – no other dependencies.

```sh
git clone https://github.com/filiphajduch420/iSnow.git
cd iSnow
./build.sh --install          # builds and signs iSnow.app, copies it to ~/Applications and launches it
```

| Command | What it does |
|---|---|
| `./build.sh` | Builds `build/iSnow.app` (universal). Signs it with your *Apple Development* certificate if you have one, so Accessibility survives rebuilds; otherwise ad hoc. |
| `./build.sh --install` | The same, then installs to `~/Applications` and launches it. |
| `./scripts/release.sh 1.0` | Builds the release DMG and its SHA-256 checksum into `dist/`. |
| `./scripts/screenshots.sh` | Renders the screenshots below into `media/` – no screen recording needed. |

## Screenshots

| | |
|---|---|
| ![Christmas mode](media/christmas.png) | ![A moved window drops its drift](media/slide.png) |
| **Christmas mode** – a tree, lights under the menu bar and Santa hats | **Move a window** – the drift breaks off and crumbles into clumps |
| ![Hard frost](media/frost.png) | ![Settings – Snowfall](media/settings-snowfall.png) |
| **Hard frost (−20 °C)** – long icicles and frosted windows | **Settings** – presets, temperature, flakes |
| ![Settings – Drifts](media/settings-drifts.png) | ![Settings – Snowman](media/settings-snowman.png) |
| **Drifts** – where snow settles, unlimited hills, ice | **Snowmen** – how many, how big, snowball fights |

## Features

- **Snowfall** with parallax depth, gusty wind and four presets: Flurry, Normal, Blizzard, Snowstorm.
- **Drifts** pile up on the visible top edges of windows, on the Dock, on desktop icons and widgets,
  and along the bottom of the screen. Hidden parts of a window stay snow-free. By default they never stop
  growing: snow keeps piling up into hills (only the top of the screen limits them), and snowmen
  ride on top. A fixed maximum height can be set instead.
- **Move a window** and its drift breaks off as a slab that crumbles into clumps with a puff of
  powder, carried a little in the direction you dragged it. The clumps land on whatever is below and
  pile up again. A small nudge only shakes off the loose top layer. Close a window and all of it falls.
- **Shovel:** a quick swipe of the cursor brushes snow off, and holding **⌥ Option** turns the
  cursor into a shovel that pushes snow aside at any speed – on windows, the Dock and the bottom of
  the screen. The menu also has *Shovel Snow at the Bottom*.
- **Icicles** grow under windows that stay still for a while (and under the menu bar). Move the
  window and they snap off.
- **Snowmen** on the Dock (one to six): each rolls in three balls, stacks them, puts on a scarf
  and a carrot nose, waves, and throws snowballs at your windows and icons. After a few minutes it
  falls apart and melts, and later a new one appears. Click a snowman to knock it apart – every
  third hit drops a level, and sometimes it fights back.
- **Drag a snowman** anywhere – onto a window, next to the Dock, wherever. It drops onto whatever is
  below, and if that window moves, it falls again.
- **Temperature** from −25 °C to +10 °C. Above zero the snow gets wet and drifts, icicles and
  snowmen melt; above +4 °C it turns to sleet. Below zero nothing melts, icicles grow faster, longer
  (up to about 3× in hard frost) and thicker, and windows frost over from the corners – the colder, the more.
- **Stays out of your way:** snow at the bottom never covers the Dock's icons and hides behind
  windows, snow on the Dock shrinks to a thin ledge under a window, icicles never hang into the Dock,
  and a snowman that covers a window fades out and lets clicks through. Without Accessibility
  permission the Dock's position is estimated from its preferences.
- **Christmas mode:** a decorated tree with twinkling lights, a glowing star and presents next to
  the Dock, a string of lights under the menu bar (colorful, warm white or chasing) and Santa hats
  for the snowmen.
- **Extras:** the cursor scatters flakes, sparkling
  flakes, custom snow color, melting, frosted screen edges, and no snow over full-screen apps.

## Settings

Open **Settings…** (⌘,) from the snowflake in the menu bar:

| Tab | What you can change |
|---|---|
| Snowfall | Preset, temperature, density, max number of flakes, flake size, fall speed, wind, sparkle, snow color |
| Drifts | Where snow settles (windows, Dock, icons, widgets, menu bar), unlimited hills or a max drift height on windows and at the bottom, pile-up speed, *Shake Off All Snow*, window frost, icicles and their length |
| Snowman | On/off, number of snowmen, size, break between snowmen, fade when covering a window, *Back to the Dock*, *Build Now*, snowball fight and how often it throws |
| Christmas | Christmas mode, tree and its size, lights under the menu bar, light style, Santa hats |
| Other | Cursor interaction, frosted edges, full-screen pause, 30 / 60 / 120 fps, launch at login, restore defaults |

The app is in English and Czech and follows your system language.

## Permissions and privacy

- **No permission is needed for snow on windows and desktop widgets.** Their positions come from
  `CGWindowList`; the app reads where they are, never what is inside them. No Screen Recording
  permission is used.
- **The exact position of the Dock and snow on desktop icons** need *Accessibility* permission (to
  read the Dock's and the desktop icons' positions). Without it, everything else still works and
  the Dock's position is estimated from its preferences – usually close, but it can be off by an
  icon or two.
- No network access, no analytics, nothing leaves your Mac. Settings are stored in `UserDefaults`.

### Allowing Accessibility

1. Click the snowflake in the menu bar and choose **Allow Snow on the Dock and Icons…**
   (or open **Settings… → Drifts → Allow…**). macOS shows a prompt – click **Open System Settings**.
2. If the prompt doesn't appear, open **System Settings → Privacy & Security → Accessibility** yourself.
3. Turn on the switch next to **iSnow**. If iSnow isn't listed, click **+** at the bottom of the list,
   choose **iSnow** in your **Applications** folder (`~/Applications` if you used `./build.sh --install`)
   and click **Open**.
4. Confirm with Touch ID or your password. Within a second the snowmen line up along the whole Dock
   and snow starts settling on your desktop icons – no restart needed.

**After rebuilding the app:** `build.sh` signs iSnow with your *Apple Development* certificate if you
have one (any free Apple ID signed in to Xcode gives you one) – then macOS keeps the permission
across rebuilds. Without a certificate the app is signed ad hoc, every build looks like a different
app to macOS, and the switch can stop working even though it still shows as on. In that case select
**iSnow** in the list, remove it with **−**, and add it again (step 3). If you used an older version
called *Vločka*, you can remove that entry too.

The menu shows *Dock position is estimated* while iSnow doesn't have the permission.

## Performance

iSnow is built to stay out of the way:

- one instanced Metal draw call for all particles and one for all triangles (drifts, icicles,
  snowman); shaders are compiled from source, so there are no textures or other assets;
- `CADisplayLink` capped at 60 fps (configurable), 30 fps in Low Power Mode;
- rendering stops completely when nothing is moving, and while the screen is asleep or locked;
- window positions are polled 5× per second (30× while a window is being dragged), Accessibility queries run off the main thread
  once per second.

On an M-series Mac a normal snowfall uses about 1 % CPU and about 20 MB of memory. The app bundle is
about 1 MB.

## How it works

| File | Role |
|---|---|
| `App.swift` | SwiftUI `MenuBarExtra`, settings scene, app delegate that wires screens, polling and power events |
| `SettingsView.swift` | The settings window |
| `Settings.swift` | `@Observable` settings, presets, JSON persistence, launch at login (`SMAppService`) |
| `Tracker.swift` | Window positions (`CGWindowList`), Dock and desktop icons (Accessibility) |
| `Simulation.swift` | Per-screen simulation: flakes, drift height maps, falling chunks, icicles, snowballs, cursor |
| `Snowman.swift` | The snowman's state machine and drawing |
| `Christmas.swift` | Tree, presents and the string of lights |
| `Mesh.swift` | Triangle helpers |
| `Renderer.swift` | Metal renderer with a triple-buffered ring of vertex buffers |
| `Overlay.swift` | Click-through overlay window per screen, display link, the snowman's click panel |
| `Snapshot.swift` | Debug mode that renders a fake scene to a PNG |
| `Promo.swift` | Renders the README screenshots: a drawn desktop with the real simulation on top, and the settings window |

Each drift is a height map with 4-point bins along the top edge of a surface. Flakes that cross the
surface deposit snow into a bin, and a simple slope rule spreads it to the neighbours, so drifts
round off at the ends. When a window moves or disappears, its height map turns into falling chunks
that can land on surfaces further down.

### Debug snapshot

```sh
swift build -c release
.build/release/iSnow --snapshot /tmp/isnow.png
```

This simulates a scene with fake windows, a Dock and icons and saves it as an image – handy for
checking rendering without screen recording permission. `ISNOW_TEMP=3` sets the temperature,
`ISNOW_SNOWMEN=2` the number of snowmen, `ISNOW_MAX=1` uses a single zoomed window and
`ISNOW_DRAG=14` drags a window for 14 frames and captures the snow falling off, and
`ISNOW_SECONDS=600` simulates ten minutes of snowfall first. `ISNOW_WIDGETS=1` adds a desktop widget (`=0`: one that snow falls through). `ISNOW_XMAS=0` (1, 2) turns on
Christmas mode with the given light style.

## Contributing

Issues and pull requests are welcome. Please keep the app lightweight: no third-party
dependencies, no extra assets, and nothing that runs when nothing is moving.
