# Feature: Play Store 출시 준비 — 패키지명 변경 + 독자 포맷 전환 + 레거시 참조 제거

> 이 플랜을 실행하기 전에 반드시 아래 CONTEXT REFERENCES의 모든 파일을 읽고 패턴을 확인할 것.

## Feature Description

암기짱(com.metastudiolab.memorize)과의 법적 리스크를 제거하기 위해:
1. 패키지명을 `com.henry.memora` → `com.henry.memora`로 변경
2. 내보내기 포맷을 `.memk` → `.memora`로 변경 (가져오기는 `.memk` + `.memora` 둘 다 지원)
3. 레거시 `amkizzangImagePrefix` 상수명을 중립적 이름으로 변경
4. DB 파일명, 프로젝트명 등 `memora` 참조를 `memora`로 통일

## User Story

As a 앱 개발자
I want to 암기짱과 완전히 구별되는 독립적인 앱 아이덴티티를 갖고 싶다
So that Play Store 출시 시 법적 분쟁 없이 안전하게 배포할 수 있다

## Problem Statement

현재 코드에 암기짱의 패키지 경로(`com.metastudiolab.memorize`), 독자 파일 포맷(`.memk`), 변수명(`amkizzangImagePrefix`)이 직접 참조되어 있어 역공학/카피캣으로 해석될 수 있음.

## Solution Statement

패키지명, 파일 포맷 확장자, 레거시 참조를 모두 독립적인 이름으로 변경. `.memk` 가져오기는 호환성 유지. 내부 ZIP 구조(folders.json 등)는 동일하게 유지하여 기능 100% 보존.

## Feature Metadata

**Feature Type**: Refactor
**Estimated Complexity**: Medium
**Primary Systems Affected**: Android Native (Kotlin 6개), Dart (lib/ 8개, test/ 4개), Build Config (Gradle, CMake, pubspec)
**Dependencies**: 없음 (순수 리네이밍)

---

## CONTEXT REFERENCES

### Relevant Codebase Files — MUST READ BEFORE IMPLEMENTING

#### Phase 1: 패키지명 변경 (Kotlin + Build)
- `android/app/build.gradle.kts` (line 9, 25) — namespace, applicationId
- `android/app/src/main/kotlin/com/henry/memora/MainActivity.kt` (line 1, 18-19, 212) — package, MethodChannel 3개
- `android/app/src/main/kotlin/com/henry/memora/LockScreenService.kt` (line 1) — package
- `android/app/src/main/kotlin/com/henry/memora/PushNotificationService.kt` (line 1) — package
- `android/app/src/main/kotlin/com/henry/memora/ImportExportService.kt` (line 1) — package
- `android/app/src/main/kotlin/com/henry/memora/PdfGenerator.kt` (line 1) — package
- `android/app/src/main/kotlin/com/henry/memora/LockScreenStartReceiver.kt` (line 1) — package
- `android/app/src/main/kotlin/com/henry/memora/ScreenReceiver.kt` (line 1) — package

#### Phase 1: 패키지명 변경 (Dart MethodChannel)
- `lib/main.dart` (line 54) — `com.henry.memora/import_export`
- `lib/services/lock_screen_service.dart` (line 5) — `com.henry.memora/lockscreen`
- `lib/services/notification_service.dart` (line 17) — `com.henry.memora/push_notif`
- `lib/services/import_export_controller.dart` (line 19) — `com.henry.memora/import_export`
- `lib/screens/push_notification_settings.dart` (line 193) — `com.henry.memora/push_notif`
- `lib/screens/home_screen.dart` (line 627) — `com.henry.memora/import_export`
- `lib/screens/file_list_screen.dart` (line 19) — `com.henry.memora/import_export`

#### Phase 2: .memk → .memora 포맷 전환
- `android/app/src/main/AndroidManifest.xml` (line 48-49, 59, 68) — intent-filter, MIME type, pathPattern
- `lib/utils/constants.dart` (line 28-31) — memkFoldersJson 등 상수
- `lib/services/memk_export_service.dart` — 전체 (export 로직)
- `lib/services/memk_import_service.dart` — 전체 (import 로직)
- `lib/services/import_export_controller.dart` (line 238, 242, 294) — 파일명 생성
- `lib/screens/export_screen.dart` (line 31, 169, 288, 291) — UI 선택지
- `lib/screens/file_list_screen.dart` (line 77, 136, 139, 307, 446-460) — 파일 목록/복원
- `lib/screens/home_screen.dart` (line 97-110, 226, 365, 368) — 가져오기 UI
- `lib/screens/import_screen.dart` (line 31, 37, 87-340) — 가져오기 화면

#### Phase 3: 레거시 참조 제거
- `lib/utils/constants.dart` (line 20-21) — `amkizzangImagePrefix`
- `lib/services/memk_export_service.dart` (line 31, 219) — amkizzangImagePrefix 사용
- `test/services/memk_export_service_test.dart` (line 17, 25) — 테스트 데이터
- `test/services/memk_import_service_test.dart` (line 15, 116, 182) — 테스트 데이터
- `test/models/card_test.dart` (line 13, 38) — 레거시 경로 테스트 데이터

#### Phase 4: 프로젝트명/DB명 통일
- `pubspec.yaml` (line 1) — `name: memora`
- `lib/utils/constants.dart` (line 5) — `dbName = 'memora.db'`
- `windows/CMakeLists.txt` (line 3, 7) — project name, BINARY_NAME
- `linux/CMakeLists.txt` (line 7, 10) — BINARY_NAME, APPLICATION_ID
- `windows/runner/main.cpp` (line 30) — window title
- `windows/runner/Runner.rc` (line 93-98) — file description
- `linux/runner/my_application.cc` (line 48, 52) — window title
- `web/manifest.json` (line 2-3) — name, short_name
- `web/index.html` (line 26, 32) — apple-mobile-web-app-title, title
- `ios/Runner/Info.plist` (line 18) — bundle name
- `macos/Runner/Configs/AppInfo.xcconfig` (line 8, 11) — PRODUCT_NAME, BUNDLE_IDENTIFIER
- 테스트 파일 5개 — `import 'package:memora/...'` → `import 'package:memora/...'`

### Patterns to Follow

**MethodChannel 네이밍**: `com.henry.memora/lockscreen`, `com.henry.memora/import_export`, `com.henry.memora/push_notif`

**파일 포맷 호환 전략**:
- 가져오기: `.memk` + `.memora` 둘 다 허용
- 내보내기: `.memora`만 생성
- ZIP 내부 구조: 변경 없음 (folders.json, cards.json, counter.json, prefs.json)

**DB 마이그레이션**: 불필요. 패키지명 변경 시 앱 재설치 필수이므로 새 DB 생성됨. 기존 데이터는 `.memk` 내보내기 → 새 앱에서 가져오기로 이전.

---

## IMPLEMENTATION PLAN

### Phase 1: 패키지명 변경 (`com.henry.memora` → `com.henry.memora`)

**주의**: Kotlin 디렉토리 구조도 함께 변경해야 함 (`kotlin/com/henry/memora/` → `kotlin/com/henry/memora/`)

**Tasks:**

1. `android/app/build.gradle.kts` — namespace, applicationId 변경
2. Kotlin 디렉토리 이동: `android/app/src/main/kotlin/com/henry/memora/` → `android/app/src/main/kotlin/com/henry/memora/`
3. 모든 Kotlin 파일 (8개) — `package com.henry.memora` → `package com.henry.memora`
4. `MainActivity.kt` — MethodChannel 이름 3개 변경
5. Dart 파일 7개 — MethodChannel 이름 변경 (일괄 치환: `com.henry.memora` → `com.henry.memora`)
6. `AndroidManifest.xml` — 자동 반영 (namespace 기반), 단 Kotlin 클래스 참조 확인

**VALIDATE**: `cd /tmp && cp -r <project> memora_build && cd memora_build && flutter build apk --debug`

### Phase 2: 내보내기 포맷 `.memk` → `.memora` 전환

**전략**: 내보내기만 `.memora`. 가져오기는 `.memk` + `.memora` 둘 다.

**Tasks:**

1. `lib/services/import_export_controller.dart` — 내보내기 파일명: `.memk` → `.memora`
2. `lib/screens/export_screen.dart` — UI 라벨: `.memk` → `.memora`, value: `'memk'` → `'memora'`
3. `lib/screens/file_list_screen.dart` — 파일 타입 체크에 `'memora'` 추가, 복원 시 `.memk` + `.memora` 둘 다 허용
4. `lib/screens/home_screen.dart` — 가져오기 시 `.memk` + `.memora` 둘 다 허용, UI 텍스트 업데이트
5. `lib/screens/import_screen.dart` — 변수명 `_memkFolders` → `_importFolders` (선택적)
6. `android/app/src/main/AndroidManifest.xml` — intent-filter에 `.memora` pathPattern + MIME type 추가 (`.memk`도 유지)
7. `lib/utils/constants.dart` — 상수명 `memkFoldersJson` 등은 내부 변수이므로 변경 선택적. 변경한다면 `importFoldersJson` 등으로.

**VALIDATE**: `flutter test && flutter analyze`

### Phase 3: 레거시 참조 제거

**Tasks:**

1. `lib/utils/constants.dart` — `amkizzangImagePrefix` → `legacyImagePrefix` (값은 동일 유지! 기능 보존 필수)
2. `lib/services/memk_export_service.dart` — `AppConstants.amkizzangImagePrefix` → `AppConstants.legacyImagePrefix`
3. 테스트 파일 3개 — 상수 참조 업데이트

**VALIDATE**: `flutter test`

### Phase 4: 프로젝트명/DB명 통일

**Tasks:**

1. `pubspec.yaml` — `name: memora` → `name: memora`
2. `lib/utils/constants.dart` — `dbName = 'memora.db'` → `dbName = 'memora.db'`
3. Kotlin DB 경로 참조 (LockScreenService, PushNotificationService, PdfGenerator) — `memora.db` → `memora.db`
4. 테스트 파일 5개 — `import 'package:memora/...'` → `import 'package:memora/...'`
5. Windows/Linux/Web/iOS/macOS 설정 파일 — `memora` → `memora` (window title, binary name 등)
6. `CLAUDE.md` — MethodChannel 참조 업데이트

**VALIDATE**: `flutter test && flutter analyze && flutter build apk --debug`

---

## STEP-BY-STEP TASKS

### Task 1: UPDATE `android/app/build.gradle.kts`
- **IMPLEMENT**: `namespace = "com.henry.memora"`, `applicationId = "com.henry.memora"`
- **VALIDATE**: 파일 저장 후 다음 태스크 진행

### Task 2: MOVE Kotlin 디렉토리
- **IMPLEMENT**: `mv android/app/src/main/kotlin/com/henry/memora android/app/src/main/kotlin/com/henry/memora`
- **GOTCHA**: debug/profile 디렉토리에도 memora이 있는지 확인
- **VALIDATE**: `ls android/app/src/main/kotlin/com/henry/memora/`

### Task 3: UPDATE 모든 Kotlin 파일 (8개) package 선언
- **IMPLEMENT**: `package com.henry.memora` → `package com.henry.memora` (일괄 치환)
- **VALIDATE**: `grep -r "com.henry.memora" android/`

### Task 4: UPDATE MethodChannel 이름 (Kotlin + Dart)
- **IMPLEMENT**: `com.henry.memora/lockscreen` → `com.henry.memora/lockscreen` (전체 프로젝트 일괄)
- **IMPLEMENT**: `com.henry.memora/import_export` → `com.henry.memora/import_export`
- **IMPLEMENT**: `com.henry.memora/push_notif` → `com.henry.memora/push_notif`
- **VALIDATE**: `grep -r "com.henry.memora" lib/ android/`

### Task 5: UPDATE `pubspec.yaml`
- **IMPLEMENT**: `name: memora` → `name: memora`
- **VALIDATE**: `flutter pub get`

### Task 6: UPDATE 테스트 파일 imports (5개)
- **IMPLEMENT**: `import 'package:memora/` → `import 'package:memora/` (일괄 치환)
- **VALIDATE**: `flutter test`

### Task 7: UPDATE DB 파일명
- **IMPLEMENT**: `constants.dart` — `dbName = 'memora.db'`
- **IMPLEMENT**: LockScreenService.kt, PushNotificationService.kt, PdfGenerator.kt — `memora.db` → `memora.db`
- **VALIDATE**: `grep -r "memora.db" lib/ android/`

### Task 8: UPDATE 레거시 상수명
- **IMPLEMENT**: `constants.dart` — `amkizzangImagePrefix` → `legacyImagePrefix` (값 변경 없음!)
- **IMPLEMENT**: `memk_export_service.dart` — 참조 업데이트
- **IMPLEMENT**: 테스트 파일 — 참조 업데이트
- **VALIDATE**: `grep -r "amkizzang" lib/ test/`

### Task 9: UPDATE 내보내기 포맷
- **IMPLEMENT**: `import_export_controller.dart` — 파일 확장자 `.memk` → `.memora`
- **IMPLEMENT**: `export_screen.dart` — UI 라벨/값 변경
- **IMPLEMENT**: `file_list_screen.dart` — `.memk` + `.memora` 둘 다 허용
- **IMPLEMENT**: `home_screen.dart` — 가져오기 필터에 `.memora` 추가, `.memk`도 유지
- **VALIDATE**: `flutter analyze`

### Task 10: UPDATE AndroidManifest intent-filter
- **IMPLEMENT**: `.memora` pathPattern + MIME type 추가 (기존 `.memk` 유지)
- **VALIDATE**: `grep -i "memk\|memora" android/app/src/main/AndroidManifest.xml`

### Task 11: UPDATE Windows/Linux/Web/iOS/macOS 설정
- **IMPLEMENT**: 모든 `memora` 참조를 `memora`로 변경
- **VALIDATE**: `grep -r "memora" windows/ linux/ web/ ios/ macos/`

### Task 12: UPDATE CLAUDE.md
- **IMPLEMENT**: MethodChannel 참조, 프로젝트 구조, 빌드 명령어 업데이트
- **VALIDATE**: 수동 확인

### Task 13: FINAL BUILD & TEST
- **VALIDATE**:
  ```bash
  rm -rf /tmp/memora_build
  cp -r . /tmp/memora_build
  cd /tmp/memora_build
  C:/flutter/bin/flutter test
  C:/flutter/bin/flutter analyze
  C:/flutter/bin/flutter build apk --debug
  ```

---

## TESTING STRATEGY

### Unit Tests
- `flutter test` — 기존 90개 테스트 전부 통과 확인
- import path 변경으로 인한 컴파일 에러만 체크 (로직 변경 없음)

### Integration Tests
- 빌드 성공: `flutter build apk --debug`
- 기기 설치: `adb install -r` 후 앱 정상 실행

### Edge Cases
- `.memk` 파일 가져오기 — 기존 암기짱 파일 호환성 유지 확인
- `.memora` 파일 내보내기 → 가져오기 round-trip 확인
- 잠금화면 서비스 정상 작동 (MethodChannel 이름 변경 후)
- 푸시 알림 서비스 정상 작동

---

## VALIDATION COMMANDS

### Level 1: Syntax & Style
```bash
C:/flutter/bin/flutter analyze
```

### Level 2: Unit Tests
```bash
C:/flutter/bin/flutter test
```

### Level 3: Build
```bash
rm -rf /tmp/memora_build && cp -r . /tmp/memora_build && cd /tmp/memora_build && C:/flutter/bin/flutter build apk --debug
```

### Level 4: 잔여 참조 확인
```bash
grep -r "memora" lib/ test/ android/ --include="*.dart" --include="*.kt" --include="*.kts" --include="*.xml"
grep -r "amkizzang" lib/ test/
```

### Level 5: Manual Validation
- 기기 설치 후 앱 실행
- 폴더 생성 → 카드 추가 → `.memora`로 내보내기 → 가져오기 확인
- 기존 `.memk` 파일 가져오기 확인
- 잠금화면/푸시 알림 상주 알림 탭 → 설정 화면 이동 확인

---

## ACCEPTANCE CRITERIA

- [ ] `grep -r "com.henry.memora"` — 결과 0건 (CLAUDE.md 제외)
- [ ] `grep -r "amkizzang"` — 결과 0건
- [ ] `flutter test` — 90/90 통과
- [ ] `flutter analyze` — No issues
- [ ] `flutter build apk --debug` — 빌드 성공
- [ ] `.memk` 파일 가져오기 정상 작동
- [ ] `.memora` 파일 내보내기 + 가져오기 round-trip 정상
- [ ] 잠금화면/푸시 알림 서비스 정상 작동
- [ ] MethodChannel 통신 정상 (잠금화면, 푸시 알림, Import/Export)

---

## COMPLETION CHECKLIST

- [ ] Phase 1 완료 (패키지명 변경)
- [ ] Phase 2 완료 (포맷 전환)
- [ ] Phase 3 완료 (레거시 제거)
- [ ] Phase 4 완료 (프로젝트명 통일)
- [ ] 전체 테스트 통과
- [ ] 기기 설치 + 수동 테스트 완료
- [ ] CLAUDE.md 업데이트
- [ ] git commit

---

## NOTES

### 데이터 마이그레이션
패키지명 변경 시 Android는 다른 앱으로 인식. 기존 앱 삭제 후 재설치 필요.
기존 데이터는 `.memk`로 내보내기 → 새 앱에서 가져오기로 이전.

### `.memk` 호환성 유지 이유
암기짱 사용자가 기존 `.memk` 파일을 Memora로 가져올 수 있어야 함.
이는 "파일 포맷 읽기"로 법적 리스크가 매우 낮음 (LibreOffice가 .docx를 읽는 것과 동일).

### `legacyImagePrefix` 값 유지 이유
`/data/user/0/com.metastudiolab.memorize/files/image/` 경로는 `.memk` 파일 내부의 이미지 경로에 포함됨.
이 값을 변경하면 기존 `.memk` 파일의 이미지 경로 파싱이 깨짐.
상수 **이름**만 중립적으로 변경하고, **값**은 반드시 유지.

### 예상 작업 시간
순수 리네이밍 작업이므로 로직 변경 없음. 13개 태스크, 약 70+ 파일 위치 수정.
