<h1 align="center">Loupecast</h1>
<p align="center">A free, open-source macOS screen recorder that zooms in where you click, lets you cut the boring parts, and exports a polished 1080p60 MP4.</p>
<p align="center">
  <a href="https://dunzkoi.github.io/loupecast/">Website</a> ·
  <a href="https://github.com/dunzkoi/loupecast/releases/latest">Download</a> ·
  <a href="README.ko.md">한국어</a>
</p>

## Install

With Homebrew:

```sh
brew install --cask dunzkoi/tap/loupecast
```

Or download `Loupecast.zip` from the [latest release](https://github.com/dunzkoi/loupecast/releases/latest), unzip it, and move `Loupecast.app` to `/Applications`.

> Loupecast is not notarized yet, so macOS may say the app "is damaged" or "can't be opened". Run this once:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Loupecast.app
> ```

Requires macOS 15 or later on Apple Silicon. The interface is currently in Korean.

## Usage

1. Open Loupecast. It lives in the menu bar (◉), not the Dock.
2. Press **⌘⇧2** (or choose 녹화 시작 from the menu) to start, and again to stop.
3. The first time, allow **Screen & System Audio Recording** in System Settings, then quit and reopen Loupecast.
4. When you stop, the editor opens:
   - Clicks become automatic zooms. Select a zoom and press Delete to remove it, or use 줌 추가 to add one.
   - **D** splits at the playhead, click a clip and press **Delete** to cut it, **⌘Z** to undo.
   - **Space** plays, **← →** step one frame, **I / O** set the clip start and end.
5. Press 내보내기 to export. Files go to `~/Movies`.

Menu toggles: 마이크 녹음 (microphone, off by default), 컴퓨터 소리 녹음 (system audio, on), 영상 속 메뉴 막대 숨기기 (crop the menu bar out of the video, on).

## Privacy

Loupecast makes no network requests. Recordings stay in `~/Library/Application Support/Loupecast/Recordings` and exports in `~/Movies`. Nothing is uploaded, and there is no analytics or telemetry.

## Build from source

```sh
git clone https://github.com/dunzkoi/loupecast.git
cd loupecast
swift test
./build.sh          # → dist/Loupecast.app
```

Needs Xcode 16 or later. No third-party dependencies.

## FAQ

**Why do I have to allow screen recording again after an update?** Release builds are signed ad hoc until the project gets an Apple Developer ID, and macOS ties the permission to the exact build. Remove the old Loupecast entry in System Settings and enable it again.

**The menu bar icon doesn't show up.** macOS may hide new menu bar items when the bar is full. Check System Settings → Menu Bar, or just press ⌘⇧2.

## Contributing

Bug reports and PRs are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; every PR gets CI and an automated review.

## License

[MIT](LICENSE) © 2026 Dunz Koi
