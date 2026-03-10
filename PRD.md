# Memora - Product Requirements Document

## 1. Executive Summary

Memora(구 암기왕)는 기존 "암기짱" 앱을 기반으로 한 플래시카드 학습 앱이다. 암기짱의 핵심 기능을 유지하되, 불필요한 기능을 제거하고 사용자 경험을 개선한 Android 전용 앱으로, Flutter + SQLite 기반의 기존 프로젝트를 수정하는 방향으로 개발한다.

핵심 개선사항은 세 가지다: (1) .memk 파일 가져오기 시 기존 폴더 선택 기능 추가 (암기짱은 무조건 새 폴더 생성), (2) 검색 시 Question 우선순위 정렬 및 키패드 내림 시 검색어 유지 버그 수정, (3) Coral Orange 테마 + 다크모드 지원으로 현대적 디자인 적용.

MVP 목표는 암기짱의 핵심 학습 기능(카드 CRUD, 폴더 관리, 검색, 가져오기/내보내기, 푸시 알림, 잠금화면)을 모두 포함하면서 위 개선사항을 반영한 완성된 앱을 배포하는 것이다.

---

## 2. Mission

**미션**: 단어/개념 암기 학습에 최적화된, 직관적이고 군더더기 없는 플래시카드 앱을 제공한다.

**핵심 원칙**:
1. **심플 퍼스트**: 사용하지 않는 기능은 과감히 제거. 학습에만 집중할 수 있는 UI
2. **데이터 주권**: .memk 호환성 유지로 암기짱과 데이터 이동 자유
3. **커스터마이징**: 가져오기 시 폴더 선택, 정답 보이기/숨기기, 정렬 등 사용자 제어권 강화
4. **안정성**: 검색 버그 등 기존 불편사항 해결, 데이터 손실 방지

---

## 3. Target Users

### Primary Persona: 자기주도 학습자
- **프로필**: 영어/일본어 등 외국어 단어 암기, 자격증 시험 준비
- **기술 수준**: 스마트폰 기본 조작 가능, 기술에 깊지 않음
- **기기**: Android 스마트폰
- **핵심 니즈**:
  - 대량의 카드(10,000+)를 효율적으로 관리
  - .memk 파일로 다른 사용자와 카드 공유
  - 푸시 알림과 잠금화면으로 일상 속 반복 학습
  - 빠른 검색으로 특정 카드 찾기
- **Pain Points (암기짱 기준)**:
  - .memk 가져오기 시 무조건 새 폴더 생성 → 폴더가 계속 늘어남
  - 검색 중 키패드 내리면 검색어가 사라짐
  - 앱 업데이트가 느리고 디자인이 오래됨

---

## 4. MVP Scope

### In Scope (Core Functionality)

**카드 관리**
- ✅ 카드 생성/읽기/수정/삭제 (Question + Answer 텍스트)
- ✅ 카드에 이미지 첨부 (최대 5장)
- ✅ 카드 복제
- ✅ 카드를 다른 폴더로 이동 (폴더 목록 다이얼로그)
- ✅ 다중 선택 & 일괄 삭제/이동

**카드 표시 & 학습**
- ✅ 리스트 형식 카드 뷰 (Question 위 / Answer 아래)
- ✅ Question 탭 → Answer 영역 접기
- ✅ Answer 탭 → Answer 내용(텍스트+이미지) 숨기기
- ✅ 정답 접고 펼치기 (전체 토글)
- ✅ 정답 보이기/가리기 (전체 토글, 정답 터치로 개별 확인)
- ✅ 카드 정렬: 최신순 / 오래된순 / 가나다순 / 랜덤

**폴더 관리**
- ✅ 폴더 생성/삭제/이름변경
- ✅ 묶음 폴더 (폴더 그룹화: 이름 입력 + 기존 폴더 체크박스 선택)
- ✅ 전체 카드 보기 (모든 폴더 카드 한번에)
- ✅ 폴더 정렬: 가나다순 / 오래된순 / 최신순 / 롱터치 드래그
- ✅ 폴더 ⋮ 메뉴: 파일 만들기 / 편집 / 삭제

**검색**
- ✅ 폴더 내 카드 검색 (🔍)
- ✅ Question 우선순위 검색 결과 정렬
- ✅ 키패드 내려도 검색어 유지 (버그 수정)

**가져오기/내보내기**
- ✅ .memk 가져오기 + 기존 폴더 선택 (다중 선택 + 새 폴더 만들기)
- ✅ 파일 만들기 (내보내기): .memk + PDF 형식
- ✅ 파일 목록 화면 (복원/내보내기/삭제)

**알림 & 잠금화면**
- ✅ 카드 푸시 알림 (ON/OFF, 요일, 시간, 폴더, 알림음)
- ✅ 잠금화면 카드 표시 (ON/OFF, 폴더, 정답옵션, 순서, 배경색)

**설정**
- ✅ 정답 접기 펼치기 기본값
- ✅ 정답 보이고 가리기 기본값
- ✅ 카드 위치 기억
- ✅ 카드 번호 표시
- ✅ 카드 목록 스크롤바
- ✅ 이미지 품질 (상/중/하)

**디자인**
- ✅ Coral Orange (#FF6B6B) 테마
- ✅ 다크모드 지원

### Out of Scope

**제거된 기능**
- ❌ 음성 녹음
- ❌ 손글씨 노트
- ❌ 웹에서 카드 생성 (QR/번호 전송)
- ❌ 엑셀 파일 가져오기
- ❌ 문제/정답 반전 (Q↔A 바꾸기)
- ❌ 별점/별 카드 시스템
- ❌ 암기중/암기완료 탭 & 상태 전환
- ❌ 테스트/퀴즈 모드
- ❌ 가로카드/세로카드 표시 모드
- ❌ 카드순서 변경 (↑↓ 버튼 화면)
- ❌ 글자 크기 조절
- ❌ 도움말 및 피드백
- ❌ 프리미엄/유료 기능
- ❌ 카드 플립 애니메이션

**추후 구현**
- ❌ 백업 및 복원 (Google Drive / Dropbox)

---

## 5. User Stories

### US-1: 카드 생성
> **As a** 학습자, **I want to** 폴더 안에서 FAB 버튼을 눌러 Question/Answer 텍스트와 이미지를 입력하여 카드를 만들고 싶다, **so that** 나만의 단어장을 구축할 수 있다.

**Example**: "영단어" 폴더에서 + 버튼 → "새 카드 추가" 화면 → Question: "winnow", Answer: "v-to blow the chaff..." + 이미지 첨부 → ✓ 저장

### US-2: 카드 검색 (Question 우선순위)
> **As a** 학습자, **I want to** 🔍 버튼을 눌러 "apple"을 검색하면 Question에 "apple"이 있는 카드가 먼저 나오고, Answer에만 "apple"이 있는 카드가 그 뒤에 나오길 원한다, **so that** 원하는 단어를 빠르게 찾을 수 있다.

**Example**: "apple" 검색 → 1순위: Question이 "apple"인 카드 → 2순위: Answer에 "apple"이 포함된 카드. 키패드를 내려도 검색어 "apple"과 결과가 유지됨.

### US-3: .memk 파일 가져오기 (폴더 선택)
> **As a** 학습자, **I want to** .memk 파일을 가져올 때 기존 폴더를 선택하여 카드를 넣고 싶다, **so that** 새 폴더가 무한히 생성되는 것을 방지하고 기존 폴더에 카드를 통합할 수 있다.

**Example**: + 버튼 → 파일(.memk) 가져오기 → cards(3).memk 선택 → 확인 → "영단어" 폴더 + "히라가나" 폴더 체크 → 가져오기 완료 (두 폴더에 카드 삽입)

### US-4: 정답 보이기/숨기기
> **As a** 학습자, **I want to** 카드 리스트에서 정답을 숨기고, 각 카드의 Answer를 터치하여 개별적으로 확인하고 싶다, **so that** 스스로 테스트하며 학습할 수 있다.

**Example**: ⋮ → "정답 보이기, 가리기" → "정답 가리기" 선택 → 모든 카드의 Answer가 숨겨짐 → 개별 Answer 터치 시 해당 카드만 정답 표시

### US-5: 묶음 폴더
> **As a** 학습자, **I want to** "영어"라는 묶음 폴더를 만들고 그 안에 "영단어", "영단어2" 폴더를 넣고 싶다, **so that** 과목별로 폴더를 정리할 수 있다.

**Example**: + 버튼 → 묶음 폴더 만들기 → 이름: "영어" → "영단어" ☑, "영단어2" ☑ 선택 → ✓ 저장

### US-6: 푸시 알림
> **As a** 학습자, **I want to** 매일 오후 12시와 8시에 "영단어" 폴더의 카드가 푸시 알림으로 오길 원한다, **so that** 일상 중에 자연스럽게 복습할 수 있다.

**Example**: 햄버거 메뉴 → 카드 푸시 알림 → 알림 ON → 월~금 선택 → 오후 12:00 [ON], 오후 8:00 [ON] → 폴더: 영단어 → 알림: "영단어 / ex convict (ex-con)" 형태로 도착, 탭하면 해당 카드로 이동

### US-7: 다중 선택 & 일괄 작업
> **As a** 학습자, **I want to** 카드 여러 개를 선택하여 한번에 삭제하거나 다른 폴더로 이동하고 싶다, **so that** 대량의 카드를 효율적으로 관리할 수 있다.

**Example**: 카드 롱프레스 → 다중 선택 모드 진입 → 5개 카드 체크 → 하단 액션바에서 "삭제" 또는 "이동" 선택

### US-8: 파일 내보내기
> **As a** 학습자, **I want to** 특정 폴더의 카드를 .memk 또는 PDF로 내보내고 싶다, **so that** 백업하거나 다른 사람과 공유할 수 있다.

**Example**: 폴더 ⋮ → 파일 만들기 → 폴더 선택: "영단어" ☑ → 파일 형식: memk → "파일 생성" → 파일 목록에서 확인 가능

---

## 6. Core Architecture & Patterns

### High-Level Architecture
```
┌──────────────────────────────────────────┐
│                 Flutter UI               │
│  (Material Design 3 + Coral Orange)      │
├──────────────────────────────────────────┤
│              Screen Layer                │
│  HomeScreen, CardListScreen,             │
│  CardEditScreen, ImportScreen, ...       │
├──────────────────────────────────────────┤
│             Service Layer                │
│  MemkImportService, MemkExportService,   │
│  NotificationService, LockScreenService  │
├──────────────────────────────────────────┤
│           Database Layer                 │
│  DatabaseHelper (Singleton, SQLite)      │
├──────────────────────────────────────────┤
│             Model Layer                  │
│  CardModel, Folder                       │
├──────────────────────────────────────────┤
│          Android Native                  │
│  Foreground Service (Lock Screen)        │
│  MethodChannel Bridge                    │
└──────────────────────────────────────────┘
```

### Directory Structure
```
lib/
├── main.dart
├── app.dart                          # MaterialApp, Theme, Routing
├── database/
│   └── database_helper.dart          # SQLite CRUD (Singleton)
├── models/
│   ├── card.dart                     # CardModel
│   └── folder.dart                   # Folder (+ bundle support)
├── screens/
│   ├── home_screen.dart              # 홈 (폴더 리스트, +버튼, 드로어)
│   ├── card_list_screen.dart         # 카드 리스트 (검색, 탭 동작, 다중선택)
│   ├── card_edit_screen.dart         # 카드 생성/편집
│   ├── import_screen.dart            # .memk 가져오기 (폴더 선택)
│   ├── export_screen.dart            # 파일 만들기 (내보내기)
│   ├── file_list_screen.dart         # 파일 목록
│   ├── bundle_folder_screen.dart     # 묶음 폴더 만들기
│   ├── push_notification_settings.dart
│   ├── lock_screen_settings.dart
│   └── settings_screen.dart
├── services/
│   ├── memk_import_service.dart
│   ├── memk_export_service.dart
│   ├── lock_screen_service.dart
│   └── notification_service.dart
├── widgets/
│   ├── card_tile.dart                # 카드 리스트 아이템
│   ├── folder_tile.dart              # 폴더 리스트 아이템
│   └── image_viewer.dart             # 이미지 전체화면 뷰어
└── utils/
    └── constants.dart                # 앱 상수
```

### Key Design Patterns
- **Singleton**: DatabaseHelper (lazy initialization)
- **StatefulWidget**: 모든 화면 (상태 관리)
- **Service Layer**: 비즈니스 로직을 Screen에서 분리
- **MethodChannel**: Flutter ↔ Android Native 통신 (잠금화면 서비스)
- **Batch Processing**: .memk 대량 가져오기 시 트랜잭션 기반 배치 처리

---

## 7. Features (상세 명세)

### 7.1 카드 리스트 뷰
**목적**: 폴더 내 카드를 리스트로 표시하고 학습/관리 기능 제공

**동작**:
- 각 카드: Question(굵은 글씨) + Answer(텍스트+이미지) + ⋮ 메뉴
- Question 탭 → Answer 영역이 AnimatedContainer로 접힘
- Answer 탭 → Answer 내용 (텍스트+이미지) Visibility 토글
- 페이지네이션: 50개씩 로딩

**⋮ 메뉴 옵션**:
| 옵션 | 동작 |
|------|------|
| 편집 | CardEditScreen으로 이동 |
| 삭제 | 확인 다이얼로그 → 삭제 |
| 카드 복제 | 동일 폴더에 카드 복사 |
| 다른 폴더로 이동 | 폴더 선택 다이얼로그 |

**정렬/필터 (⋮ 메뉴)**:
| 옵션 | 동작 |
|------|------|
| 카드 정렬 | 최신순/오래된순/가나다순/랜덤 |
| 정답 접고 펼치기 | 전체 Answer 영역 토글 |
| 정답 보이기, 가리기 | 정답 보이기 / 정답 가리기 (터치 확인) |

### 7.2 카드 검색
**목적**: 폴더 내 카드를 빠르게 찾기

**핵심 로직**:
```dart
// 검색 결과 정렬 우선순위
1. Question에 검색어가 포함된 카드 (상위)
2. Answer에 검색어가 포함된 카드 (하위)
// 각 그룹 내에서는 기존 정렬 순서 유지
```

**버그 수정**:
- TextEditingController의 값을 스크롤/키패드 이벤트와 독립적으로 유지
- FocusNode 해제 시에도 검색어와 필터 결과 보존

### 7.3 .memk 가져오기 (커스텀)
**목적**: .memk 파일의 카드를 기존 폴더에 삽입

**흐름**:
```
파일 피커 → 확인 다이얼로그 → 폴더 선택 (다중 체크박스 + 새 폴더) → 가져오기
```

**폴더 선택 UI**:
```
┌─────────────────────────┐
│ 폴더 선택                │
│                         │
│ ☐ 영단어_원본            │
│ ☑ 영단어                 │
│ ☐ 히라가나               │
│ ─────────────────────── │
│ + 새 폴더 만들기          │
│                         │
│      취소       확인     │
└─────────────────────────┘
```

### 7.4 다중 선택 & 일괄 작업
**목적**: 여러 카드를 효율적으로 관리

**진입**: 카드 롱프레스 → 다중 선택 모드 진입

**다중 선택 모드 UI** (암기짱 참고):
```
┌─────────────────────────────────┐
│ ← 1개 선택됨    카드 전체선택 ☐  │  ← 상단바 변경
├─────────────────────────────────┤
│                                 │
│  [선택된 카드: 하이라이트 표시]    │
│  [미선택 카드: 탭하여 추가 선택]   │
│                                 │
├─────────────────────────────────┤
│  🗑️ 삭제하기    📁 폴더 이동     │  ← 하단 액션바
└─────────────────────────────────┘
```

**동작**:
- 상단바: ← (뒤로/해제) + "N개 선택됨" + "카드 전체선택 ☐"
- 카드 탭: 선택/해제 토글
- 하단 액션바: **삭제하기** / **폴더 이동** (2개만)
- ← 또는 뒤로가기로 선택 모드 해제
- 제외: 카드 이동(암기중/완료), 별 설정

### 7.5 묶음 폴더
**목적**: 폴더를 그룹으로 묶어서 계층적 정리

**동작**:
- 묶음 폴더 이름 입력
- 기존 폴더 체크박스 선택
- 홈 화면에서 묶음 폴더 탭 → 하위 폴더 리스트 표시
- DB: `is_bundle` 플래그 + `parent_folder_id` 관계

### 7.6 파일 내보내기
**목적**: 카드를 .memk 또는 PDF로 내보내기

**지원 형식**:
| 형식 | 내용 |
|------|------|
| .memk | ZIP 파일 (folders.json, cards.json, counter.json, prefs.json + 이미지) |
| PDF | 텍스트 + 이미지 레이아웃 |

### 7.7 푸시 알림
**목적**: 정해진 시간에 카드를 알림으로 전송

**설정 항목**:
- 알림 ON/OFF
- 반복 요일 (일~토, 칩 선택)
- 시간 알람 (다중, 각각 ON/OFF, + 추가)
- 폴더 선택
- 알림음 ON/OFF

**알림 형태**: "[폴더명] / [Question 텍스트]" → 탭하면 해당 카드로 이동

### 7.8 잠금화면
**목적**: 잠금화면에서 카드 학습

**설정 항목**:
- 잠금화면 ON/OFF
- 폴더 선택 (다중)
- 정답 옵션 (보이기/가리기)
- 카드 순서 (기본/랜덤)
- 배경 색상 설정

**구현**: Android Foreground Service + Overlay Permission

---

## 8. Technology Stack

### Core
| 기술 | 버전 | 용도 |
|------|------|------|
| Flutter | ^3.11.1 | UI 프레임워크 |
| Dart | ^3.x | 프로그래밍 언어 |
| SQLite (sqflite) | latest | 로컬 데이터베이스 |
| Material Design 3 | built-in | UI 컴포넌트 |

### Dependencies (현재 pubspec.yaml 기반)
| 패키지 | 용도 |
|--------|------|
| sqflite | SQLite 데이터베이스 |
| image_picker | 카메라/갤러리 이미지 선택 |
| photo_view | 이미지 줌 뷰어 |
| archive | ZIP 압축/해제 (.memk) |
| file_picker | 파일 선택 (가져오기) |
| receive_sharing_intent | .memk 파일 공유 수신 |
| uuid | 고유 카드 ID 생성 |
| flutter_local_notifications | 푸시 알림 |
| permission_handler | 권한 요청 (오버레이 등) |

### 추가 필요 패키지
| 패키지 | 용도 |
|--------|------|
| pdf (또는 printing) | PDF 내보내기 |
| shared_preferences | 설정값 저장 (보조) |

### Android Native
- Foreground Service (잠금화면 카드 표시)
- MethodChannel (Flutter ↔ Native 통신)

---

## 9. Security & Configuration

### 권한 (Android)
| 권한 | 용도 | 필수 |
|------|------|------|
| CAMERA | 카드에 사진 첨부 | 선택 |
| READ_EXTERNAL_STORAGE | .memk 파일 읽기 | 선택 |
| WRITE_EXTERNAL_STORAGE | .memk/PDF 내보내기 | 선택 |
| SYSTEM_ALERT_WINDOW | 잠금화면 오버레이 | 선택 |
| FOREGROUND_SERVICE | 잠금화면 서비스 | 선택 |
| POST_NOTIFICATIONS | 푸시 알림 | 선택 |

### 데이터 보안
- 모든 데이터는 로컬 SQLite에 저장 (서버 전송 없음)
- 이미지는 앱 전용 디렉토리에 저장
- 클라우드 백업은 추후 구현 (MVP 범위 외)

### Configuration
- DB 이름: `amki_wang.db` 유지 (개인 프로젝트이므로 마이그레이션 불필요, 내부 DB명은 그대로 유지)
- 이미지 디렉토리: `images/`
- .memk 호환성: 암기짱 경로 프리픽스 유지 (`/data/user/0/com.metastudiolab.memorize/files/image/`)
- PDF 내보내기: `pdf` 패키지 사용 (Flutter 표준 PDF 생성 라이브러리)
- 빌드 환경: 한글 경로 이슈 → `/tmp/`에 복사 후 `C:\flutter\` SDK로 빌드

---

## 10. Database Schema

### folders 테이블
```sql
CREATE TABLE folders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  card_count INTEGER DEFAULT 0,
  sequence INTEGER DEFAULT 0,
  modified TEXT,
  parent_folder_id INTEGER,        -- 묶음 폴더 내 소속
  is_bundle INTEGER DEFAULT 0      -- 1이면 묶음 폴더
);
```

### cards 테이블
```sql
CREATE TABLE cards (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT UNIQUE NOT NULL,
  folder_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
  question TEXT DEFAULT '',
  answer TEXT DEFAULT '',
  -- 이미지 (앞면 최대 5장)
  question_image_path TEXT,
  question_image_path_2 TEXT,
  question_image_path_3 TEXT,
  question_image_path_4 TEXT,
  question_image_path_5 TEXT,
  -- 이미지 (뒷면 최대 5장)
  answer_image_path TEXT,
  answer_image_path_2 TEXT,
  answer_image_path_3 TEXT,
  answer_image_path_4 TEXT,
  answer_image_path_5 TEXT,
  -- 정렬
  sequence INTEGER DEFAULT 0,
  -- 메타데이터
  modified TEXT
);
```

### settings 테이블
```sql
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- Keys: answer_fold, answer_visibility, card_position_memory,
--        card_number, card_scroll, image_quality
```

### exported_files 테이블 (새로 추가)
```sql
CREATE TABLE exported_files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_name TEXT NOT NULL,
  file_path TEXT NOT NULL,
  file_size INTEGER,
  file_type TEXT,          -- 'memk' or 'pdf'
  created_at TEXT
);
```

### push_alarms 테이블 (새로 추가)
```sql
CREATE TABLE push_alarms (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  time TEXT NOT NULL,       -- 'HH:mm' format
  enabled INTEGER DEFAULT 1,
  folder_id INTEGER,
  days TEXT,                -- JSON array: [0,1,2,3,4,5,6] (일~토)
  sound_enabled INTEGER DEFAULT 1
);
```

---

## 11. Success Criteria

### MVP 성공 정의
사용자가 기존 암기짱 .memk 데이터를 Memora로 가져오고, 카드를 생성/관리/학습하며, 푸시 알림과 잠금화면으로 일상 학습을 할 수 있는 완성된 앱.

### Functional Requirements
- ✅ 카드 CRUD (텍스트 + 이미지 최대 5장)
- ✅ 폴더 CRUD + 묶음 폴더
- ✅ 카드 리스트 뷰: Question/Answer 탭 접기/숨기기
- ✅ 카드 검색: Question 우선순위 + 키패드 버그 수정
- ✅ .memk 가져오기: 기존 폴더 선택 (다중 + 새 폴더)
- ✅ .memk + PDF 내보내기
- ✅ 파일 목록 관리
- ✅ 다중 선택 & 일괄 작업
- ✅ 푸시 알림 (요일/시간/폴더/알림음)
- ✅ 잠금화면 (폴더/정답옵션/순서/배경색)
- ✅ 설정 화면 (6개 항목)
- ✅ Coral Orange 테마 + 다크모드

### Quality Indicators
- 10,000+ 카드에서 스크롤 끊김 없음 (페이지네이션)
- .memk 가져오기 시 데이터 무결성 보장 (UUID 기반 중복 방지)
- 검색 결과 즉시 반영 (디바운싱 적용)
- 앱 재시작 후 설정값 유지

### UX Goals
- 기존 암기짱 사용자가 3분 내에 주요 기능을 파악할 수 있는 직관적 UI
- 홈 → 폴더 → 카드 3단계 이내 접근
- 모든 액션에 시각적 피드백 (Snackbar, 로딩 인디케이터)

---

## 12. Implementation Phases

### Phase 1: 기반 작업 (앱 설정, 테마, 홈 화면)
**Goal**: 앱의 뼈대를 구축하고 홈 화면을 완성

**Deliverables**:
- ✅ 앱 이름 "Memora"로 변경, 패키지명 업데이트
- ✅ Coral Orange 테마 적용 (ColorScheme.fromSeed)
- ✅ 다크모드 ThemeData 설정
- ✅ DB 스키마 업데이트 (묶음 폴더, exported_files, push_alarms)
- ✅ 홈 화면 리뉴얼 (폴더 리스트, 전체 카드, 폴더 정렬)
- ✅ + 버튼 바텀시트 (카드/폴더/묶음폴더/memk 가져오기)
- ✅ 햄버거 메뉴 사이드 드로어 (통계, 메뉴 항목)
- ✅ 묶음 폴더 만들기 화면

**Validation**: 앱 빌드 성공, 홈 화면 표시, 폴더 CRUD 동작, 테마 적용 확인

### Phase 2: 카드 기능 (리스트, 편집, 검색, 다중선택)
**Goal**: 카드 관리의 핵심 기능 완성

**Deliverables**:
- ✅ 카드 리스트 리뉴얼 (탭 동작: Question접기, Answer숨기기)
- ✅ 카드 ⋮ 메뉴 (편집/삭제/복제/이동)
- ✅ 폴더 내 ⋮ 메뉴 (정렬, 정답 접기/보이기)
- ✅ 카드 편집 화면 리뉴얼 (📷만, 폴더 드롭다운 + 폴더 추가)
- ✅ 카드 검색 (Question 우선순위 + 키패드 버그 수정)
- ✅ 다중 선택 & 일괄 삭제/이동

**Validation**: 카드 CRUD 동작, 검색 우선순위 확인, 키패드 버그 수정 확인, 다중 선택 동작

### Phase 3: 가져오기/내보내기
**Goal**: .memk 호환성과 파일 관리 완성

**Deliverables**:
- ✅ .memk 가져오기 리뉴얼 (폴더 선택 다이얼로그)
- ✅ 파일 만들기 (내보내기: .memk + PDF, 폴더 다중 선택)
- ✅ 파일 목록 화면 (복원/내보내기/삭제)

**Validation**: .memk 가져오기 → 기존 폴더에 카드 삽입 확인, PDF 내보내기 확인, 파일 목록 동작

### Phase 4: 알림, 잠금화면, 설정 & 마무리
**Goal**: 부가 기능 완성 및 전체 테스트

**Deliverables**:
- ✅ 푸시 알림 설정 화면 (요일/시간/폴더/알림음)
- ✅ 잠금화면 설정 수정 & 동작 확인
- ✅ 설정 화면 (6개 항목)
- ✅ 다크모드 전체 화면 적용 확인
- ✅ 전체 테스트 & 버그 수정
- ✅ APK 빌드 & 배포 준비

**Validation**: 푸시 알림 수신 확인, 잠금화면 동작, 설정값 저장/복원, 다크모드 전환, 전체 E2E 테스트

---

## 13. Future Considerations

### Post-MVP
- **백업 및 복원**: Google Drive / Dropbox 클라우드 백업
- **TTS (음성 읽어주기)**: Question/Answer를 음성으로 읽기
- **홈화면 위젯**: 앱 열지 않고 카드 복습
- **폴더별 통계**: 카드 수, 최근 학습일 등
- **전체 검색**: 홈 화면에서 모든 폴더 카드를 한번에 검색
- **자동 백업**: 주기적 자동 백업
- **iOS 지원**: Flutter 크로스플랫폼 활용

### Integration Opportunities
- Google Drive API (클라우드 백업)
- TTS 엔진 (flutter_tts)
- 공유 기능 확장 (카카오톡 등)

---

## 14. Risks & Mitigations

### Risk 1: 한글 경로 빌드 이슈
- **위험**: `바탕 화면` 경로에서 Flutter 빌드 실패
- **완화**: `/tmp/`에 프로젝트 복사 후 빌드, 또는 영문 경로로 프로젝트 이동

### Risk 2: 대량 카드 성능
- **위험**: 10,000+ 카드에서 리스트 스크롤 성능 저하
- **완화**: 50개 단위 페이지네이션, 배치 로딩, ListView.builder lazy rendering

### Risk 3: .memk 호환성
- **위험**: 암기짱 .memk 형식 변경 시 가져오기 실패
- **완화**: 기존 import 로직 유지, 에러 핸들링 강화, 버전 체크

### Risk 4: Android 잠금화면 정책
- **위험**: Android 버전별 오버레이/포그라운드 서비스 제한
- **완화**: Android 버전별 분기 처리, 배터리 최적화 가이드 제공

### Risk 5: DB 스키마 변경
- **위험**: 기존 `amki_wang.db`에 새 테이블/컬럼 추가 시 기존 데이터와 충돌
- **완화**: SQLite `onUpgrade` 콜백에서 ALTER TABLE로 점진적 마이그레이션, DB 버전 번호 관리

---

## 15. Appendix

### 참조 앱
- **암기짱** (com.metastudiolab.memorize): 기능 기반 레퍼런스
- **Quizlet**: UI/UX 디자인 레퍼런스
- **FlashRecall**: 미니멀 디자인 레퍼런스

### 디자인 레퍼런스
- Figma: Snapdeck Flashcard App Mobile UI/UX Design
- 색상 팔레트: Coral Orange (#FF6B6B, #FFF5F5, #FFA8A8, #2D3436)
- Material Design 3 + ColorScheme.fromSeed()

### 프로젝트 경로
- 소스: `C:\Users\yhi55\OneDrive\바탕 화면\Python\project\amki_wang\`
- Flutter SDK: `C:\flutter\`
- 빌드 경로: `/tmp/amki_wang/` (한글 경로 우회)
