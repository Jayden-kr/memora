# Memora 고도화 TODO (Round 19)

> 전체 코드 심층 재분석 (Round 19) — Round 18 (5항목 완료) 이후 새로 발견된 버그 및 고도화 항목
> 우선순위: 🔴 Critical → 🟠 High → 🟡 Medium → 🟢 Low
> 분석 범위: Flutter (Dart) 전체 + Android Native (Kotlin) 전체

---

## 🟠 High

### R19-01: PushNotificationSettings에서 삭제된 폴더 참조 시 화면 크래시
- **파일**: `lib/screens/push_notification_settings.dart:88`
- **문제**: 알림에 설정된 폴더가 삭제된 후 설정 화면 열면 DropdownButton value 불일치로 assertion error
- **해결**: folder_id 복원 시 현재 폴더 목록에 존재 여부 검증

### R19-02: 알림 ID `_safeId` 모듈로 200 오버플로
- **파일**: `lib/services/notification_service.dart:20,27`
- **문제**: `id % 200`으로 정규화. autoincrement ID가 200 초과 시 알림 ID 충돌 → 알림 덮어씀
- **해결**: `_maxAlarmId` 200→10000, `_intervalBase` 2000→100000 확대

---

## 🟡 Medium

### R19-03: BundleFolderScreen `_save()` 더블탭 가드 누락
- **파일**: `lib/screens/bundle_folder_screen.dart:68`
- **문제**: 저장 버튼 빠른 더블탭 시 동시 save → 중복 묶음 생성 가능
- **해결**: `_saving` 플래그 추가

### R19-04: PDF Export가 폴더의 전체 카드를 한번에 메모리 로드 (OOM 위험)
- **파일**: `lib/services/pdf_export_service.dart:72`
- **문제**: `getCardsByFolderId()` limit/offset 없이 전체 로드. 수만 장 폴더에서 OOM
- **해결**: `countCardsByFolderId` + 배치 단위 `getCardsByFolderId(limit, offset)` 페이지네이션

---

## 진행 현황

| ID | 상태 | 설명 |
|----|------|------|
| R19-01 | ✅ | 삭제된 폴더 참조 DropdownButton 크래시 방지 (이미 적용) |
| R19-02 | ✅ | _maxAlarmId 200→10000, _intervalBase 2000→100000 |
| R19-03 | ✅ | BundleFolderScreen _saving 가드 (이미 적용) |
| R19-04 | ✅ | PDF Export 카드 배치 페이지네이션 |
