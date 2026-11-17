# PedalBox

A small macOS menu bar app for Logitech racing wheels (G29 and other classic Logitech wheels).

macOS has no force feedback driver for these wheels, so games running through Wine (such as
BeamNG.drive with [BeamNG Launcher for Mac](https://github.com/j0di3x/beamng-mac-launcher)) can
steer with them but can't drive their motor. PedalBox fills that gap.

## Download

Get the latest **PedalBox .dmg** from [Releases](https://github.com/j0di3x/PedalBox/releases/latest)
and drag PedalBox onto Applications. The first time, right-click → Open (the app isn't notarized).
Runs on macOS 14 or newer, Apple silicon and Intel.

## Force feedback for BeamNG.drive (experimental)

- A small BeamNG mod (installed by BeamNG Launcher when you turn on **Wheel force feedback**)
  sends the game's steering force, the steering position and the car's speed to PedalBox over
  UDP on `127.0.0.1:47290`.
- PedalBox plays that force on the wheel and turns the wheel's own centering spring off, so you
  only feel the game.
- **Strength** (0–400 %, default 300 %): how strongly the game's road and tyre force is played.
  G29 owners usually run BeamNG at 200–450 %.
- **Return to centre**: a push back to centre after a turn, like power steering. Nothing while
  standing still, strongest at town speeds, fading as speed rises and the tyres take over.
- **Minimum force**: Logitech motors ignore weak pushes; this lifts small forces past that dead zone.
- **Invert** and **Test left / right** to check the direction.
- Safety: if the game stops sending for 0.3 s (pause, menu, crash), the force stops. Quitting
  PedalBox stops it too.

A once-a-second summary is written to `~/Library/Logs/PedalBox/ffb.log`.

## Wheel monitor

The main window also shows what macOS sees from the wheel (IOHID and GameController), read-only,
and can export a text report. Useful when a wheel isn't detected.

## Build

Open `PedalBox.xcodeproj` in Xcode (macOS 14 or later) and run the **PedalBox** scheme, or:

```sh
xcodebuild -project PedalBox.xcodeproj -scheme PedalBox -configuration Release build
```

Protocol facts and their sources are in [docs/RESEARCH.md](docs/RESEARCH.md).
