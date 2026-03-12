# Memora 고도화 TODO

> 전체 코드 심층 분석 결과 도출된 버그 수정 및 개선 항목
> 우선순위: 🔴 Critical → 🟠 High → 🟡 Medium

---

## 🔴 Critical Bugs (즉시 수정)

### BUG-01: main.dart 테스트 알림 제거
- **파일**: `lib/main.dart:36-38`
- **문제**: 앱 시작 3초 후 테스트 알림이 매번 발송됨. 개발용 코드가 프로덕션에 남아있음
- **코드**:
  ```dart
  Future.delayed(const Duration(seconds: 3), () {
    NotificationService.showTestNotification();
  });
  ```
- **해결**: 해당 3줄 삭제

### BUG-02: NotificationService 알림 제목 null
- **파일**: `lib/services/notification_service.dart`
- **문제**: `showTestNotification()`에서 알림 title이 항상 null로 전달될 수 있음
- **해결**: title에 기본값 'Memora' 설정

### BUG-03: ItemPositionsListener reduce() 빈 컬렉션 크래시
- **파일**: `lib/screens/card_list_screen.dart`
- **문제**: `positions.where(...).reduce()`에서 필터된 결과가 빈 컬렉션이면 StateError 발생
- **해결**: `reduce()` 호출 전 빈 리스트 체크 또는 `firstOrNull` 사용

### BUG-04: LockScreenSettings 번들 폴더 표시
- **파일**: `lib/screens/lock_screen_settings.dart`
- **문제**: `getAllFolders()`로 번들 폴더도 잠금화면 폴더 선택에 표시됨. 번들 폴더는 카드를 직접 갖지 않으므로 선택해도 카드 없음
- **해결**: 번들 폴더(`isBundle == true`) 필터링하여 목록에서 제외

### BUG-05: ImportScreen 폴더 매핑 불완전
- **파일**: `lib/screens/import_screen.dart`
- **문제**: 기존 폴더 선택 모드에서 일부 .memk 폴더만 매핑하고 나머지는 매핑하지 않으면, 매핑 안 된 폴더의 카드가 유실됨
- **해결**: 매핑되지 않은 폴더는 자동으로 새 폴더 생성하도록 fallback 로직 추가

### BUG-06: ExportScreen 파일 저장/DB 불일치
- **파일**: `lib/screens/export_screen.dart`
- **문제**: `exportMemk()` 성공 후 `insertExportedFile()` 실패 시, 파일은 존재하지만 DB에 기록 없음
- **해결**: 전체 과정을 try-catch로 감싸고, DB 실패 시 파일 삭제 또는 재시도

### BUG-07: FileListScreen 날짜 문자열 substring 크래시
- **파일**: `lib/screens/file_list_screen.dart`
- **문제**: `createdAt.substring(0, 10)` — 10자 미만이면 RangeError
- **해결**: 길이 체크 후 substring, 또는 안전한 날짜 파싱 사용

### BUG-08: CardEditScreen GMT+09:00 하드코딩
- **파일**: `lib/screens/card_edit_screen.dart`
- **문제**: 타임존이 `GMT+09:00`으로 하드코딩. 해외 사용 시 시간 불일치
- **해결**: `DateTime.now().timeZoneOffset`에서 동적으로 계산

---

## 🟠 High Priority (성능 & 안정성)

### PERF-01: NotificationService 카드 랜덤 선택 비효율
- **파일**: `lib/services/notification_service.dart`
- **문제**: 카드 100개 조회 후 랜덤 1개 선택. 불필요한 I/O
- **해결**: DB에서 `ORDER BY RANDOM() LIMIT 1` 쿼리 추가

### PERF-02: MemkExportService N+1 쿼리
- **파일**: `lib/services/memk_export_service.dart`
- **문제**: 폴더 N개 → N번 `countCardsByFolderId()` 개별 쿼리
- **해결**: `SELECT folder_id, COUNT(*) FROM cards WHERE folder_id IN (...) GROUP BY folder_id` 단일 쿼리

### PERF-03: PdfExportService 동기 I/O
- **파일**: `lib/services/pdf_export_service.dart`
- **문제**: `readAsBytesSync()` 동기 호출로 대량 이미지 처리 시 UI 프리징
- **해결**: `readAsBytes()` 비동기 사용

### PERF-04: ZIP 디코딩 메인 스레드 블로킹
- **파일**: `lib/services/memk_import_service.dart`, `memk_export_service.dart`
- **문제**: `ZipDecoder().decodeBytes()` 대용량 파일에서 UI 프리징
- **해결**: `compute()` 함수로 Isolate에서 처리

### PERF-05: HomeScreen getTotalCardCount() 비효율
- **파일**: `lib/screens/home_screen.dart`
- **문제**: 매번 전체 카드 COUNT 쿼리 실행. 폴더별 card_count 합계로 대체 가능
- **해결**: 폴더 로드 시 `SUM(card_count)` 계산

### ERR-01: MemkImportService JSON 파싱 예외 미처리
- **파일**: `lib/services/memk_import_service.dart`
- **문제**: 손상된 .memk 파일의 잘못된 JSON → 앱 크래시
- **해결**: jsonDecode에 try-catch 추가, 사용자에게 친화적 에러 메시지

### ERR-02: ImportExportController 경쟁 조건
- **파일**: `lib/services/import_export_controller.dart`
- **문제**: `isRunning` 플래그 체크와 설정 사이에 동시 호출 가능
- **해결**: Completer 기반 락 또는 synchronized 접근

### ERR-03: FileListScreen 파일 삭제 에러 무시
- **파일**: `lib/screens/file_list_screen.dart`
- **문제**: `catch (_) {}` — 삭제 실패 사용자에게 알림 없음
- **해결**: 에러 로깅 + SnackBar 표시

---

## 🟡 Medium Priority (UX & 코드 품질)

### UX-01: PushNotificationSettings 권한 거부 시 설정 앱 연동
- **파일**: `lib/screens/push_notification_settings.dart`
- **문제**: 알림 권한 거부 시 "설정에서 허용해주세요" 텍스트만 표시, 설정으로 이동 버튼 없음
- **해결**: `openAppSettings()` 버튼 추가

### UX-02: HomeScreen 새 카드 추가 UX 개선
- **파일**: `lib/screens/home_screen.dart`
- **문제**: "폴더를 먼저 선택해주세요" 스낵바 → 폴더가 있으면 폴더 선택 다이얼로그 직접 표시가 더 자연스러움
- **해결**: 폴더 선택 다이얼로그 → 선택 후 CardEditScreen으로 이동

### UX-03: 검색 하이라이트 미흡
- **파일**: `lib/screens/card_list_screen.dart`
- **문제**: 검색어 매칭 부분의 시각적 강조가 부족할 수 있음
- **해결**: 검색어 부분에 TextSpan 하이라이팅 강화

### UX-04: ExportScreen 진행률 표시 개선
- **파일**: `lib/screens/export_screen.dart`
- **문제**: 내보내기 중 진행 바만 표시, 백분율이나 카드 수 미표시
- **해결**: "123/500 카드 처리 중 (24%)" 형식의 상세 진행률

### UX-05: BundleFolderScreen 비활성 폴더 설명
- **파일**: `lib/screens/bundle_folder_screen.dart`
- **문제**: 다른 묶음에 속한 폴더가 비활성화되지만 이유 설명 없음
- **해결**: "(다른 묶음에 포함됨)" 서브타이틀 표시

### CODE-01: NotificationService 중복 코드 리팩토링
- **파일**: `lib/services/notification_service.dart`
- **문제**: 카드 선택 + 알림 생성 로직이 3곳에서 반복
- **해결**: `_selectRandomCard()` 헬퍼 메서드 추출

### CODE-02: NotificationService 매직 넘버
- **파일**: `lib/services/notification_service.dart`
- **문제**: 알림 ID 계산에 `* 10`, `* 10000` 등 매직 넘버 사용
- **해결**: `AppConstants`에 상수로 정의

### CODE-03: SettingsScreen 설정값 실제 적용 누락
- **파일**: `lib/screens/settings_screen.dart`, `card_list_screen.dart`
- **문제**: 설정 화면에서 "정답 접기 기본값", "카드 번호 표시" 등을 변경해도 카드 리스트에서 해당 설정을 읽어 적용하지 않을 수 있음
- **해결**: CardListScreen 초기화 시 settings 테이블에서 기본값 로드

---

## 진행 현황

| ID | 상태 | 설명 |
|----|------|------|
| BUG-01 | ✅ | 테스트 알림 제거 — `main.dart:36-38` 삭제 |
| BUG-02 | ✅ | 알림 제목 null → 기본값 'Memora' + 폴더명 표시 |
| BUG-03 | ✅ | reduce() 크래시 → 빈 컬렉션 체크 추가 |
| BUG-04 | ✅ | 번들 폴더 잠금화면 → isBundle 필터링 |
| BUG-05 | ✅ | 폴더 매핑 fallback → null 값은 새 폴더 자동 생성 |
| BUG-06 | ✅ | 내보내기 DB 불일치 → 개별 try-catch 분리 |
| BUG-07 | ✅ | 날짜 substring 크래시 → 길이 체크 추가 |
| BUG-08 | ✅ | GMT 하드코딩 → timeZoneOffset 동적 계산 |
| PERF-01 | ✅ | 랜덤 카드 쿼리 → DB RANDOM() LIMIT 1 |
| PERF-02 | ⬜ | N+1 쿼리 |
| PERF-03 | ✅ | PDF 동기 I/O → 비동기 preloadImages 캐시 |
| PERF-04 | ⬜ | ZIP Isolate |
| PERF-05 | ✅ | 카드 카운트 효율화 → 폴더 card_count 합산 |
| ERR-01 | ✅ | JSON 파싱 예외 → try-catch 추가 |
| ERR-02 | ⬜ | 경쟁 조건 |
| ERR-03 | ✅ | 파일 삭제 에러 → SnackBar + 로깅 |
| UX-01 | ⬜ | 권한 설정 연동 |
| UX-02 | ⬜ | 새 카드 UX |
| UX-03 | ⬜ | 검색 하이라이트 |
| UX-04 | ⬜ | 진행률 상세화 |
| UX-05 | ✅ | 묶음 폴더 설명 → "다른 묶음에 포함됨" 표시 |
| CODE-01 | ⬜ | 알림 중복 코드 |
| CODE-02 | ✅ | 매직 넘버 → 명명 상수로 교체 |
| CODE-03 | ✅ | 설정값 적용 → 정답 접기/숨기기 기본값 연결 |
| EXTRA | ✅ | main.dart unused import 제거 |
