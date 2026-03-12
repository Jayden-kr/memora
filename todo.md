# Memora 고도화 TODO (Round 8)

> 전체 코드 심층 분석 (Round 8) 결과 도출된 버그 수정 및 개선 항목
> 우선순위: 🔴 Critical → 🟠 High → 🟡 Medium

---

## 🟠 High

### R8-01: 폴더 이름 변경 후 mounted 체크 누락 → 크래시
- **파일**: `lib/screens/home_screen.dart:314-315`
- **문제**: `_renameFolder()`에서 `updateFolder()` await 후 `_loadFolders()` 호출 시 mounted 미체크. 이름 변경 중 화면 이탈 시 disposed widget에 setState
- **해결**: `if (!mounted) return;` 추가

### R8-02: 잠금화면 설정 다이얼로그 후 mounted 체크 누락
- **파일**: `lib/screens/lock_screen_settings.dart:115`
- **문제**: 오버레이 권한 다이얼로그에서 '취소' 선택 시 `setState(() => _enabled = false)` 호출에 mounted 체크 없음
- **해결**: `if (!mounted) return;` 추가

### R8-03: Import 결과의 skippedCards가 항상 0
- **파일**: `lib/services/memk_import_service.dart:226,241,245`
- **문제**: `skippedCards` 변수 선언 후 한 번도 증가시키지 않음. folderId null이거나 매핑 없는 카드는 `errors++`로 처리되어 import 결과에서 '건너뜀' 수가 항상 0. 실제 스킵된 카드와 진짜 에러를 구분 불가
- **해결**: folderId null/매핑 미존재 시 `skippedCards++` 사용, `errors++`는 실제 예외에만

---

## 🟡 Medium

### R8-04: [Kotlin] Typeface 메모리 누수 — onDestroy에서 미해제
- **파일**: `android/.../LockScreenService.kt:onDestroy()`
- **문제**: `fontRegular`/`fontBold` Typeface 참조가 서비스 종료 시 null로 설정되지 않음. 서비스 반복 시작/중지 시 Typeface 객체 누적
- **해결**: `onDestroy()`에서 `fontRegular = null; fontBold = null`

### R8-05: [Kotlin] ImportExportService onDestroy 누락 → 알림 잔존
- **파일**: `android/.../ImportExportService.kt`
- **문제**: `onDestroy()` 미구현. 앱 강제종료 시 포그라운드 알림이 알림창에 영구 잔존
- **해결**: `onDestroy()` 추가하여 `stopForeground(STOP_FOREGROUND_REMOVE)` 호출

### R8-06: [Kotlin] isServiceRunning SharedPreferences 동기화 미흡
- **파일**: `android/.../MainActivity.kt:isServiceRunning()`
- **문제**: 시스템이 서비스를 kill 시 `onDestroy()` 미호출 → SharedPreferences `service_running=true` 잔존. 알림 없는데 prefs만으로 running 판단 → 사용자에게 잘못된 상태 표시
- **해결**: 알림 미존재 확인 시 SharedPreferences도 false로 동기화

---

## 진행 현황

| ID | 상태 | 설명 |
|----|------|------|
| R8-01 | ✅ | 폴더 이름 변경 mounted |
| R8-02 | ✅ | 잠금화면 설정 mounted |
| R8-03 | ✅ | Import skippedCards 카운터 |
| R8-04 | ✅ | Typeface 메모리 해제 |
| R8-05 | ✅ | ImportExportService onDestroy |
| R8-06 | ✅ | isServiceRunning 동기화 |
