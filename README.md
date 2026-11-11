# iSnow ❄️

**It snows on your Mac.** iSnow is a tiny menu bar app that lets snow fall over everything on
your screen. Snow settles on top of your windows, the Dock, desktop icons and widgets, icicles grow
under windows you leave alone, and snowmen build themselves on the Dock.

It is not a wallpaper or a screensaver – it snows on top of whatever you are doing, and every click
goes straight through the snow.

![iSnow – snow drifts on windows, icicles and snowmen on the Dock](media/hero.png)

**Current version: 1.1** · macOS 14 Sonoma or later · Apple silicon and Intel · about 1 MB · [MIT License](LICENSE)

## Install

### Download (recommended)

1. Download **`iSnow-v1.1.dmg`** (and `iSnow-v1.1.dmg.sha256`) from the
   [Releases](https://github.com/filiphajduch420/iSnow/releases/latest) page.
2. Verify the download – both files in the same folder:
   ```sh
   shasum -a 256 -c iSnow-v1.1.dmg.sha256
   ```
   It should print `iSnow-v1.1.dmg: OK`. The SHA-256 of `iSnow-v1.1.dmg` is:
   <!-- sha256 -->
   ```
   db163439b94c9aaf175a82adee860e7cd840b3084235502ce54599d4770b4d43
   ```
   <!-- /sha256 -->
3. Open the DMG and drag **iSnow** onto **Applications**.
4. Open iSnow. Because it isn't signed with an Apple Developer ID certificate, macOS says it can't
   verify the app. Go to **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to the iSnow message, then confirm with **Open**. (Or run
   `xattr -dr com.apple.quarantine /Applications/iSnow.app` in Terminal.) The app is fully open
   source – you can read every line and build it yourself.
5. A snowflake appears in the menu bar and it starts snowing. For snow on the Dock and desktop
   icons, [allow Accessibility](#allowing-accessibility).

**Updating:** quit iSnow and drag the new version onto **Applications**, replacing the old one.
macOS treats every new download as a different app, so the Accessibility switch can still look on
but no longer work (the menu then says *Dock position is estimated*). Once per update, open
**System Settings → Privacy & Security → Accessibility**, select **iSnow**, remove it with **−** and
add it again with **+**.

### Build from source

You need Xcode or just the Xcode Command Line Tools (`xcode-select --install`, Swift 6) – no other
dependencies.

```sh
git clone https://github.com/filiphajduch420/iSnow.git
cd iSnow
./build.sh --install          # builds and signs iSnow.app, copies it to ~/Applications and launches it
```

| Command | What it does |
|---|---|
| `./build.sh` | Builds `build/iSnow.app` (universal). Signs it with your *Apple Development* certificate if you have one, so Accessibility survives rebuilds; otherwise ad hoc. |
| `./build.sh --install` | The same, then installs to `~/Applications` and launches it. |
| `./scripts/release.sh 1.1` | Builds the release DMG and its SHA-256 checksum into `dist/` and updates the version and checksum in this README. |
| `./scripts/screenshots.sh` | Renders the screenshots below into `media/` – no screen recording needed. |

With full Xcode both architectures are built in one go. With only the Command Line Tools the scripts
build Apple silicon and Intel separately and join them with `lipo` (set `ISNOW_SEPARATE_ARCHS=1` to
force that path).

## Screenshots

| | |
|---|---|
| ![Christmas mode](media/christmas.png) | ![A moved window drops its drift](media/slide.png) |
| **Christmas mode** – a tree, lights under the menu bar, Santa hats and Santa's sleigh | **Move a window** – the drift breaks off and crumbles into clumps |
| ![Hard frost](media/frost.png) | ![Settings – Snowfall](media/settings-snowfall.png) |
| **Hard frost (−20 °C)** – long icicles and frosted windows | **Settings** – presets, temperature, flakes |
| ![Settings – Drifts](media/settings-drifts.png) | ![Settings – Snowman](media/settings-snowman.png) |
| **Drifts** – where snow settles, unlimited hills, ice | **Snowmen** – how many, how big, snowball fights |

## Features

- **Snowfall** with parallax depth, gusty wind and four presets: Flurry, Normal, Blizzard, Snowstorm.
  Over the window you are working in the flakes calm down to a light dusting (optional).
- **Drifts** pile up on the visible top edges of windows, on the Dock, on desktop icons and widgets,
  and along the bottom of the screen. Hidden parts of a window stay snow-free, and snow never grows
  into a window in front of it. By default drifts keep growing into hills; deep snow slowly settles
  and compacts. A fixed maximum height can be set instead.
- **Move a window** and its drift breaks off as a slab that crumbles into clumps with a puff of
  powder, carried a little in the direction you dragged it. The clumps land on whatever is below and
  pile up again. A small nudge only shakes off the loose top layer. Close a window and all of it falls.
  Switching Spaces keeps the snow on your windows.
- **Shovel:** a quick swipe of the cursor brushes snow off, and holding **⌥ Option** brings out a
  shovel that pushes snow aside at any speed – on windows, the Dock and the bottom of the screen.
  The shovel is drawn next to the cursor (macOS doesn't let a background app replace the system
  cursor). The menu also has *Shovel Snow at the Bottom*.
- **Icicles** grow under windows that stay still for a while (and under the menu bar). Move the
  window and they snap off.
- **Snowmen** on the Dock (one to six): each rolls in three balls, stacks them, puts on a scarf
  and a carrot nose, waves, and throws snowballs at your windows and icons. Their eyes follow your
  cursor. After a few minutes a snowman falls apart and melts, and later a new one appears. Click a
  snowman to knock it apart – every third hit drops a level, and sometimes it fights back.
- **Drag a snowman** anywhere – onto a window, next to the Dock, wherever. It drops onto whatever is
  below, and if that window moves, it falls again.
- **Temperature** from −25 °C to +10 °C (or °F). Above zero the snow gets wet, melts quickly, and
  icicles and snowmen melt; above +4 °C it turns to sleet. Below zero snow only evaporates very
  slowly, icicles grow faster, longer (up to about 3× in hard frost) and thicker, and windows frost
  over from the corners – the colder, the more.
- **Stays out of your way:** snow at the bottom never covers the Dock's icons and hides behind
  windows, icicles never hang into the Dock, snowmen and the tree hide under menus and popovers, and
  a snowman that covers a window fades out and lets clicks through. Full-screen apps (also on Macs
  with a notch and in Split View) get no snow. Without Accessibility permission the Dock's position
  is estimated.
- **Christmas mode:** a decorated tree with twinkling lights, a glowing star and presents next to
  the Dock, a string of lights under the menu bar (colorful, warm white or chasing), Santa hats
  for the snowmen, and Santa's sleigh flying across the screen now and then (or right away with
  *Send Santa Now*).
- **Extras:** the cursor scatters flakes, sparkling flakes, custom snow color, frosted screen edges,
  and an option to keep the snow out of screenshots and screen sharing.

### Hide Effects and battery saver

- **Hide Effects** in the menu makes everything disappear for 15 minutes, 1 hour, until tomorrow or
  until you turn it back on – without quitting. The drifts come back exactly as they were.
- **Battery saver** (on by default): on battery iSnow runs at 30 fps and standard resolution, with
  fewer flakes and no sparkle. Turn it off on the *Other* tab.

## Settings

Open **Settings…** (⌘,) from the snowflake in the menu bar. If the snowflake is hidden behind the
notch, open iSnow again from Finder or Spotlight and the Settings window comes up.

| Tab | What you can change |
|---|---|
| Snowfall | Preset, temperature, density, max number of flakes, flake size, fall speed, wind, sparkle, calm snow over the active window, snow color |
| Drifts | Where snow settles (windows, Dock, icons, widgets, menu bar), unlimited hills or a max drift height on windows and at the bottom, pile-up speed, *Shake Off All Snow*, window frost, icicles and their length |
| Snowman | On/off, number of snowmen, size, break between snowmen, fade when covering a window, *Back to the Dock*, *Build Now*, snowball fight and how often it throws |
| Christmas | Christmas mode, tree and its size, lights under the menu bar, light style, lights while paused, Santa hats, Santa's sleigh, *Send Santa Now* |
| Other | Cursor interaction, frosted edges, full-screen pause, 30 / 60 / 120 fps, sharp Retina rendering, battery saver, launch at login, Fahrenheit, hide from screenshots and screen sharing, restore defaults |

The app is in English and Czech and follows your system language.

## Permissions and privacy

- **No permission is needed for snow on windows and desktop widgets.** Their positions come from
  `CGWindowList`. iSnow uses window positions and sizes only – no window titles, no content. No
  Screen Recording permission is used.
- **The exact position of the Dock and snow on desktop icons** need *Accessibility* permission (to
  read the Dock's and the desktop icons' positions). Without it, everything else still works and
  the Dock's width is estimated from the identifiers of the apps pinned to it (read from the Dock's
  preferences) – usually close, but it can be off by an icon or two.
- The snow shows up in screenshots and screen sharing unless you turn on *Hide the snow from
  screenshots and screen sharing* (Settings → Other).
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

**After an update or a rebuild** the switch can stay on but stop working, because an app without a
Developer ID signature looks like a new app to macOS. Select **iSnow** in the list, remove it with
**−**, and add it again (step 3). `build.sh` avoids this for your own builds by signing with your
*Apple Development* certificate if you have one (any free Apple ID signed in to Xcode gives you one).

The menu shows *Dock position is estimated* while iSnow doesn't have the permission.

## Performance

iSnow is built to stay out of the way:

- one instanced Metal draw call for all particles and one for all triangles (drifts, icicles,
  snowmen); shaders are compiled from source, so there are no textures or other assets;
- rendered at standard (1×) resolution by default – a quarter of the pixels of a 2× Retina frame
  for the GPU and the window compositor; *Sharp Retina rendering* is optional;
- `CADisplayLink` capped at 60 fps (configurable), 30 fps in Low Power Mode and on battery;
- rendering stops completely when nothing is moving, while the snow is paused or hidden, over
  full-screen apps and while the screen is asleep or locked;
- window positions are polled 5× per second (30× while a window is being dragged), Accessibility
  queries run off the main thread once per second.

<!-- perf -->
Measured on a 14" MacBook Pro on battery (battery saver on, 6,000-flake settings, Christmas mode):
about 6–8 % of one CPU core and 40–60 MB of memory. Version 1.0 (2× Retina, 60 fps) needed about
10–13 % and about 118 MB in the same situation. Nearly all of it is the system compositing a
full-screen layer – the simulation itself takes well under a millisecond per frame. The app bundle
is about 1 MB.
<!-- /perf -->

### Known limitations

- **Mission Control and Stage Manager:** while Mission Control is open (or windows move into the
  Stage Manager strip) drifts and icicles can float where the windows were before. They line up
  again when you close it.

## How it works

| File | Role |
|---|---|
| `App.swift` | SwiftUI `MenuBarExtra`, settings scene, app delegate that wires screens, polling and power events |
| `SettingsView.swift` | The settings window |
| `Settings.swift` | `@Observable` settings, presets, JSON persistence, launch at login (`SMAppService`) |
| `AppState.swift` | Runtime state shown in the menu: hidden effects, battery saver, full-screen pause |
| `Tracker.swift` | Window positions (`CGWindowList`), Dock and desktop icons (Accessibility) |
| `Simulation.swift` | Per-screen simulation: flakes, drift height maps, falling chunks, icicles, snowballs, cursor, Santa |
| `Snowman.swift` | The snowman's state machine and drawing |
| `Christmas.swift` | Tree, presents, the string of lights and Santa's sleigh |
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
`ISNOW_SNOWMEN=2` the number of snowmen, `ISNOW_MAX=1` uses a single zoomed window,
`ISNOW_DRAG=14` drags a window for 14 frames and captures the snow falling off, and
`ISNOW_SECONDS=600` simulates ten minutes of snowfall first. `ISNOW_WIDGETS=1` adds a desktop widget
(`=0`: one that snow falls through). `ISNOW_XMAS=0` (1, 2) turns on Christmas mode with the given
light style, and `ISNOW_SANTA=1` sends Santa's sleigh just before the picture is taken.

## Contributing

Issues and pull requests are welcome. Please keep the app lightweight: no third-party
dependencies, no extra assets, and nothing that runs when nothing is moving.

## License

[MIT](LICENSE) © 2026 Filip Hajduch
