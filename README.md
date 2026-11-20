# QR 스캐너 (macOS)

맥북 전면(FaceTime) 카메라로 QR 코드를 인식하고, 내용에 맞는 동작을 바로 실행하는 macOS 앱입니다.
SwiftUI + AVFoundation + Vision으로 만들었고, 영상은 Mac 안에서만 처리되며 저장·전송하지 않습니다.

## 인식하는 QR 종류

| QR 내용 | 동작 |
|---|---|
| 웹사이트 (`https://…`, `example.com`) | 브라우저에서 열기, 링크 복사 |
| Wi-Fi (`WIFI:…`) | 연결 시도, 비밀번호 복사 |
| 연락처 (vCard / MECARD) | 연락처 앱에 추가 |
| 일정 (VEVENT) | 캘린더에 추가 |
| 전화 / 문자 / 이메일 | FaceTime 통화, 메시지, 메일 쓰기 |
| 위치 (`geo:`) | 지도에서 열기 |
| 앱 링크 (`scheme://…`) | 해당 앱 열기 |
| 일반 텍스트 | 복사, 웹 검색 |

단축 URL, HTTP, IP 주소, 퓨니코드 도메인 등 의심스러운 링크에는 경고를 표시합니다.

## 기능

- 인식한 QR 위치에 초록색 박스 표시, 인식음
- 웹 링크 자동 열기 모드 (확인 없이 바로 열기)
- 스캔 기록 (최대 300개, 우클릭 메뉴로 재실행·삭제)
- 이미지에서 QR 읽기: 화면에 끌어다 놓기, `⌘O`, 클립보드 `⇧⌘V`, Finder에서 "다음으로 열기"
- 여러 카메라(외장 카메라, iPhone 연속성 카메라) 선택
- 다른 앱 사용 중에는 카메라 자동 끄기

| 단축키 | 동작 |
|---|---|
| `Enter` | 결과의 첫 번째 동작 실행 |
| `⌘R` | 다시 스캔 |
| `⌘O` | 이미지 파일에서 QR 읽기 |
| `⇧⌘V` | 클립보드 이미지에서 QR 읽기 |
| `⌘,` | 설정 |

## 빌드

요구사항: macOS 14 이상, Xcode(또는 Command Line Tools)의 Swift 컴파일러

```bash
./build.sh
open "build/QR 스캐너.app"
```

처음 실행하면 카메라 권한을 묻습니다. 응용 프로그램 폴더에 설치하려면:

```bash
cp -R "build/QR 스캐너.app" /Applications/
```

> 로컬 ad-hoc 서명으로 빌드되므로, 다시 빌드하면 카메라 권한을 다시 물어볼 수 있습니다.

## 테스트

QR 내용 해석과 Vision 디코딩 자체 테스트:

```bash
swiftc -swift-version 5 Sources/QRContent.swift Sources/CameraScanner.swift Tools/SelfTest/main.swift -o build/selftest && build/selftest
```

## 구조

```
Sources/
  App.swift            앱 진입점, 메뉴, 파일 열기 처리
  AppModel.swift       상태, 스캔 기록, QR별 동작, Wi-Fi 연결
  CameraScanner.swift  카메라 세션 + Vision QR 인식
  QRContent.swift      QR 내용 해석 (URL, Wi-Fi, vCard, …)
  Views.swift          SwiftUI 화면
Tools/
  make_icon.swift      앱 아이콘 생성
  SelfTest/main.swift  자체 테스트
```
