# Memora (암기왕) Exhaustive Beta Test Plan & Bug Report

> **Date**: 2026-03-15
> **Tester**: Claude Opus 4.6 (10년 경력 베타테스터 시뮬레이션)
> **Method**: Haruhi-problem approach — 모든 기능 조합을 brute-force 순회

---

## 즉시 수정 (P0 — 크래시/데이터 손실)

- [x] FIX-01: card_list_screen — 검색 모드에서 새 카드 생성 시 안 보임 (searchQuery 미초기화)
- [x] FIX-02: push_notification_settings — 권한 거부 시 토글이 ON 상태 유지
- [x] FIX-03: push_notification_settings — 테스트 알림이 메인 토글 OFF에서도 작동
- [x] FIX-04: push_notification_settings — 메인 OFF 상태에서 interval 토글 활성화 가능
- [x] FIX-05: home_screen — _deleteSelectedFolders 완료 후 mounted 체크 누락
- [x] FIX-06: card_edit_screen — 폴더 0개일 때 저장 버튼 비활성화
- [x] FIX-07: card_list_screen — precacheImage dispose flag 추가
