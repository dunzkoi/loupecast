# Changelog

## [0.9.0](https://github.com/dunzkoi/loupecast/compare/v0.8.0...v0.9.0) (2026-10-14)


### Features

* 3-second countdown before recording starts, cancel with Esc ([ab4a72a](https://github.com/dunzkoi/loupecast/commit/ab4a72a2cf184513ca02e284593b8a169cfb741f))
* a smooth, larger cursor drawn over the recording (Effects menu → Cursor Size, Smooth Cursor Movement) ([f3c55f6](https://github.com/dunzkoi/loupecast/commit/f3c55f68105319ce3acee6d31fb9a99eb74630c7))
* after the third finished export, a one-time line invites a GitHub star ([7683285](https://github.com/dunzkoi/loupecast/commit/768328515a7347920161729cc2aa4d9c82d330f4))
* captions from your microphone, recognized on this Mac, exported as SRT (Export menu → Captions) ([f89efe5](https://github.com/dunzkoi/loupecast/commit/f89efe5f947cd52836c241bad0604e39fdf8e870))
* click rings: a ring spreads from every click in the video (Effects menu → Show Clicks) ([96557de](https://github.com/dunzkoi/loupecast/commit/96557de8f907b04e040fdc33ed56cda6b7cd8844))
* export MP4 at 30 fps or under a size limit (10 MB or 25 MB) from the Export menu ([83c909a](https://github.com/dunzkoi/loupecast/commit/83c909a19a2117af2fcf84b56c627980a32f28f2))
* in Record Area, click a window to record exactly that window ([5fc8611](https://github.com/dunzkoi/loupecast/commit/5fc86111108742eae6aca24b48493f83f3a4f7ed))
* keyboard shortcuts popover in the editor (keyboard button or ?) ([18ae90e](https://github.com/dunzkoi/loupecast/commit/18ae90e5480e95c1167746c89de15ae78700e4c7))
* motion blur on zooms and pans (Effects menu → Motion Blur, on for new recordings) ([ed5fe76](https://github.com/dunzkoi/loupecast/commit/ed5fe761db80623a83c25859dd6d2d69214d8903))
* MP4 4K export (3840×2160, 2160×3840 or 2160×2160) for recordings with enough detail ([a720246](https://github.com/dunzkoi/loupecast/commit/a720246cd9662725104093f8bc081ca1f1489b78))
* new recordings start with the aspect ratio, background, fill and webcam corner picked last ([4a8cf81](https://github.com/dunzkoi/loupecast/commit/4a8cf81a7f9a11df6fff96cb81252fb49a23f057))
* pick your own image as the background ([2f2fa8e](https://github.com/dunzkoi/loupecast/commit/2f2fa8e45caa7f543b209836fa3c2fda8e1271fb))
* rename a recording in the editor; exports are named after it ([a863827](https://github.com/dunzkoi/loupecast/commit/a863827db7515d933141907f062664dd0480768a))
* show keyboard shortcuts (⌘ or ⌃ combinations) as a badge in the video, opt-in from the menu ([58e7623](https://github.com/dunzkoi/loupecast/commit/58e76237b1560725236116813b99485aae2f307b))
* zoom in on typing: stretches of typing zoom to where the text goes (on by default, needs Accessibility) ([b794bfd](https://github.com/dunzkoi/loupecast/commit/b794bfd471e0e7d154de3dfcf6c9883694291ce8))


### Bug Fixes

* a project file can't make the app read files outside its recording folder ([f3c55f6](https://github.com/dunzkoi/loupecast/commit/f3c55f68105319ce3acee6d31fb9a99eb74630c7))
* the camera menu's Size heading is in Korean on Korean systems ([17b46aa](https://github.com/dunzkoi/loupecast/commit/17b46aa73a3bcf0610dcc4df7dbdf26fe21fc951))


### Changes

* ⌘·⌃·⌥가 눌린 단축키만 기록해 영상 아래쪽에 키 배지로 보여 준다 ([58e7623](https://github.com/dunzkoi/loupecast/commit/58e76237b1560725236116813b99485aae2f307b))
* CI의 Swift 6.3에서 Render 테스트가 컴파일되게 고쳐 v0.8.0 릴리스 PR을 통과시킨다 ([18d3dea](https://github.com/dunzkoi/loupecast/commit/18d3dea40ddb4c96144662810d238d59fe340cd9))
* MP4 내보내기에 4K(2160p) 해상도 선택을 추가한다 ([a720246](https://github.com/dunzkoi/loupecast/commit/a720246cd9662725104093f8bc081ca1f1489b78))
* MP4 내보내기에서 30fps와 목표 파일 크기(10MB·25MB 이하)를 고를 수 있게 한다 ([83c909a](https://github.com/dunzkoi/loupecast/commit/83c909a19a2117af2fcf84b56c627980a32f28f2))
* README와 랜딩 페이지에 0.8.0 기능을 반영하고 비교표를 갱신한다 ([c54a5c5](https://github.com/dunzkoi/loupecast/commit/c54a5c549dfae761cd1d7e9f8e9a780fad9adfbc))
* release-as 0.8.0을 지우고 0.8.0 릴리스 노트의 한국어 fsd 줄을 영어 항목으로 정리한다 ([ec52ae2](https://github.com/dunzkoi/loupecast/commit/ec52ae261256dfa485da4e0f7bbddd7dfda6756c))
* UI 문자열마다 한국어 줄이 있는지 Core 테스트로 검사하고 빠진 'Size'를 채운다 ([17b46aa](https://github.com/dunzkoi/loupecast/commit/17b46aa73a3bcf0610dcc4df7dbdf26fe21fc951))
* 녹화 시작 전에 3초 카운트다운을 보여 주고 Esc로 취소할 수 있게 한다 ([ab4a72a](https://github.com/dunzkoi/loupecast/commit/ab4a72a2cf184513ca02e284593b8a169cfb741f))
* 녹화에서 시스템 커서를 빼고 합성 단계에서 부드럽고 크게 다시 그린다 ([f3c55f6](https://github.com/dunzkoi/loupecast/commit/f3c55f68105319ce3acee6d31fb9a99eb74630c7))
* 배경을 내 이미지(배경화면·브랜드 이미지)로 고를 수 있게 한다 ([2f2fa8e](https://github.com/dunzkoi/loupecast/commit/2f2fa8e45caa7f543b209836fa3c2fda8e1271fb))
* 세 번째 내보내기가 끝나면 한 번만 GitHub 별을 부탁하는 줄을 보여 준다 ([7683285](https://github.com/dunzkoi/loupecast/commit/768328515a7347920161729cc2aa4d9c82d330f4))
* 영역 지정 오버레이에서 창을 클릭하면 그 창 크기로 영역이 잡히게 한다 ([5fc8611](https://github.com/dunzkoi/loupecast/commit/5fc86111108742eae6aca24b48493f83f3a4f7ed))
* 자막 1단계: 마이크 음성을 기기 안에서 받아 적어 project.json과 SRT로 내보낸다 ([2841c81](https://github.com/dunzkoi/loupecast/commit/2841c812030ddc6c01a150acd74e1e6ba4cc0a75))
* 자막 1단계: 마이크 음성을 기기 안에서 받아 적어 project.json과 SRT로 내보낸다 ([f89efe5](https://github.com/dunzkoi/loupecast/commit/f89efe5f947cd52836c241bad0604e39fdf8e870))
* 줌·이동 중 카메라 속도에 비례하는 모션 블러를 넣는다 ([ed5fe76](https://github.com/dunzkoi/loupecast/commit/ed5fe761db80623a83c25859dd6d2d69214d8903))
* 직전에 고른 비율·배경·화면 채우기·카메라 위치를 새 녹화의 기본값으로 쓴다 ([4a8cf81](https://github.com/dunzkoi/loupecast/commit/4a8cf81a7f9a11df6fff96cb81252fb49a23f057))
* 클릭한 지점에 퍼지는 원을 그려 영상에서 클릭이 보이게 한다 ([96557de](https://github.com/dunzkoi/loupecast/commit/96557de8f907b04e040fdc33ed56cda6b7cd8844))
* 타이핑하는 구간을 감지해 입력 위치로 자동 줌을 만든다 ([b794bfd](https://github.com/dunzkoi/loupecast/commit/b794bfd471e0e7d154de3dfcf6c9883694291ce8))
* 편집기 단축키를 한눈에 보는 안내 팝오버를 추가한다 ([18ae90e](https://github.com/dunzkoi/loupecast/commit/18ae90e5480e95c1167746c89de15ae78700e4c7))
* 편집기에서 녹화 이름을 바꾸고 내보낸 파일 이름에 그 이름을 쓴다 ([a863827](https://github.com/dunzkoi/loupecast/commit/a863827db7515d933141907f062664dd0480768a))

## [0.8.0](https://github.com/dunzkoi/loupecast/compare/v0.7.0...v0.8.0) (2026-10-14)


### Features

* background presets in the editor: gradients, solid colors, or no padding ([c6b69c3](https://github.com/dunzkoi/loupecast/commit/c6b69c3aa561efbc730c73fb49ac2852e1abfb38))
* cancel button for a running export ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* change the selected zoom's magnification in the editor ([eb7d514](https://github.com/dunzkoi/loupecast/commit/eb7d514464daa2e91c77fac0e7a1f7c0199478fe))
* click the preview to hold the selected zoom on one spot ([f691ec7](https://github.com/dunzkoi/loupecast/commit/f691ec71f6062692801363dbb4c7d3c1041435be))
* copy an exported video to the clipboard, or drag it from the editor into another app ([cef0a0a](https://github.com/dunzkoi/loupecast/commit/cef0a0a2fa738aa947646b2ee4df3c0e24cf835d))
* English interface that follows the macOS language; Korean systems keep the same wording ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* English landing page, linked to the Korean one with hreflang ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* export in 9:16 (Shorts, Reels) or 1:1 as well as 16:9, picked in the editor toolbar ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* fill the frame in 9:16 and 1:1: the recording fills the canvas and the crop follows the cursor ([7385d28](https://github.com/dunzkoi/loupecast/commit/7385d28564323a22e7cfb477284a85e22e8df343))
* GIF export (silent, looping, 15 fps) for READMEs, issues and docs ([d30de7d](https://github.com/dunzkoi/loupecast/commit/d30de7d34e273fba284ff30c7a56ff505ce6074c))
* open recordings older than the five in the menu with Open Recording… ([9f79a6c](https://github.com/dunzkoi/loupecast/commit/9f79a6c0d4a938357c7293bef49ef2352e2b404a))
* pause and resume a recording; the paused stretch is cut automatically ([bb37621](https://github.com/dunzkoi/loupecast/commit/bb376213067bdc05863509bc3da27ecc0779730d))
* play selected clips at 2× or 4× speed; voices keep their pitch ([9527106](https://github.com/dunzkoi/loupecast/commit/9527106a1a0f2b716dba27a9e90b9259ec9dee3c))
* record only an area of the screen, picked by dragging ([c359b73](https://github.com/dunzkoi/loupecast/commit/c359b736fef95df9005804cd047e6fe60c2bc4a0))
* record your webcam as a circle in a corner of the video ([c35a8b1](https://github.com/dunzkoi/loupecast/commit/c35a8b1effc3459cf9bea682023e9774b3bd2648))
* separate volume and mute for computer audio and the microphone ([bea993f](https://github.com/dunzkoi/loupecast/commit/bea993fe39c456e1b73042d3d9ae482031ba4c3d))
* the Recent Recordings menu shows how much disk space the original recordings take ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))


### Bug Fixes

* a failed or cancelled export leaves no half-written MP4, and two exports in the same second no longer overwrite each other ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* autosave and opening the menu no longer stall the app on hour-long recordings ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* key presses are no longer recorded at all, so project files can't hold typed text ([8674ecc](https://github.com/dunzkoi/loupecast/commit/8674ecc547ea7bda4eba8d23e42690b9794c457e))
* quitting or a self-update no longer loses a recording or an export in progress: the recording is saved first, and quitting during an export asks before cancelling it ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* recordings survive a crash or force quit (all but the last few seconds), and folders left by failed recordings are cleaned up at launch ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))

## [0.7.0](https://github.com/dunzkoi/loupecast/compare/v0.6.0...v0.7.0) (2026-10-02)


### Features

* own start/stop chimes instead of system sounds ([#25](https://github.com/dunzkoi/loupecast/issues/25)) ([f72a45c](https://github.com/dunzkoi/loupecast/commit/f72a45cb8fbbae1705fcde2a1fda5767b95d1984))


### Bug Fixes

* visible manual updates that always relaunch ([#24](https://github.com/dunzkoi/loupecast/issues/24)) ([fb86baf](https://github.com/dunzkoi/loupecast/commit/fb86baf8296e20686e100070bd7d1606359aab41))

## [0.6.0](https://github.com/dunzkoi/loupecast/compare/v0.5.0...v0.6.0) (2026-10-02)


### Features

* play a sound when recording starts and stops ([#22](https://github.com/dunzkoi/loupecast/issues/22)) ([9bc6d62](https://github.com/dunzkoi/loupecast/commit/9bc6d62bb4fc0b6b47826e467a6c868ba1c011e3))
* ship a real app icon ([#21](https://github.com/dunzkoi/loupecast/issues/21)) ([75c1178](https://github.com/dunzkoi/loupecast/commit/75c1178953478d1d7d7f5ccd364a28b19aa17cb6))


### Bug Fixes

* one permission prompt, and reset a stale grant once ([#20](https://github.com/dunzkoi/loupecast/issues/20)) ([63fad27](https://github.com/dunzkoi/loupecast/commit/63fad27ddc0826223c78c5396190891c95b27ca9))

## [0.5.0](https://github.com/dunzkoi/loupecast/compare/v0.4.0...v0.5.0) (2026-10-02)


### Features

* show the version, a manual update check and GitHub in the menu ([#18](https://github.com/dunzkoi/loupecast/issues/18)) ([782c5f7](https://github.com/dunzkoi/loupecast/commit/782c5f7559a050c2c7a7eddee507e29635618c19))

## [0.4.0](https://github.com/dunzkoi/loupecast/compare/v0.3.1...v0.4.0) (2026-10-02)


### Features

* add sponsor links to the menu, README and site ([#11](https://github.com/dunzkoi/loupecast/issues/11)) ([cb2aa0f](https://github.com/dunzkoi/loupecast/commit/cb2aa0fdeaced16f02b599204acb6d6becc6d919))


### Bug Fixes

* pin the update signer and log failed installs ([#10](https://github.com/dunzkoi/loupecast/issues/10)) ([0b0c88f](https://github.com/dunzkoi/loupecast/commit/0b0c88f8fb6b02e22a3d973df9932f37b0827c51))

## [0.3.1](https://github.com/dunzkoi/loupecast/compare/v0.3.0...v0.3.1) (2026-10-02)


### Continuous Integration

* sign releases with a fixed self-signed identity ([#7](https://github.com/dunzkoi/loupecast/issues/7)) ([a7a2a0e](https://github.com/dunzkoi/loupecast/commit/a7a2a0e95b1d99e9a5508bbc135931f3725df955))

## [0.3.0](https://github.com/dunzkoi/loupecast/compare/v0.2.0...v0.3.0) (2026-10-02)


### Features

* self-update from GitHub releases ([#5](https://github.com/dunzkoi/loupecast/issues/5)) ([8db13d6](https://github.com/dunzkoi/loupecast/commit/8db13d63daedad2ff77e90fe774f3bf58de3579a))

## [0.2.0](https://github.com/dunzkoi/loupecast/compare/v0.1.0...v0.2.0) (2026-10-02)


### Features

* add landing page ([#2](https://github.com/dunzkoi/loupecast/issues/2)) ([3ce9fc0](https://github.com/dunzkoi/loupecast/commit/3ce9fc060077b2842226b210ed075edde96443cb))
* open folders and trash recordings from the menu ([#4](https://github.com/dunzkoi/loupecast/issues/4)) ([af4caaa](https://github.com/dunzkoi/loupecast/commit/af4caaa675e085a58b003788c8c76a540e9e1914))

## 0.1.0 (2026-10-01)


### Features

* initial release of Loupecast screen recorder ([4e52e7e](https://github.com/dunzkoi/loupecast/commit/4e52e7ec8a1445ccbcb41c48076c2cd87cef943e))
