# Oneko for iOS

Port of [Oneko](https://en.wikipedia.org/wiki/Neko_(software)) to iOS, based on
[oneko-mac](https://github.com/mdonoughe/neko-mac): a little pixel cat that lives on top of
everything on your screen, runs around, scratches, yawns and falls asleep.

This is a fork of [pixelomer](https://github.com/pixelomer)'s port. It teaches the cat to walk on
what's on the screen instead of just chasing your finger.

## What the cat does

**It stands on edges.** Twice a second the tweak looks at the screen and finds horizontal edges,
anywhere two colors meet along a line at least 40 pt long: the tops and bottoms of icons, widgets,
the dock, banners, buttons and app UI. Text is ignored. The cat walks to the closest edge and
stands on it.

**It moves when the screen changes.** If the edge under the cat disappears because you opened an
app, scrolled or anything else changed, it walks to the next closest one. When the screen has no
edges at all, it waits at the bottom until one appears.

**It comes when you tap.** Tap the home screen and the cat runs to the edge closest to your tap.
Swipes, long presses and multi-finger gestures are ignored.

**It scratches things.** Once it stops, before washing itself and dozing off, the cat may scratch:

- a wall right beside it, such as the side of an app icon it's standing in (it steps over to it);
- an edge right above its head, by reaching up;
- the edge it's standing on (about half the time).

All the original animations are kept: running in eight directions, washing, scratching itself,
yawning and sleeping.

## Settings

Settings → Oneko:

- **Bottom of Screen Only**: the cat stays at the bottom of the screen and just runs left or right
  to line up with your taps; the screen isn't scanned at all. Tap right next to a side and it
  climbs into the rounded corner to scratch the wall, then slides back down to the flat part
  before falling asleep.

Changes apply immediately, no respring needed.

## Requirements

- A jailbroken iPhone on iOS 15 or later (rootless), with PreferenceLoader.
- Developed and tested on an iPhone XR on iOS 17.0 (Dopamine).

## Notes

- The cat is hidden from screenshots and screen recordings, so it never mistakes itself for an
  edge.
- Taps inside apps go to the app, not SpringBoard, so the cat only hears taps on the home screen.
  It still moves between edges inside apps.
- Screen scanning runs off the main thread and takes about 20 ms. It slows to once a second while
  the cat sleeps and stops entirely while the phone is locked.

## Building

See [BUILDING.md](BUILDING.md).
