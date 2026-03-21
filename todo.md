# Memora Push Notification 수정 계획

> **Date**: 2026-03-21
> **Issue**: Push 알림을 탭하면 나머지 쌓인 알림이 전부 사라지는 문제 (Cold Start 시)
> **Root Cause**: `notification_service.dart:185` — `_plugin.cancelAll()`

---

## 1. 가상 시뮬레이션 결과

### 테스트 환경 (가상)
- Android 14 (API 34), Samsung Galaxy S24
- Memora 알림 설정: 09:00~22:00, 30분 간격, 전체 폴더
- PushNotificationService (`:push` 프로세스) 정상 동작 중

### 시나리오별 테스트 매트릭스

#### A. 현재 코드 (수정 전)

| # | 시나리오 | 알림 상태 | 결과 | 원인 |
|---|---------|----------|------|------|
| A1 | Cold start — 알림 탭 | 5개 쌓임 | ❌ 나머지 4개 사라짐 | `main()` → `rescheduleAll()` → `cancelAll()` |
| A2 | Warm start — 알림 탭 | 5개 쌓임 | ✅ 나머지 4개 유지 | `onNewIntent()` 경로 — `cancelAll()` 안 불림 |
| A3 | 설정에서 알림 ON/OFF 토글 | 3개 쌓임 | ❌ 3개 전부 사라짐 | `rescheduleAll()` → `cancelAll()` |
| A4 | 설정에서 간격 저장 | 3개 쌓임 | ❌ 3개 전부 사라짐 | `_saveIntervalAlarm()` → `rescheduleAll()` → `cancelAll()` |
| A5 | 설정에서 폴더/알림음 변경 | 3개 쌓임 | ❌ 3개 전부 사라짐 | `_applyGlobalSettings()` → `rescheduleAll()` → `cancelAll()` |
| A6 | 테스트 알림 보내기 | 3개 쌓임 | ✅ 유지 (직접 `_plugin.show`) | `rescheduleAll()` 안 불림 |
| A7 | 부팅 후 LockScreenStartReceiver | 3개 쌓임 | ✅ 유지 | Kotlin 단독 — Flutter 안 거침 |
| A8 | Cold start + 잠금화면 서비스 | 잠금화면 FGS 알림 | ❌ FGS 알림 순간 사라짐 | `cancelAll()`이 LockScreenService 알림도 제거 → 레이스 |
| A9 | Cold start + Import 진행 중 | ImportExport FGS 알림 | ❌ 진행 알림 사라짐 | `cancelAll()`이 ImportExportService 알림도 제거 |
| A10 | 연속 2개 알림 탭 (Cold→Warm) | 5개 쌓임 | ❌→✅ | 첫 번째(Cold): 전부 사라짐. 이후 새로 쌓인 것은 Warm이라 유지 |

#### B. 수정 후 (cancelAll 제거) — 예상 결과

| # | 시나리오 | 예상 결과 | 검증 포인트 |
|---|---------|----------|-----------|
| B1 | Cold start — 알림 탭 | ✅ 나머지 유지 | `cancelAll()` 제거됨 |
| B2 | Warm start — 알림 탭 | ✅ 나머지 유지 | 기존과 동일 (변경 없음) |
| B3 | 설정에서 알림 ON/OFF 토글 | ✅ 쌓인 알림 유지 | 서비스만 중지, 기존 알림 보존 |
| B4 | 설정에서 간격 저장 | ✅ 쌓인 알림 유지 | 서비스 재설정만, 기존 알림 보존 |
| B5 | 설정에서 폴더/알림음 변경 | ✅ 쌓인 알림 유지 | 서비스 재설정만, 기존 알림 보존 |
| B6 | 테스트 알림 보내기 | ✅ 유지 | 변경 없음 |
| B7 | 부팅 후 복원 | ✅ 유지 | 변경 없음 |
| B8 | Cold start + 잠금화면 서비스 | ✅ FGS 알림 안정 | 레이스 컨디션 해소 |
| B9 | Cold start + Import 진행 중 | ✅ 진행 알림 유지 | 레이스 컨디션 해소 |
| B10 | 연속 알림 탭 | ✅ 매번 유지 | Cold/Warm 무관 |
| B11 | 알림 OFF → 서비스 중지 후 잔존 알림 | ✅ 잔존 (무해) | 탭하면 정상 네비게이션, 스와이프로 개별 삭제 가능 |
| B12 | 500개 알림 누적 (ID 순환) | ✅ 정상 | ID = 50000+(tick%500), 오래된 알림 자동 교체 |

### 부작용 분석

| 우려사항 | 분석 | 위험도 |
|---------|------|--------|
| flutter_local_notifications 좀비 알림 남음? | 이 앱은 `_plugin.show(99999)` (테스트 알림)만 사용. 고정 ID라 자체 교체됨. 좀비 불가. | 없음 |
| 알림 OFF 시 쌓인 알림 안 지워짐 | 서비스 중지로 새 알림 안 옴. 기존 알림은 유저가 스와이프 or 전체삭제. UX상 문제 없음. | 없음 |
| `cancelAllNotifications()` 메소드 호출처 | 현재 코드에서 호출하는 곳 없음 (사실상 미사용). 하지만 일관성 위해 같이 수정. | 없음 |
| `rescheduleAll()` 이 PushNotificationService 재시작 → 타이머 리셋 | 이건 기존 동작. `cancelAll()` 제거와 무관. 별도 이슈로 분리. | 기존 |

---

## 2. 수정 계획

### 변경 파일: 1개

**`lib/services/notification_service.dart`** — 단 1줄 수정

### 수정 내용

#### Step 1: `_rescheduleAllImpl()` 에서 `cancelAll()` 제거

```
수정 전 (185줄):
    try { await _plugin.cancelAll(); } catch (_) {}

수정 후:
    // 주의: _plugin.cancelAll()은 NotificationManager.cancelAll()을 호출하여
    // 네이티브 PushNotificationService가 발행한 카드 알림까지 전부 삭제함.
    // 이 앱은 flutter_local_notifications로 스케줄링하지 않으므로 (네이티브 FGS 사용)
    // cancelAll()이 불필요하며, 쌓인 push 알림을 죽이는 부작용만 발생.
    // → 삭제 (테스트 알림 ID 99999는 고정 ID라 자체 교체됨)
```

#### Step 2: `cancelAllNotifications()` 도 일관성 있게 수정

```
수정 전 (357-364줄):
    static Future<void> cancelAllNotifications() async {
        final errors = <String>[];
        try { await stopIntervalService(); } catch (e) { errors.add('stopService: $e'); }
        try { await _plugin.cancelAll(); } catch (e) { errors.add('cancelAll: $e'); }
        ...
    }

수정 후:
    static Future<void> cancelAllNotifications() async {
        final errors = <String>[];
        try { await stopIntervalService(); } catch (e) { errors.add('stopService: $e'); }
        // _plugin.cancelAll() 제거: 네이티브 push 알림까지 삭제하는 부작용 방지
        ...
    }
```

### 변경하지 않는 것

| 파일 | 이유 |
|------|------|
| `PushNotificationService.kt` | 알림 생성 로직 정상. 변경 불필요. |
| `MainActivity.kt` | Intent/MethodChannel 처리 정상. 변경 불필요. |
| `main.dart` | `rescheduleAll()` 호출 자체는 정상 (서비스 재설정용). `cancelAll()`만 문제. |
| `push_notification_settings.dart` | `rescheduleAll()` 호출 경로가 수정되므로 자동 해결. |

---

## 3. 검증 계획

### 빌드 검증
- [ ] `flutter analyze` — No issues
- [ ] `flutter build apk --debug` — 빌드 성공
- [ ] `adb install` — 기기 설치

### 기능 테스트 (실기기)
- [ ] **T1**: 알림 5개 쌓은 후 앱 강제 종료 → 알림 1개 탭 → 나머지 4개 유지 확인
- [ ] **T2**: 알림 5개 쌓은 후 앱 살아있는 상태 → 알림 1개 탭 → 나머지 4개 유지 확인
- [ ] **T3**: 알림 3개 쌓은 후 → 설정 → 알림 OFF → 쌓인 알림 유지, 새 알림 안 옴 확인
- [ ] **T4**: 알림 3개 쌓은 후 → 설정 → 간격 변경 → 저장 → 쌓인 알림 유지 확인
- [ ] **T5**: 알림 탭 → 해당 카드로 정상 네비게이션 확인
- [ ] **T6**: 테스트 알림 → 정상 표시 + 기존 알림 유지 확인
- [ ] **T7**: 잠금화면 서비스 ON 상태에서 Cold start → FGS 알림 정상 유지 확인

---

## 4. 요약

| 항목 | 내용 |
|------|------|
| **수정 파일** | `notification_service.dart` 1개 |
| **수정 줄 수** | 2줄 삭제 (185줄, 360줄) |
| **영향 범위** | `rescheduleAll()` 호출 경로 전체 (cold start + 설정 변경) |
| **위험도** | 매우 낮음 — 기능 제거가 아닌 불필요한 부작용 제거 |
| **근본 원인** | `flutter_local_notifications`의 `cancelAll()` ≠ "플러그인 알림만 삭제". Android `NotificationManager.cancelAll()` 호출로 앱 전체 알림 삭제. |

---

## 이전 전수조사 결과 (2026-03-18)

> 아래는 이전에 완료된 버그 수정 이력입니다.

### ✅ 수정 완료

| # | 파일 | 수정 내용 | 검증 |
|---|------|----------|------|
| ROOT | `database_helper.dart:44` | `PRAGMA journal_mode = WAL` 제거 (DB 열기 실패 → 전체 마비) | analyze ✅ build ✅ |
| H1 | `import_screen.dart:115` | Import 전 `_controller.isRunning` 체크 + SnackBar | SAFE ✅ |
| H2 | `database_helper.dart:628` + `card_list_screen.dart` 3곳 | `getAllCards(sortBy:)` 파라미터 추가, allCards 모드 정렬 적용 | SAFE ✅ |
| M1 | `export_screen.dart:47` | 새 ExportScreen 진입 시 `clearExportResult()` 호출 | SAFE ✅ |
| M2 | `card_list_screen.dart:985,992` | 정답 접기/가리기 토글 시 `upsertSetting()` 추가 | SAFE ✅ |
| M3 | `push_notification_settings.dart:144` | `endMinutes <= startMinutes` → `endMinutes == startMinutes` (야간 허용) | SAFE ✅ |
| M4 | `push_notification_settings.dart:186` | `_intervalEnabled = true` 강제 설정 삭제 | SAFE ✅ |
| M5 | `home_screen.dart:372` | FilePicker catch 블록 + SnackBar 에러 메시지 추가 | SAFE ✅ |

### 미수정 (LOW — 기능 영향 없음)

| # | 파일 | 설명 |
|---|------|------|
| L1 | `card_tile.dart:224` | 빈 정답에 "(내용 없음)" 미표시 (질문은 표시됨) |
| L2 | `card_list_screen.dart:465` | 이동 대상 폴더 없을 때 빈 다이얼로그 |
| L3 | `card.dart:291` | `folderName ?? ''` → null이 빈 문자열로 변환 |
| L4 | `lock_screen_settings.dart:60` | `_loadData()` try/catch 없음 |
| L5 | `push_notification_settings.dart:36` | `notification_enabled` 키 하드코딩 중복 |
| L6 | `home_screen.dart:555` | 폴더 삭제 시 DB→파일 순서 (중간 크래시 시 고아 파일) |
