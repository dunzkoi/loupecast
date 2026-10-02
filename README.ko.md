<h1 align="center">Loupecast</h1>
<p align="center">클릭한 곳을 자동으로 확대하고, 필요 없는 구간을 잘라 1080p60 MP4로 내보내는 무료 오픈소스 macOS 화면 녹화 앱입니다.</p>
<p align="center">
  <a href="https://dunzkoi.github.io/loupecast/">웹사이트</a> ·
  <a href="https://github.com/dunzkoi/loupecast/releases/latest">다운로드</a> ·
  <a href="README.md">English</a>
</p>

## 설치

Homebrew로 설치합니다.

```sh
brew install --cask dunzkoi/tap/loupecast
```

또는 [최신 릴리스](https://github.com/dunzkoi/loupecast/releases/latest)에서 `Loupecast.zip`을 받아 압축을 풀고 `Loupecast.app`을 `응용 프로그램` 폴더로 옮깁니다.

> 아직 Apple 공증을 받지 않아서 "손상된 앱" 또는 "열 수 없음" 경고가 뜰 수 있습니다. 처음 한 번만 아래 명령을 실행하세요.
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Loupecast.app
> ```

Apple Silicon Mac, macOS 15 이상에서 동작합니다.

## 사용법

1. Loupecast를 엽니다. Dock이 아니라 메뉴바(◉)에 나타납니다.
2. **⌘⇧2**를 누르거나 메뉴에서 "녹화 시작"을 누릅니다. 다시 누르면 녹화가 멈춥니다.
3. 처음에는 시스템 설정에서 **화면 및 시스템 오디오 녹음** 권한을 켜고, Loupecast를 종료했다가 다시 엽니다.
4. 녹화를 멈추면 편집 창이 열립니다.
   - 클릭한 지점이 자동 줌이 됩니다. 줌을 선택하고 Delete로 지우거나, "줌 추가"로 넣을 수 있습니다.
   - **D**로 재생 위치에서 나누고, 구간을 클릭한 뒤 **Delete**로 잘라냅니다. **⌘Z**로 되돌립니다.
   - **Space** 재생, **← →** 한 프레임 이동, **I / O** 구간 시작과 끝 지정입니다.
5. "내보내기"를 누르면 `~/Movies`에 저장됩니다.

메뉴의 토글: 마이크 녹음(기본 꺼짐), 컴퓨터 소리 녹음(기본 켜짐), 영상 속 메뉴 막대 숨기기(기본 켜짐).

## 개인정보

Loupecast가 하는 네트워크 요청은 하루 한 번 GitHub 릴리스(`api.github.com`)에서 업데이트를 확인하는 것과, 새 버전이 있을 때 내려받는 것뿐입니다. 녹화 원본은 `~/Library/Application Support/Loupecast/Recordings`에, 내보낸 영상은 `~/Movies`에만 저장됩니다. 업로드, 분석, 텔레메트리가 없습니다.

## 소스에서 빌드

```sh
git clone https://github.com/dunzkoi/loupecast.git
cd loupecast
swift test
./build.sh          # → dist/Loupecast.app
```

Xcode 16 이상이 필요하고, 외부 의존성은 없습니다.

## 자주 묻는 질문

**업데이트하면 화면 녹화 권한을 다시 켜야 하나요?** 네. 아직 Apple Developer ID가 없어서 릴리스 빌드를 ad-hoc으로 서명하는데, macOS는 이 권한을 빌드마다 따로 기억합니다. 시스템 설정에서 기존 Loupecast 항목을 지우고 다시 켜 주세요.

**메뉴바 아이콘이 안 보여요.** 메뉴바가 꽉 차면 macOS가 새 아이콘을 숨길 수 있습니다. 시스템 설정 → 메뉴 막대를 확인하거나, 그냥 ⌘⇧2를 누르세요.

## 기여

버그 제보와 PR을 환영합니다. 먼저 [CONTRIBUTING.md](CONTRIBUTING.md)를 읽어 주세요. 모든 PR에 CI와 자동 리뷰가 돕니다.

## 라이선스

[MIT](LICENSE) © 2026 Dunz Koi
