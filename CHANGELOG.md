# Changelog

## [0.8.0](https://github.com/dunzkoi/loupecast/compare/v0.7.0...v0.8.0) (2026-10-14)


### Features

* cancel button for a running export ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* English interface that follows the macOS language; Korean systems keep the same wording ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* English landing page, linked to the Korean one with hreflang ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* export in 9:16 (Shorts, Reels) or 1:1 as well as 16:9, picked in the editor toolbar ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* the Recent Recordings menu shows how much disk space the original recordings take ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))


### Bug Fixes

* a failed or cancelled export leaves no half-written MP4, and two exports in the same second no longer overwrite each other ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* autosave and opening the menu no longer stall the app on hour-long recordings ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* quitting or a self-update no longer loses a recording or an export in progress: the recording is saved first, and quitting during an export asks before cancelling it ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* recordings survive a crash or force quit (all but the last few seconds), and folders left by failed recordings are cleaned up at launch ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))


### Changes

* 9:16·1:1 비율에서 녹화 화면이 캔버스를 채우고 커서를 따라 잘리게 한다 ([7385d28](https://github.com/dunzkoi/loupecast/commit/7385d28564323a22e7cfb477284a85e22e8df343))
* CHANGELOG 갱신 ([194f5ce](https://github.com/dunzkoi/loupecast/commit/194f5cef8dc3aeefee2de0aeaaabb01fa8ce2a5a))
* GitHub와 문서에 바로 넣을 수 있는 GIF 내보내기를 추가한다 ([d30de7d](https://github.com/dunzkoi/loupecast/commit/d30de7d34e273fba284ff30c7a56ff505ce6074c))
* Loupecast로 만든 실제 데모 영상을 랜딩 페이지와 README에 넣는다 ([3a0ddd0](https://github.com/dunzkoi/loupecast/commit/3a0ddd09f89aa13291f5e14c7f42eeb440ea74b6))
* Render 테스트의 합성 영상 작성 교착을 고치고 테스트에 시간 제한을 건다 ([170ef5a](https://github.com/dunzkoi/loupecast/commit/170ef5a9f13f6538af0230d5e84d84075b3cb7ae))
* 긴 녹화에서 자동 저장과 메뉴 열기가 메인 스레드를 막지 않게 한다 ([ef35bb0](https://github.com/dunzkoi/loupecast/commit/ef35bb036a88ec36451777cdbd20e8ec44ff1e57))
* 내보내기 취소 버튼을 넣고 실패·취소 시 남는 반쪽 파일을 지운다 ([b05efe7](https://github.com/dunzkoi/loupecast/commit/b05efe7e8db57bcd8529efd22482e982cda61f3e))
* 내보내기 취소 버튼을 넣고 실패·취소 시 남는 반쪽 파일을 지운다 ([6fa7324](https://github.com/dunzkoi/loupecast/commit/6fa73242a090cb259d3e2afcaa62f4b34313a436))
* 내보내기 취소 버튼을 넣고 실패·취소 시 남는 반쪽 파일을 지운다 ([eeafacc](https://github.com/dunzkoi/loupecast/commit/eeafacc49d40228bcab809ac5c13782b9b2e258d))
* 내보낸 영상을 클립보드에 복사하고 편집기에서 바로 끌어다 놓을 수 있게 한다 ([cef0a0a](https://github.com/dunzkoi/loupecast/commit/cef0a0a2fa738aa947646b2ee4df3c0e24cf835d))
* 녹화·내보내기 중 앱 종료나 자동 업데이트로 결과물이 날아가지 않게 막는다 ([a10cc1d](https://github.com/dunzkoi/loupecast/commit/a10cc1dc54dba75b1ebbc7bdd3a3b66709c6e662))
* 녹화를 일시정지했다가 이어서 녹화하고 멈춘 구간은 자동으로 잘라 낸다 ([bb37621](https://github.com/dunzkoi/loupecast/commit/bb376213067bdc05863509bc3da27ecc0779730d))
* 녹화에 웹캠 화면을 원형으로 겹쳐 넣는 기능을 추가한다 ([c35a8b1](https://github.com/dunzkoi/loupecast/commit/c35a8b1effc3459cf9bea682023e9774b3bd2648))
* 랜딩 사이트에 영어 페이지를 추가하고 hreflang으로 두 언어를 잇는다 ([6a79173](https://github.com/dunzkoi/loupecast/commit/6a79173079de871fb23b6f9bc9ffe27f706f0c92))
* 레포에 CLAUDE.md를 추가하고 CONTRIBUTING의 없는 lint 문구를 바로잡는다 ([d8ae052](https://github.com/dunzkoi/loupecast/commit/d8ae052030718d99905bcb7d0cd25b6e37dd9889))
* 멈춘 릴리스 경로를 살려 main의 새 기능이 v0.8.0으로 나가게 한다 ([6a68414](https://github.com/dunzkoi/loupecast/commit/6a68414edde60003d53d1f97730459c78ca973ed))
* 배경 스타일 프리셋을 편집기에서 고를 수 있게 한다 ([c6b69c3](https://github.com/dunzkoi/loupecast/commit/c6b69c3aa561efbc730c73fb49ac2852e1abfb38))
* 선택한 줌의 초점을 미리보기에서 찍어 고정할 수 있게 한다 ([f691ec7](https://github.com/dunzkoi/loupecast/commit/f691ec71f6062692801363dbb4c7d3c1041435be))
* 선택한 줌의 확대 배율을 편집기에서 바꿀 수 있게 한다 ([eb7d514](https://github.com/dunzkoi/loupecast/commit/eb7d514464daa2e91c77fac0e7a1f7c0199478fe))
* 선택한 클립을 2배·4배로 빠르게 재생하는 구간 가속을 추가한다 ([9527106](https://github.com/dunzkoi/loupecast/commit/9527106a1a0f2b716dba27a9e90b9259ec9dee3c))
* 세로 9:16과 정사각 1:1 내보내기 비율을 고를 수 있게 한다 ([e25e7d0](https://github.com/dunzkoi/loupecast/commit/e25e7d071554498fe56a198f7b7a78366fdb5a7d))
* 세로 9:16과 정사각 1:1 내보내기 비율을 고를 수 있게 한다 ([768da44](https://github.com/dunzkoi/loupecast/commit/768da446719c7d248e518a7977d556c00f6b16f5))
* 쓰지 않는 전역 키 입력 기록을 없애 키로거처럼 남는 데이터를 막는다 ([8674ecc](https://github.com/dunzkoi/loupecast/commit/8674ecc547ea7bda4eba8d23e42690b9794c457e))
* 앱 UI를 영어로도 제공해 해외 사용자가 쓸 수 있게 한다 ([4a95043](https://github.com/dunzkoi/loupecast/commit/4a95043336e1a372f717540ea3087e6f675a6f3a))
* 업데이트마다 화면 녹화 권한을 다시 켜야 한다는 낡은 FAQ를 바로잡는다 ([7064d75](https://github.com/dunzkoi/loupecast/commit/7064d7566228edd6ebeb6837f614706b389178ca))
* 최근 5개보다 오래된 녹화도 메뉴에서 열 수 있게 한다 ([9f79a6c](https://github.com/dunzkoi/loupecast/commit/9f79a6c0d4a938357c7293bef49ef2352e2b404a))
* 최근 녹화 메뉴에 녹화 원본이 차지하는 디스크 용량을 보여 준다 ([6bb7afe](https://github.com/dunzkoi/loupecast/commit/6bb7afe81282196cd26d041d6dce32bd3c38e093))
* 최근 녹화 메뉴에 녹화 원본이 차지하는 디스크 용량을 보여 준다 ([98d246e](https://github.com/dunzkoi/loupecast/commit/98d246ea17b6f6b1d2d9fd759a6da2e7bc21b4b3))
* 충돌·강제 종료 뒤에도 녹화를 살리고 실패한 녹화 폴더를 정리한다 ([1453f62](https://github.com/dunzkoi/loupecast/commit/1453f629e836be55c6ff82c8c68e642827edd148))
* 충돌·강제 종료 뒤에도 녹화를 살리고 실패한 녹화 폴더를 정리한다 ([69eac34](https://github.com/dunzkoi/loupecast/commit/69eac34b7ce2069b633ebd0f1db352bbd84cd7d0))
* 편집기에서 컴퓨터 소리와 마이크 음량을 따로 조절하고 끌 수 있게 한다 ([bea993f](https://github.com/dunzkoi/loupecast/commit/bea993fe39c456e1b73042d3d9ae482031ba4c3d))
* 화면 전체 대신 드래그로 고른 영역만 녹화할 수 있게 한다 ([c359b73](https://github.com/dunzkoi/loupecast/commit/c359b736fef95df9005804cd047e6fe60c2bc4a0))

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
