# CLAUDE.md — Oneko-iOS (fork)

Fork of pixelomer's Oneko-iOS (`origin` = github.com/Shmankus/Oneko-iOS, a submodule of the
iphoneTweaks repo). SpringBoard tweak: a 32x32 neko in its own top-level window. The fork makes
the cat walk to and stand on horizontal color edges instead of chasing touches.
Package id stays `com.pixelomer.oneko`; 4-space indentation like upstream.

## Status

- 1.5.0 installed on the XR: Settings → Oneko → Random Edges (`RandomEdges`): a tap on the
  cat (its frame + 8 pt) and a lost edge pick a random edge (`randomFootAwayFrom:`, at least 32 pt
  from the cat) instead of the nearest; other taps are ignored (`handleTouches`). In bottom mode a cat tap picks a random x
  (`randomBottomX`): 1 in 3 a side, so it climbs the corner and scratches the wall; other
  picks stay on the flat floor (a random x on a slope looked like a failed climb, 2026-10-08). 1.4.0: wall scratching in edge mode (user-verified at icon sides). 1.3.0:
  scratching animations, corner slopes and slide-to-sleep in bottom
  mode (all user-verified 2026-10-08). 1.2.0 added Settings → Oneko → Bottom of Screen Only.
  1.1.0 (iOS 17.0), 2026-10-08. Edge detection verified with debug dumps on
  the home screen and App Library; the cat stands on widget/icon tops and follows taps (user-confirmed). Rotation (landscape apps)
  is untested.

## Files

- `Oneko.m` — upstream cat state machine (MRC!). Walks toward `mouseLocation`, which is where the
  frame's top-center ends up. Fork changes: y flip uses the superview height; an idle cat slides
  the last < 6 pt onto its target (upstream wouldn't move); `isAsleep`; `scratchDirection` picks
  the togi animation after stopping (upstream had it commented out, so togi never played);
  `restLocation`: the yawning (akubi) cat slides there at 4 pt/tick before sleeping (setting
  `mouseLocation` cancels it); the d_togi sprite is drawn 10 pt lower (user-tuned: it draws the
  cat higher than the other sprites, so it seemed to jump up); a sleeping cat stirs about once
  per 2400 ticks (~5 min, `STIR_CHANCE`): akubi → jare, kaki or d_togi in place → sleep (`stirTo`). `canScratchDown` (set in `setTargetFoot`) is NO
  in bottom mode and on the screen-bottom fallback, so it never scratches down at the bezel there.
- `EdgeMap.m` (ARC, `-O2`) — screen capture + edge finding, one pixel per point of the view.
- `Tweak.xm` — window, timer (8 Hz), tap detection (`handleTouches`), scan scheduling and
  targeting (`applyEdges`).
- `layout/Library/PreferenceLoader/Preferences/Oneko.plist` (+ icon PNGs drawn from `mati2.gif`) —
  plist-only PreferenceLoader page (no bundle): switches `BottomOnly`
  and `RandomEdges` in domain `com.pixelomer.oneko`, posts `com.pixelomer.oneko/changed`; `Tweak.xm`
  `loadPrefs`/`followBottom`. Dopamine redirects
  the domain to `/var/jb/var/mobile/Library/Preferences/com.pixelomer.oneko.plist`; SpringBoard reads
  it with `CFPreferencesAppSynchronize` + `CFPreferencesCopyAppValue` (verified 2026-10-08).
- `bundle.sh` → `resources.m` (generated, gitignored): the GIF sprites as a C array.

## How it works

- No scans while locked or for 8 ticks (1 s) after unlocking (`UNLOCK_SCAN_DELAY`): the unlock
  animation made the cat's edge vanish and woke it.
- Every 4 ticks (0.5 s; 8 while asleep) a background queue renders the display with
  `CARenderServerRenderDisplay(0, "LCD", surface, 0, 0)` into our own 828x1792 BGRA IOSurface and
  samples every other pixel (via precomputed row/column offsets, so 90° rotations are free).
- Edge at row y: rows y-2 and y+1 differ by >= 48 (sum of RGB diffs) and each side is flat
  (y-2 vs y-4, y+1 vs y+3 differ < 32), in a run of >= 40 pt with gaps <= 2 px. The flatness test
  is what rejects text. The bottom of the screen counts only while no edge exists (it used to be a
  permanent edge: once the cat landed there, e.g. after an app transition, it never left).
- Scratching: edge mode → left/right (l/r_togi) if `wallFromX:` finds a vertical edge within
  `WALL_REACH` (12 pt) of the frame's side, over >= 80% of the paw rows (frame top + 3...12), with a
  flat far side only (icon artwork on the cat's side is fine); the target shifts so the paws touch
  it if the feet stay on the edge. Else up (u_togi) if an edge is within 4 pt of where the paws
  reach (foot + 3 - 32), else down (d_togi) on a random half of new targets. Bottom mode → left/right
  wall (l/r_togi) when the tap is closer to a side than the cat's center can get (16 pt).
- Bottom mode floor follows the display's rounded corners (`-[UIScreen _displayCornerRadius]`,
  41.5 pt on the XR) under the feet (±10 pt from center), so the cat climbs into the corner instead
  of being clipped; on a slope it gets a rest location where the floor turns flat. It walks along
  the curve (`followFloor`: each tick `mouseLocation` is one 13 pt stride further along the floor,
  the final target once that close) instead of straight through the air to the top.
- Target: a tap → edge nearest the tap; else keep the target while an edge is within 3 pt of it;
  else nearest edge to the cat's feet. With Random Edges, a tap on the cat and a lost edge pick a random edge entry
  (uniform over stored edges, so an edge found on two adjacent rows counts twice) and a random x on it. Feet are 3 pt above the frame bottom (sprite padding).

## Pitfalls (2026-10-08, XR)

- In `-[UITouchesEvent _setHIDEvent:]` (upstream's touch hook), `touch.phase` is always 2
  (stationary), so taps and swipes can't be told apart there. Taps are detected in
  `-[SpringBoard sendEvent:]` instead, where phases are right: began → ended within 0.35 s, moving
  < 10 pt, one finger. SpringBoard sees each event twice with different `UITouch` objects, so
  don't match the ending touch to the beginning one. Taps inside apps don't reach SpringBoard.
- The cat must be hidden from the capture, or it breaks the edge under it and the target jitters:
  `neko.layer.disableUpdateMask = 0x12` works (also hides it from user screenshots/recordings).
- `_UICreateScreenUIImage` works (also off the main thread) but returns a 16-bit RGBX image whose
  `CGDataProviderCopyData` takes ~75 ms; `CGDataProviderRetainBytePtr` returns NULL for it. Kept
  only as a fallback. Calling it on the main thread blocked SpringBoard ~30 ms per scan.
- Render-server path: ~12 ms waiting on the render server + ~7 ms sampling + ~3 ms scanning.
  Sampling took 48 ms at Theos' debug `-O0` with a per-pixel affine transform.
- `CARenderServerRenderDisplayExcludeList` (in the 16.5 SDK) is gone on iOS 17.
- Debug: `touch /var/tmp/oneko-dump` (chmod 666) makes each scan write `/var/tmp/oneko-edges.png`
  (the sampled screen with edges in red); delete it when done. Logs: `syslog show -p SpringBoard -g "[Oneko]"`.
