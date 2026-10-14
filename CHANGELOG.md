# Changelog

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
