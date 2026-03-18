# Memora 전수조사 결과 — 버그 리스트

> **Date**: 2026-03-18
> **방법**: 에이전트 6마리 병렬 투입, 154개 시나리오 시뮬레이션
> **결과**: HIGH 2건 + MEDIUM 5건 + LOW 6건 → HIGH/MEDIUM 전부 수정 완료

---

## ✅ 수정 완료

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
| - | `notification_service.dart:319` | overnight 스케줄 허용 (M3 백엔드) | 이전 수정 |
| - | `pdf_export_service.dart:216` | PDF 이미지 70px → 300px | 이전 수정 |
| - | `card_edit_screen.dart:447` | `initialValue:` 유지 (Flutter 3.33+ 표준 확인) | analyze ✅ |

---

## 미수정 (LOW — 기능 영향 없음)

| # | 파일 | 설명 |
|---|------|------|
| L1 | `card_tile.dart:224` | 빈 정답에 "(내용 없음)" 미표시 (질문은 표시됨) |
| L2 | `card_list_screen.dart:465` | 이동 대상 폴더 없을 때 빈 다이얼로그 |
| L3 | `card.dart:291` | `folderName ?? ''` → null이 빈 문자열로 변환 |
| L4 | `lock_screen_settings.dart:60` | `_loadData()` try/catch 없음 |
| L5 | `push_notification_settings.dart:36` | `notification_enabled` 키 하드코딩 중복 |
| L6 | `home_screen.dart:555` | 폴더 삭제 시 DB→파일 순서 (중간 크래시 시 고아 파일) |

---

## 검증 결과

- `flutter analyze`: **No issues found**
- `flutter build apk --debug`: **빌드 성공**
- `adb install`: **기기 설치 완료**
