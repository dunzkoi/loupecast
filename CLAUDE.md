# Loupecast

Free, open-source macOS menu-bar screen recorder: clicks become automatic zooms, the editor cuts and trims, and
export writes a 60 fps H.264 MP4 at 16:9 (1920×1080), 9:16 (1080×1920) or 1:1 (1080×1080). Swift 6, SwiftUI,
ScreenCaptureKit, AVFoundation; macOS 15+, Apple Silicon. Public repo `dunzkoi/loupecast`: release-please releases,
self-update from GitHub Releases, Homebrew cask, GitHub Pages site. The original spec is `PROMPT.md` (gitignored,
only in the maintainer's checkout); the rules that matter are below.

## Layout

- `Sources/LoupecastCore`: pure logic, Foundation only (no AppKit/AVFoundation). `Project` (project.json, cut list,
  aspect), `AutoZoom` and `CameraPath` (camera(t)), `InputLog`, `Version`.
- `Sources/LoupecastRender`: `Composer` (composition from the kept clips), `LoupecastCompositor` (custom
  `AVVideoCompositing` with Core Image), `Exporter` (reader/writer pumps, H.264 + one stereo AAC track),
  `GIFExporter` (the same composition at 15 fps, long side 960 px, silent and looping).
- `Sources/Loupecast`: the app. `main.swift` (AppDelegate, menu, quit handling, `Library`: recent recordings,
  crash recovery, disk usage, `HotKey`), `Recorder` (SCStream → AVAssetWriter), `CameraRecorder` (webcam →
  `camera.mov`), `AreaPicker` (the 영역 지정 녹화 overlay), `Editor` (EditorModel and views), `Updater` (self-update), `Debug.swift` (verification hooks, DEBUG
  builds only).
- `Resources`: app icon, chimes, `en.lproj`/`ko.lproj`. `build.sh` copies them into `Contents/Resources`.
- `site/`: landing pages, Korean at `/loupecast/`, English at `/loupecast/en/`, shared `site.css`/`site.js`;
  deployed by `pages.yml` on pushes to `main` that touch `site/`. `scripts/make-demo.sh` rebuilds the demo
  (`site/demo.mp4`, `site/demo-poster.jpg`, `.github/demo.gif` for the READMEs): `scripts/make-demo.swift` draws a
  to-do app screen with its clicks, zooms and cut, and a debug build exports it (`LOUPECAST_EXPORT_TO`).
- `Tests/LoupecastCoreTests` (fast) and `Tests/LoupecastRenderTests` (real exports of a synthetic movie).

## Build and verify

```sh
swift build --build-tests && swift test   # Core ~0.1 s; Render 10-40 s, each export test fails after 120 s
./build.sh                                # dist/Loupecast.app, release; signs with "Loupe Local Dev" if present
```

- CI (`ci.yml`) builds, runs Core tests, runs Render tests (they skip themselves under `GITHUB_ACTIONS`: GitHub's
  macOS VMs have no video hardware), runs `build.sh` and checks the binary for developer paths. Anything touching
  render, export or the camera path needs `swift test --filter LoupecastRenderTests` locally.
- `ClipTests.testRealV1FilesLoad` skips unless `LOUPECAST_V1_DIR` points at copies of version-1 project files.
- Verification hooks: environment variables `LOUPECAST_*`, all listed at the top of `Sources/Loupecast/Debug.swift`,
  on the debug binary `$(swift build --show-bin-path)/Loupecast`. Every run sets both `LOUPECAST_RECORDINGS_DIR` and
  `LOUPECAST_EXPORT_DIR` to absolute scratch paths (missing folders are fine): otherwise launch-time recovery and
  trash actions work on the real `~/Library/Application Support/Loupecast/Recordings` and exports land in
  `~/Movies`. With the override, trashing moves to `<dir>-trash` instead of the user's Trash. Hooks quit on their
  own; wrap them in `timeout 60` (`brew install coreutils`, not in stock macOS) to be safe. A recording to open is
  a folder with `recording.mov` and `project.json`; the Render tests leave one in `.build/loupecast-test/`
  (`synthetic.mov` + `project.json`, rename the movie to `recording.mov` in a copy).
  - Menu text: `LOUPECAST_STATUS=<png>` prints the idle and recording menus.
  - Editor: `LOUPECAST_OPEN=<dir> LOUPECAST_SNAPSHOT=<png>` saves the window with the preview frame;
    `LOUPECAST_EDITOR_TEST=<dir>` drives drags, clicks and keys; `LOUPECAST_EXPORT=cancel|twice`,
    `LOUPECAST_QUIT_TEST=<dir>`, `LOUPECAST_USAGE_TEST=1` and `LOUPECAST_PERF=<dir>` cover export, quit, disk
    usage and performance.
- Localized UI needs a bundle: copy `dist/Loupecast.app`, put the debug binary in `Contents/MacOS/Loupecast`, change
  `CFBundleIdentifier`, `codesign --force --sign -`, then run it with `-AppleLanguages '(en)'` or `'(ko)'`.
- Performance: `LOUPECAST_PERF=<recording>` prints per-edit main-thread stalls; build with
  `swift build -c release -Xswiftc -DDEBUG` for realistic numbers.
- Needs grants this process may not have: `LOUPECAST_SELFTEST` needs Screen Recording (and Accessibility for its
  CGEvent clicks); the key checks in `LOUPECAST_EDITOR_TEST` need Accessibility and fail on any build without it.

## Invariants

- No third-party dependencies. No SwiftPM resources or `Bundle.module`: assets are copied by `build.sh` and found
  through `Bundle.main` (`NSSound(named:)`, `Localizable.strings`).
- Preview and export use the same `Composer` video composition and `CameraPath`; `camera(t)` is a pure function.
  Never bake zoom into an intermediate render. `[ClipRange].recordingTime/compositionTime` is the one mapping
  between composition and recording time (preview, timeline, export); a clip's `speed` (1, 2, 4) divides its
  composition length (`playLength`), and `Composer.make` squeezes it with `scaleTimeRange` (pitch kept).
- project.json stores recording-relative seconds only, no host time or wall clock. New fields decode with
  `decodeIfPresent` and a default, so older files load and older apps ignore them; bump
  `Project.currentVersion` only for incompatible changes (2 = cut list).
- The update signing requirement (`Updater.requirement`, certificate leaf hash) changes only together with the
  "Guard against an unstable signature" step in `release-please.yml` and the `MACOS_CERT_*` secrets.
- UI text is English in the source (`String(localized:)`, SwiftUI `LocalizedStringKey`) with Korean in
  `Resources/ko.lproj/Localizable.strings`; keys are the English text with `%@`/`%lld` for interpolations. New UI
  text needs its Korean line; Korean users must keep seeing the same wording.
- Never call `AVAssetReader.cancelReading()` while a pump may be inside `copyNextSampleBuffer()` (it crashes).
  Cancel through `Pumps.stop()`; the reader is cancelled after both pumps return.
- Quitting from inside a Swift task goes through `Updater.quit()`: a `.terminateLater` quit spins a nested run loop
  that doesn't drain the main queue while a main-queue job is on the stack.
- Autosave encodes off the main thread on `EditorModel.saves` (one serial queue, saves land in order);
  `close()` saves a pending edit and waits for the queue.
- PR titles follow Conventional Commits (`pr-title.yml`); squash merges; release-please owns `CHANGELOG.md`
  sections for releases and `version.txt`.
- Commits that land on `main` directly need a Conventional title too, or release-please skips them and no release
  goes out. `fsd:` runner commits (title fixed by the runner) count through the `fsd` → "Changes" entry in
  `release-please-config.json`; an English `feat: …`/`fix: …` line after a blank line in the body adds a proper
  Features/Bug Fixes entry. Without that line the release notes carry the Korean `fsd:` title under "Changes"
  (0.8.0 shipped 32 such lines, rewritten in English by hand afterwards). Never hand-write an Unreleased block in
  `CHANGELOG.md`: release-please inserts each release below it, so it stays on top forever.

## Decisions

- Recorder writes a movie fragment every 5 s and an event-free `recovery.json` at start; at launch, folders
  without project.json become "… (Recovered)" projects or go to the Trash (folders touched in the last minute are
  left alone, another instance may be recording).
- An export keeps running after its editor closes (`EditorModel.exports`); the updater waits for it, quitting
  asks first and deletes the partial file if cancelled. Export names never reuse an existing or running file.
- The synthetic test movie drives each writer input with `requestMediaDataWhenReady`; polling one input while
  pushing the others deadlocked the writer.
- The menu caches recording names by project.json modification date and the Recordings size by folder dates.
- Frame look scales with the canvas's short side (1080 px), so every aspect ratio gets the same corners and shadow.
- The webcam is its own file (`camera.mov`); `Project.camera.offset` is the recording time of its first frame (both
  stamped on the host clock), and `Composer` inserts it as a second video track shifted by that offset, so cuts,
  speed and export apply to it like the screen. The circle is drawn after the zoom, so it never moves.
- The site's `x-default` hreflang is the English page; README's Website link points there.

## Open

- Releases use a fixed self-signed identity (since 0.3.1) and aren't notarized (README's `xattr` step).
- Recording-path changes (start-failure cleanup, finishing a recording on quit, pause/resume dropping samples, area
  recording's `sourceRect`) were
  verified only by reading the code and with synthetic movies here; they need a machine with the Screen Recording
  grant. The webcam capture (`CameraRecorder`) also needs the Camera grant; only its compositing is tested. A crash while paused recovers without the pause cut (recovery.json has no pauses).
- Hour-long projects: each edit rebuilds the whole camera path (~5 ms) and redraws the timeline; 화면 채우기 adds a
  cursor-following track over the whole edit (tens of ms an hour).
- The demo's screen is drawn by a script, not recorded (no Screen Recording grant here, and a real desktop would be
  public); swap in a real recording run through the same export when there is one.
- The GIF export writes every frame whole (ImageIO): ~0.6 MB a second at 960 px, so GitHub's 10 MB image limit fits
  about 15 s. Frame differencing or a smaller size would stretch that.
