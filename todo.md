# Memora 고도화 TODO (Round 13)

> 전체 코드 심층 재분석 (Round 13) — Round 12 (6항목 완료) 이후 새로 발견된 버그 및 고도화 항목
> 우선순위: 🔴 Critical → 🟠 High → 🟡 Medium → 🟢 Low
> 분석 범위: Flutter (Dart) 전체 + Android Native (Kotlin) 전체

---

## 🟠 High

### R13-01: ImportScreen._createNewLocalFolder setState mounted 체크 누락
- **파일**: `lib/screens/import_screen.dart:173`
- **문제**: async DB 작업(getMaxFolderSequence, insertFolder, getNonBundleFolders) 후 `setState()` 호출 시 `mounted` 체크 없음. 폴더 생성 중 화면 이탈 시 "setState() called after dispose" crash
- **해결**: `setState` 전 `if (!mounted) return;` 가드 추가

---

## 🟡 Medium

### R13-02: ImportExportService 완료 시 진행 알림 미제거 → 이중 알림
- **파일**: `android/.../ImportExportService.kt:58-78`
- **문제**: `showComplete()`가 `COMPLETE_NOTIFICATION_ID(2002)` 알림을 생성하지만 기존 `PROGRESS_NOTIFICATION_ID(2001)` 진행 알림을 취소하지 않음. 서비스 stop 전까지 사용자에게 2개 알림이 동시 표시
- **해결**: `showComplete()`에서 progress 알림 cancel 추가

### R13-03: MainActivity.isServiceRunning() NotificationManager NPE
- **파일**: `android/.../MainActivity.kt:202-203`
- **문제**: `getSystemService(NotificationManager::class.java)` 반환값이 null일 수 있으나 바로 `.activeNotifications` 접근 → NPE crash
- **해결**: null 체크 추가, null이면 SharedPreferences fallback 사용

### R13-04: LockScreenService WindowManager unsafe cast
- **파일**: `android/.../LockScreenService.kt:75`
- **문제**: `getSystemService(WINDOW_SERVICE) as WindowManager` — null 반환 시 ClassCastException crash. `as?` 안전 캐스트 필요
- **해결**: `as? WindowManager`로 변경

---

## 진행 현황

| ID | 상태 | 설명 |
|----|------|------|
| R13-01 | ✅ | ImportScreen setState mounted 체크 누락 |
| R13-02 | ✅ | ImportExportService 이중 알림 |
| R13-03 | ✅ | NotificationManager NPE |
| R13-04 | ✅ | WindowManager unsafe cast |
