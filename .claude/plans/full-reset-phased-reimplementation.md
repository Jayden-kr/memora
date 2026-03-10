# Feature: 전체 앱 리셋 후 Phase별 재구현

The following plan should be complete, but its important that you validate documentation and codebase patterns and task sanity before you start implementing.

Pay special attention to naming of existing utils types and models. Import from the right files etc.

## Feature Description

Memora(구 암기왕) Flutter 앱을 **처음부터 다시 구현**한다. PRD에 정의된 4개 Phase를 순서대로 진행하며, 기존 코드의 검증된 패턴(Triple Serialization, DatabaseHelper Singleton, MethodChannel Bridge, Progress Callback)은 유지하되, PRD에 없는 불필요 화면(StudyScreen, CardViewScreen, CardFlipWidget)을 제거하고, 테마를 Coral Orange로 교체하며, PRD에 명시된 모든 기능을 구현한다.

## User Story

As a 자기주도 학습자
I want to 암기짱에서 마이그레이션한 카드를 Memora에서 더 편리하게 관리하고 학습하고 싶다
So that 직관적인 UI, 폴더 선택 가져오기, 다크모드, 잠금화면/푸시 알림으로 일상 학습을 할 수 있다

## Problem Statement

현재 코드는 Phase 1-2가 부분적으로 구현되어 있으나:
1. 테마가 PRD와 다름 (indigo → Coral Orange 필요)
2. 앱 이름이 `암기왕` (→ `Memora` 필요)
3. PRD에 없는 화면 존재 (StudyScreen, CardViewScreen, CardFlipWidget)
4. PRD에 있는 기능 미구현 (묶음 폴더, 다중 선택, PDF 내보내기, 설정 화면, 다크모드 등)
5. 홈 화면 구조가 PRD와 다름 (+ 버튼 바텀시트, 햄버거 드로어 없음)
6. 코드 일관성/품질 개선 필요

## Solution Statement

**전체 리셋 후 Phase별 순차 구현**:
- Phase 1: 기반 (테마, 홈, 폴더, 묶음 폴더, 드로어)
- Phase 2: 카드 (리스트 리뉴얼, 편집, 검색, 다중 선택)
- Phase 3: 가져오기/내보내기 (.memk 폴더 선택, PDF, 파일 목록)
- Phase 4: 알림, 잠금화면, 설정, 마무리

각 Phase 완료 후 빌드 & 검증한다.

## Feature Metadata

**Feature Type**: Full Reimplementation
**Estimated Complexity**: HIGH
**Primary Systems Affected**: 전체 (lib/, android/, test/)
**Dependencies**: 기존 pubspec.yaml 패키지 + pdf 패키지 추가 (Phase 3), shared_preferences (Phase 4)

---

## CONTEXT REFERENCES

### Relevant Codebase Files — MUST READ BEFORE IMPLEMENTING

**유지할 핵심 파일 (패턴 참조용)**:
- `lib/models/card.dart` — CardModel 100+ fields, Triple Serialization (fromJson/toJson/fromDb/toDb/copyWith). **이 파일은 그대로 유지**. .memk 호환 필드(voice, hand image 등)를 삭제하면 안 됨
- `lib/models/folder.dart` — Folder 모델. **그대로 유지하되** `is_bundle` 플래그 추가 필요 (PRD의 묶음 폴더)
- `lib/database/database_helper.dart` — Singleton, CRUD, 트랜잭션 패턴. **확장 필요** (exported_files, push_alarms 테이블, 새 쿼리 메소드)
- `lib/utils/constants.dart` — 상수 정의. **확장 필요** (새 테이블명, 설정 키)
- `lib/services/memk_import_service.dart` — Progress Callback 패턴, ZIP 처리. **수정 필요** (폴더 선택 로직 개선)
- `lib/services/memk_export_service.dart` — Export 로직. **확장 필요** (선택적 폴더 내보내기)
- `lib/services/lock_screen_service.dart` — MethodChannel 브릿지. **그대로 유지**
- `lib/services/notification_service.dart` — 기본 알림. **대폭 확장** (다중 시간, 요일, 폴더 선택)

**Android Native (유지)**:
- `android/app/src/main/kotlin/com/henry/amki_wang/MainActivity.kt` — MethodChannel 핸들러
- `android/app/src/main/kotlin/com/henry/amki_wang/LockScreenService.kt` — 잠금화면 Foreground Service (483 lines, 잘 동작함)
- `android/app/src/main/kotlin/com/henry/amki_wang/ScreenReceiver.kt`
- `android/app/src/main/kotlin/com/henry/amki_wang/LockScreenStartReceiver.kt`
- `android/app/src/main/AndroidManifest.xml`

**삭제할 파일** (PRD에 없음):
- `lib/screens/card_view_screen.dart` — PRD에 없는 단순 뷰어
- `lib/screens/study_screen.dart` — PRD에 없는 학습 모드
- `lib/widgets/card_flip_widget.dart` — PRD에 카드 플립 애니메이션 Out of Scope 명시

**참조 문서**:
- `PRD.md` — 전체 기능 명세, Phase 정의, DB 스키마, 화면 설계
- `CLAUDE.md` — 코드 패턴, 네이밍 컨벤션, 빌드 명령어
- `.claude/reference/amkizzang-apk-analysis.md` — 암기짱 APK 역공학 분석 (DB 스키마, 잠금화면 구현, .memk 처리)

### New Files to Create

**Phase 1**:
- `lib/screens/bundle_folder_screen.dart` — 묶음 폴더 만들기/편집 화면

**Phase 2**: (기존 파일 대폭 수정으로 대체)
- 없음 (card_list_screen, card_edit_screen 수정)

**Phase 3**:
- `lib/screens/export_screen.dart` — 파일 만들기 (내보내기) 화면
- `lib/screens/file_list_screen.dart` — 파일 목록 관리 화면
- `lib/services/pdf_export_service.dart` — PDF 내보내기 서비스

**Phase 4**:
- `lib/screens/push_notification_settings.dart` — 푸시 알림 설정 화면
- `lib/screens/settings_screen.dart` — 앱 설정 화면

### Patterns to Follow

**Naming Conventions** (CLAUDE.md 기반):
- 파일: `snake_case.dart`
- 클래스: `PascalCase`
- 변수/메소드: `camelCase`
- DB 컬럼: `snake_case`
- JSON 키: `camelCase`
- private: `_` prefix

**Model Serialization (Triple Pattern)**:
```dart
factory Model.fromJson(Map<String, dynamic> json)  // .memk JSON (camelCase)
Map<String, dynamic> toJson()
factory Model.fromDb(Map<String, dynamic> map)      // SQLite (snake_case)
Map<String, dynamic> toDb()
Model copyWith({...})
```

**Screen Widget Pattern**:
```dart
class XxxScreen extends StatefulWidget {
  final RequiredParam param;
  const XxxScreen({super.key, required this.param});
  @override State<XxxScreen> createState() => _XxxScreenState();
}
class _XxxScreenState extends State<XxxScreen> {
  bool _loading = true;
  @override void initState() { super.initState(); _loadData(); }
  @override void dispose() { /* cleanup */ super.dispose(); }
}
```

**Error Handling**:
```dart
try { await operation(); }
catch (e) {
  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('에러: $e')));
}
```

**Navigation**:
```dart
await Navigator.push(context, MaterialPageRoute(builder: (_) => NextScreen()));
_loadData();  // 돌아오면 리로드
```

**Dialog Pattern**:
```dart
final result = await showDialog<T>(context: context, builder: (ctx) => AlertDialog(...));
if (result == null) return;
```

---

## IMPLEMENTATION PLAN

### Phase 1: 기반 작업 (앱 설정, 테마, 홈 화면)

**Goal**: 앱의 뼈대를 구축하고 홈 화면을 완성

**Scope**:
- 앱 이름 "Memora"로 변경
- Coral Orange 테마 + 다크모드
- DB 스키마 업데이트 (묶음 폴더 is_bundle)
- 홈 화면 리뉴얼 (폴더 리스트, 전체 카드, 폴더 정렬, +버튼 바텀시트, 햄버거 드로어)
- 묶음 폴더 만들기 화면
- 불필요 파일 삭제

### Phase 2: 카드 기능 (리스트, 편집, 검색, 다중선택)

**Goal**: 카드 관리의 핵심 기능 완성

**Scope**:
- 카드 리스트 리뉴얼 (Question 탭→접기, Answer 탭→숨기기)
- 카드 ⋮ 메뉴 (편집/삭제/복제/이동)
- 폴더 내 ⋮ 메뉴 (정렬, 정답 접기/보이기)
- 카드 편집 화면 리뉴얼
- 카드 검색 (Question 우선순위 + 키패드 버그 수정)
- 다중 선택 & 일괄 삭제/이동

### Phase 3: 가져오기/내보내기

**Goal**: .memk 호환성과 파일 관리 완성

**Scope**:
- .memk 가져오기 리뉴얼 (폴더 선택 다이얼로그)
- 파일 만들기 (내보내기: .memk + PDF, 폴더 다중 선택)
- 파일 목록 화면 (복원/내보내기/삭제)

### Phase 4: 알림, 잠금화면, 설정 & 마무리

**Goal**: 부가 기능 완성 및 전체 테스트

**Scope**:
- 푸시 알림 설정 화면 (요일/시간/폴더/알림음)
- 잠금화면 설정 수정 & 동작 확인
- 설정 화면 (6개 항목)
- 다크모드 전체 화면 적용 확인
- 전체 테스트 & 버그 수정

---

## STEP-BY-STEP TASKS

> IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable.
> 각 Phase 완료 후 반드시 빌드 검증할 것.

---

## PHASE 1: 기반 작업

### Task 1.1: DELETE 불필요 파일

- **REMOVE**: `lib/screens/card_view_screen.dart`
- **REMOVE**: `lib/screens/study_screen.dart`
- **REMOVE**: `lib/widgets/card_flip_widget.dart`
- **REMOVE**: `card_list_screen.dart`에서 StudyScreen/CardViewScreen import 및 참조 제거
- **GOTCHA**: 삭제 전 다른 파일에서 이 파일들을 import하는지 grep으로 확인
- **VALIDATE**: `grep -r "study_screen\|card_view_screen\|card_flip_widget" lib/` → 결과 없음

### Task 1.2: UPDATE `lib/app.dart` — 테마 & 앱 이름

- **IMPLEMENT**:
  ```dart
  class MemoraApp extends StatelessWidget {
    @override
    Widget build(BuildContext context) {
      return MaterialApp(
        title: 'Memora',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFFFF6B6B),  // Coral Orange
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFFFF6B6B),
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        themeMode: ThemeMode.system,  // 시스템 설정 따름
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      );
    }
  }
  ```
- **PATTERN**: 기존 `app.dart` 구조 유지, 클래스명 `AmkiWangApp` → `MemoraApp`
- **VALIDATE**: 빌드 성공 확인

### Task 1.3: UPDATE `lib/main.dart` — 앱 클래스 이름 변경

- **IMPLEMENT**: `AmkiWangApp` → `MemoraApp` 변경
- **IMPORTS**: `app.dart` import 유지
- **VALIDATE**: 컴파일 에러 없음

### Task 1.4: UPDATE `lib/utils/constants.dart` — 새 상수 추가

- **IMPLEMENT**:
  ```dart
  class AppConstants {
    // 기존 상수 유지

    // 새 테이블
    static const String tableExportedFiles = 'exported_files';
    static const String tablePushAlarms = 'push_alarms';

    // 설정 키
    static const String settingAnswerFold = 'answer_fold';           // 'expanded' | 'collapsed'
    static const String settingAnswerVisibility = 'answer_visibility'; // 'visible' | 'hidden'
    static const String settingCardPositionMemory = 'card_position_memory'; // 'true' | 'false'
    static const String settingCardNumber = 'card_number';           // 'true' | 'false'
    static const String settingCardScroll = 'card_scroll';           // 'true' | 'false'
    static const String settingImageQuality = 'image_quality';       // 'high' | 'medium' | 'low'
    static const String settingThemeMode = 'theme_mode';             // 'system' | 'light' | 'dark'

    // 내보내기 디렉토리
    static const String exportDir = 'exports';
  }
  ```
- **VALIDATE**: `flutter analyze` 경고 없음

### Task 1.5: UPDATE `lib/models/folder.dart` — is_bundle 필드 추가

- **IMPLEMENT**:
  - `isBundle` (bool) 필드 추가 (default: false)
  - `fromJson()`: `json['isBundle']` 파싱 (bool/int)
  - `toJson()`: `'isBundle': isBundle`
  - `fromDb()`: `(map['is_bundle'] as int? ?? 0) == 1`
  - `toDb()`: `'is_bundle': isBundle ? 1 : 0`
  - `copyWith()`: `isBundle` 파라미터 추가
- **PATTERN**: 기존 `isSpecialFolder` 필드와 동일한 패턴 (bool ↔ int 변환)
- **GOTCHA**: 기존 `parent` 필드는 유지 (암기짱 호환). `isBundle`은 Memora 전용 묶음 폴더 플래그
- **VALIDATE**: 기존 테스트 + 새 필드 round-trip 테스트

### Task 1.6: UPDATE `lib/database/database_helper.dart` — 스키마 확장

- **IMPLEMENT**:
  1. `dbVersion` 2로 업데이트 (`constants.dart`에서)
  2. `_createDB()`에 `is_bundle` 컬럼 추가 (folders 테이블)
  3. `_createDB()`에 `exported_files` 테이블 추가:
     ```sql
     CREATE TABLE exported_files (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       file_name TEXT NOT NULL,
       file_path TEXT NOT NULL,
       file_size INTEGER,
       file_type TEXT,
       created_at TEXT
     );
     ```
  4. `_createDB()`에 `push_alarms` 테이블 추가:
     ```sql
     CREATE TABLE push_alarms (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       time TEXT NOT NULL,
       enabled INTEGER DEFAULT 1,
       folder_id INTEGER,
       days TEXT,
       sound_enabled INTEGER DEFAULT 1
     );
     ```
  5. `onUpgrade` 콜백 추가 (version 1→2 마이그레이션):
     ```dart
     onUpgrade: (db, oldVersion, newVersion) async {
       if (oldVersion < 2) {
         await db.execute('ALTER TABLE folders ADD COLUMN is_bundle INTEGER NOT NULL DEFAULT 0');
         await db.execute('CREATE TABLE IF NOT EXISTS exported_files (...)');
         await db.execute('CREATE TABLE IF NOT EXISTS push_alarms (...)');
       }
     },
     ```
  6. 새 CRUD 메소드:
     - `getBundleFolders()` — `WHERE is_bundle = 1`
     - `getNonBundleFolders()` — `WHERE is_bundle = 0`
     - `getChildFolders(int parentId)` — `WHERE parent_folder_id = ?`
     - `insertExportedFile(...)`, `getAllExportedFiles()`, `deleteExportedFile(int id)`
     - `insertPushAlarm(...)`, `getAllPushAlarms()`, `updatePushAlarm(...)`, `deletePushAlarm(int id)`
- **PATTERN**: 기존 CRUD 패턴 (async, db.query/insert/update/delete)
- **GOTCHA**: `onUpgrade`에서 `ALTER TABLE`은 DEFAULT 값 필수. `CREATE TABLE IF NOT EXISTS` 사용
- **VALIDATE**: 앱 실행 후 DB 테이블 생성 확인 (로그)

### Task 1.7: REWRITE `lib/screens/home_screen.dart` — 홈 화면 리뉴얼

PRD Section 7 참조. 현재 홈 화면을 완전히 리뉴얼.

- **IMPLEMENT**:
  1. **AppBar**:
     - 좌측: 햄버거 메뉴 (Drawer)
     - 중앙: "Memora"
     - 우측: 없음 (기존 PopupMenuButton 제거)

  2. **Drawer (햄버거 메뉴)**:
     ```
     ┌───────────────────────┐
     │  Memora               │  ← DrawerHeader (Coral Orange 배경)
     │  카드 N장 · 폴더 N개   │
     ├───────────────────────┤
     │  📂 전체 카드 보기     │  → CardListScreen(allCards: true)
     │  📥 카드 푸시 알림     │  → PushNotificationSettings (Phase 4)
     │  🔒 잠금화면 설정     │  → LockScreenSettings
     │  ⚙ 설정              │  → SettingsScreen (Phase 4)
     │  ───────────────────  │
     │  📤 파일 만들기       │  → ExportScreen (Phase 3)
     │  📋 파일 목록         │  → FileListScreen (Phase 3)
     └───────────────────────┘
     ```
     - Phase 3/4 메뉴는 placeholder로 Snackbar("준비 중") 표시

  3. **Body (폴더 리스트)**:
     - `ListView.builder` — 묶음 폴더 + 일반 폴더
     - 묶음 폴더: 아이콘 다르게 (folder_special), 탭 시 하위 폴더 리스트
     - 일반 폴더: 탭 시 CardListScreen
     - 롱프레스: 바텀시트 (파일 만들기 / 편집 / 삭제)
     - 폴더 정렬: AppBar에 정렬 아이콘 (가나다순/오래된순/최신순/수동)

  4. **FAB (+버튼) → 바텀시트**:
     ```
     ┌───────────────────────┐
     │  📝 새 카드 추가       │  → CardEditScreen (Phase 2에서 구현, 일단 placeholder)
     │  📁 새 폴더 만들기     │  → 폴더 생성 다이얼로그
     │  📦 묶음 폴더 만들기   │  → BundleFolderScreen
     │  📥 파일(.memk) 가져오기│  → 파일 피커 → ImportScreen
     └───────────────────────┘
     ```

  5. **폴더 정렬 구현**:
     - 가나다순: `ORDER BY name ASC`
     - 오래된순: `ORDER BY id ASC`
     - 최신순: `ORDER BY id DESC`
     - 수동(드래그): `ORDER BY sequence ASC` (기본값)
     - 롱터치 드래그: `ReorderableListView` 사용

  6. **전체 카드 보기**: 모든 폴더의 카드를 한 리스트에 표시 (CardListScreen에 allCards 모드 추가 — Phase 2에서 구현)

- **IMPORTS**: DatabaseHelper, Folder, FolderTile, CardListScreen, ImportScreen, LockScreenSettingsScreen, BundleFolderScreen
- **GOTCHA**:
  - `receive_sharing_intent` 로직 유지 (Intent로 .memk 수신)
  - Phase 3/4 화면은 아직 없으므로 placeholder 처리
  - `ReorderableListView`는 Flutter built-in (추가 패키지 불필요)
- **VALIDATE**: 앱 실행 → 홈 화면 표시, 폴더 CRUD 동작, 드로어 열림, FAB 바텀시트 동작

### Task 1.8: UPDATE `lib/widgets/folder_tile.dart` — 묶음 폴더 구분

- **IMPLEMENT**:
  - `isBundle` prop 추가
  - 묶음 폴더: `Icons.folder_special` + 하위 폴더 수 표시
  - 일반 폴더: `Icons.folder` + 카드 수 표시
  - trailing에 ⋮ 메뉴 (PopupMenuButton): 파일 만들기 / 편집 / 삭제
- **PATTERN**: 기존 `folder_tile.dart` 확장
- **VALIDATE**: 묶음 폴더와 일반 폴더가 시각적으로 구분됨

### Task 1.9: CREATE `lib/screens/bundle_folder_screen.dart` — 묶음 폴더

PRD Section 7.5 참조.

- **IMPLEMENT**:
  ```
  ┌─────────────────────────┐
  │ ← 묶음 폴더 만들기    ✓  │
  ├─────────────────────────┤
  │ 묶음 이름: [TextField]    │
  │                          │
  │ 포함할 폴더 선택:         │
  │ ☐ 영단어 (123장)         │
  │ ☑ 히라가나 (45장)        │
  │ ☐ 한자 (67장)            │
  └─────────────────────────┘
  ```
  - 묶음 이름 입력 (필수)
  - 기존 일반 폴더 목록 체크박스
  - 저장 시:
    1. 묶음 폴더 INSERT (`is_bundle = 1`)
    2. 선택된 폴더의 `parent_folder_id` = 묶음 폴더 ID로 UPDATE
  - 편집 모드: 기존 묶음 폴더 수정 (이름 변경, 폴더 추가/제거)

- **PATTERN**: StatefulWidget, DatabaseHelper 직접 호출
- **GOTCHA**: 이미 다른 묶음에 속한 폴더는 선택 불가 표시 (또는 이동 허용)
- **VALIDATE**: 묶음 폴더 생성 → 홈 화면에 표시 → 탭 시 하위 폴더 리스트

### Task 1.10: Phase 1 빌드 & 검증

- **VALIDATE**:
  ```bash
  # /tmp/에 복사 후 빌드
  rm -rf /tmp/amki_wang && cp -r . /tmp/amki_wang && cd /tmp/amki_wang
  C:/flutter/bin/flutter analyze
  C:/flutter/bin/flutter test
  C:/flutter/bin/flutter build apk --debug
  ```
- **ACCEPTANCE**:
  - [ ] 앱 이름 "Memora" 표시
  - [ ] Coral Orange 테마 적용
  - [ ] 다크모드 전환 동작
  - [ ] 폴더 CRUD (생성/이름변경/삭제)
  - [ ] 묶음 폴더 생성 & 하위 폴더 표시
  - [ ] FAB 바텀시트 (4개 옵션)
  - [ ] 햄버거 드로어 (메뉴 항목)
  - [ ] 폴더 정렬 (4가지)
  - [ ] .memk Intent 수신

---

## PHASE 2: 카드 기능

### Task 2.1: REWRITE `lib/screens/card_list_screen.dart` — 카드 리스트 리뉴얼

PRD Section 7.1, 7.2, 7.4 참조.

- **IMPLEMENT**:
  1. **카드 리스트 아이템 구조**:
     ```
     ┌─────────────────────────────┐
     │ Question (굵은 글씨)     ⋮  │  ← Question 탭 → Answer 영역 접기/펼치기
     │ ─────────────────────────── │
     │ Answer 텍스트               │  ← Answer 탭 → 텍스트+이미지 숨기기/보이기
     │ [이미지 썸네일들]            │
     └─────────────────────────────┘
     ```

  2. **탭 동작** (PRD 핵심):
     - **Question 영역 탭**: Answer 전체 영역 `AnimatedContainer`로 접기/펼치기 (높이 0 ↔ auto)
     - **Answer 영역 탭**: Answer 내용(텍스트+이미지)의 `Visibility` 토글 (가려짐 ↔ 보임)
     - 이 두 동작은 독립적

  3. **⋮ 메뉴 (개별 카드)**:
     - 편집 → CardEditScreen
     - 삭제 → 확인 다이얼로그
     - 카드 복제 → 같은 폴더에 복사 (새 UUID)
     - 다른 폴더로 이동 → 폴더 선택 다이얼로그

  4. **AppBar ⋮ 메뉴 (폴더 수준)**:
     - 카드 정렬: 최신순/오래된순/가나다순/랜덤
     - 정답 접고 펼치기: 전체 Answer 영역 토글
     - 정답 보이기, 가리기: 전체 Answer 내용 토글 (가린 상태에서 개별 터치로 확인)

  5. **페이지네이션**: 50개씩 무한 스크롤 (기존 패턴 유지)

  6. **전체 카드 모드**: `allCards` 파라미터로 모든 폴더 카드 표시
     - `DatabaseHelper.getAllCards()` 사용
     - 폴더명 표시 추가

- **STATE 변수**:
  ```dart
  bool _allAnswersFolded = false;     // 전체 접기 상태
  bool _allAnswersHidden = false;     // 전체 숨기기 상태
  Set<int> _foldedCards = {};         // 개별 접힌 카드 ID
  Set<int> _revealedCards = {};       // 개별 공개된 카드 ID (숨김 모드에서)
  String _sortOrder = 'sequence';     // 정렬 기준
  bool _isSelectionMode = false;      // 다중 선택 모드
  Set<int> _selectedCardIds = {};     // 선택된 카드 ID
  ```

- **PATTERN**: ScrollController 기반 pagination (기존), AnimatedContainer/Visibility (신규)
- **GOTCHA**:
  - `_allAnswersHidden = true`일 때 개별 Answer 탭 → 해당 카드만 `_revealedCards`에 추가
  - 랜덤 정렬 시 페이지네이션 주의 (전체 로드 후 shuffle, 또는 SQL RANDOM())
- **VALIDATE**: 카드 리스트 표시, Question/Answer 탭 동작, 정렬, 페이지네이션

### Task 2.2: UPDATE `lib/widgets/card_tile.dart` — 카드 타일 리뉴얼

- **IMPLEMENT**:
  - 기존 Dismissible 제거 (다중 선택으로 대체)
  - Question (굵은 글씨) + ⋮ 메뉴
  - Answer 영역 (AnimatedContainer 접기)
  - Answer 내용 (Visibility 숨기기)
  - 이미지 썸네일 (가로 스크롤)
  - 선택 모드: 체크박스 표시
  - `onQuestionTap`, `onAnswerTap`, `onMenuAction` 콜백
- **PATTERN**: StatelessWidget → StatefulWidget (애니메이션 때문에)
- **VALIDATE**: 탭 동작 정상

### Task 2.3: UPDATE `lib/screens/card_edit_screen.dart` — 카드 편집 리뉴얼

PRD 기준 변경사항:
- **IMPLEMENT**:
  1. 상단: 폴더 드롭다운 (현재 폴더 + 변경 가능) + 폴더 추가 버튼
  2. Question TextField + 이미지 추가 버튼 (📷 카메라만, PRD에 갤러리 없음 → **확인 필요: PRD에 image_picker 있으니 갤러리도 포함**)
  3. Answer TextField + 이미지 추가 버튼
  4. 이미지 관리: 최대 5장/면, 썸네일 + 삭제 버튼
  5. 저장/취소 버튼

- **PATTERN**: 기존 `card_edit_screen.dart` 구조 유지하되 UI 개선
- **GOTCHA**:
  - 이미지는 카메라 + 갤러리 모두 지원 (image_picker)
  - 이미지 경로는 앱 docs 디렉토리에 UUID 기반 저장
  - 기존 이미지 처리 로직 재사용
- **VALIDATE**: 카드 생성/편집 → 저장 → 리스트에 표시

### Task 2.4: IMPLEMENT 카드 검색 — `card_list_screen.dart`

PRD Section 7.2 참조.

- **IMPLEMENT**:
  1. AppBar에 🔍 아이콘 → SearchBar 토글
  2. 검색 로직:
     ```dart
     // Question 우선순위 검색
     Future<List<CardModel>> searchCards(int folderId, String query) async {
       final db = await database;
       // Question에 포함된 카드 (1순위)
       final questionMatches = await db.query(tableCards,
         where: 'folder_id = ? AND question LIKE ?',
         whereArgs: [folderId, '%$query%'],
         orderBy: 'sequence ASC');
       // Answer에만 포함된 카드 (2순위)
       final answerMatches = await db.query(tableCards,
         where: 'folder_id = ? AND answer LIKE ? AND question NOT LIKE ?',
         whereArgs: [folderId, '%$query%', '%$query%'],
         orderBy: 'sequence ASC');
       return [...questionMatches.map(CardModel.fromDb), ...answerMatches.map(CardModel.fromDb)];
     }
     ```
  3. **키패드 버그 수정**:
     - `TextEditingController` 값을 FocusNode 해제와 독립적으로 유지
     - `onTapOutside` 시 `FocusNode.unfocus()` 만 호출, 검색어는 유지
  4. 디바운싱: 300ms Timer

- **ADD**: `DatabaseHelper`에 `searchCards()` 메소드 추가
- **GOTCHA**: FocusNode 해제 시 controller.text 초기화하지 않기
- **VALIDATE**: "apple" 검색 → Question 매치 우선 → 키패드 내려도 검색어 유지

### Task 2.5: IMPLEMENT 다중 선택 — `card_list_screen.dart`

PRD Section 7.4 참조.

- **IMPLEMENT**:
  1. **진입**: 카드 롱프레스 → `_isSelectionMode = true`
  2. **AppBar 변경**: `← N개 선택됨` + `카드 전체선택 ☐`
  3. **카드 탭**: 선택/해제 토글 (체크박스)
  4. **하단 액션바** (BottomAppBar):
     - 🗑️ 삭제하기 → 확인 다이얼로그 → batch delete
     - 📁 폴더 이동 → 폴더 선택 다이얼로그 → batch move
  5. **뒤로가기/←**: 선택 모드 해제

- **PATTERN**:
  ```dart
  // 선택 모드 AppBar
  AppBar(
    leading: IconButton(icon: Icon(Icons.close), onPressed: _exitSelectionMode),
    title: Text('${_selectedCardIds.length}개 선택됨'),
    actions: [
      Row(children: [
        Text('카드 전체선택'),
        Checkbox(value: _isAllSelected, onChanged: _toggleSelectAll),
      ]),
    ],
  )
  ```
- **GOTCHA**:
  - 삭제 후 `updateFolderCardCount()` 호출
  - 이동 후 원래 폴더 + 대상 폴더 모두 `updateFolderCardCount()`
  - WillPopScope/PopScope로 뒤로가기 처리
- **VALIDATE**: 롱프레스 → 선택 모드 → 3개 선택 → 삭제 → 카드 수 업데이트

### Task 2.6: UPDATE `lib/database/database_helper.dart` — Phase 2 메소드 추가

- **ADD**:
  ```dart
  // 검색 (Question 우선순위)
  Future<List<CardModel>> searchCards(int folderId, String query) async { ... }

  // 전체 카드 검색 (allCards 모드)
  Future<List<CardModel>> searchAllCards(String query) async { ... }

  // 배치 삭제
  Future<int> deleteCardsBatch(List<int> cardIds) async { ... }

  // 배치 이동
  Future<void> moveCardsBatch(List<int> cardIds, int newFolderId) async { ... }

  // 카드 복제
  Future<int> duplicateCard(int cardId) async { ... }

  // 정렬 옵션
  Future<List<CardModel>> getCardsByFolderIdSorted(int folderId, String sortBy, {int? limit, int? offset}) async { ... }
  ```
- **VALIDATE**: 각 메소드 단위 테스트

### Task 2.7: Phase 2 빌드 & 검증

- **VALIDATE**:
  ```bash
  rm -rf /tmp/amki_wang && cp -r . /tmp/amki_wang && cd /tmp/amki_wang
  C:/flutter/bin/flutter analyze
  C:/flutter/bin/flutter test
  C:/flutter/bin/flutter build apk --debug
  ```
- **ACCEPTANCE**:
  - [ ] 카드 리스트: Question 탭 → 접기, Answer 탭 → 숨기기
  - [ ] 카드 ⋮ 메뉴: 편집/삭제/복제/이동
  - [ ] 폴더 ⋮ 메뉴: 정렬, 정답 접기/보이기
  - [ ] 카드 편집: 이미지 5장, 폴더 드롭다운
  - [ ] 검색: Question 우선순위, 키패드 버그 수정
  - [ ] 다중 선택: 롱프레스 → 선택 → 삭제/이동

---

## PHASE 3: 가져오기/내보내기

### Task 3.1: UPDATE `lib/screens/import_screen.dart` — 폴더 선택 리뉴얼

PRD Section 7.3 참조.

- **IMPLEMENT**:
  기존 ImportScreen 수정:
  1. 분석 후 폴더 선택 UI:
     ```
     ┌─────────────────────────┐
     │ .memk 폴더 선택          │
     │                         │
     │ ─── .memk 내부 폴더 ──── │
     │ ☑ 영단어_원본 (50장)     │
     │ ☐ 히라가나 (30장)        │
     │                         │
     │ ─── 가져올 위치 ──────── │
     │ ○ 새 폴더 자동 생성      │  ← 기존 동작
     │ ● 기존 폴더 선택         │  ← 신규
     │                         │
     │ [기존 폴더 선택 드롭다운]  │
     │ ☑ 영단어                 │
     │ ☐ 한자                   │
     │ + 새 폴더 만들기          │
     │                         │
     │      취소       가져오기  │
     └─────────────────────────┘
     ```
  2. 기존 폴더에 카드 삽입 시 `folderIdMap`에서 .memk 폴더 ID → 선택된 기존 폴더 ID로 매핑
  3. 여러 .memk 폴더 → 하나의 기존 폴더에 병합 가능

- **PATTERN**: 기존 ImportScreen 스테이지 패턴 유지 (loading → folderSelect → importing → done)
- **GOTCHA**:
  - 기존 폴더에 삽입 시 UUID 중복 → `ConflictAlgorithm.replace`로 덮어쓰기 (기존 동작)
  - 새 폴더 만들기 → inline TextField + 생성 → 목록에 추가
- **VALIDATE**: .memk 가져오기 → 기존 "영단어" 폴더에 카드 삽입 확인

### Task 3.2: UPDATE `lib/services/memk_import_service.dart` — 폴더 매핑 개선

- **IMPLEMENT**:
  - `importSelectedFolders()` 파라미터에 `Map<int, int>? folderMapping` 추가
    - key: .memk 내부 폴더 ID, value: 로컬 폴더 ID
    - null이면 기존 동작 (자동 생성)
  - 매핑이 있으면 해당 폴더에 카드 삽입 (새 폴더 생성 스킵)
  - `updateFolderCardCount()` 호출

- **VALIDATE**: 매핑 모드 + 자동 생성 모드 둘 다 동작

### Task 3.3: UPDATE `lib/services/memk_export_service.dart` — 선택적 폴더 내보내기

- **IMPLEMENT**:
  - `exportMemk()` 파라미터에 `List<int>? folderIds` 추가
  - null이면 전체 내보내기 (기존 동작)
  - 있으면 해당 폴더 + 소속 카드만 내보내기
  - 결과 파일 정보를 `exported_files` 테이블에 저장

- **VALIDATE**: 특정 폴더만 내보내기 → .memk 파일에 해당 폴더만 포함

### Task 3.4: CREATE `lib/services/pdf_export_service.dart` — PDF 내보내기

- **IMPLEMENT**:
  - `pdf` 패키지 사용 (pubspec.yaml에 추가)
  - 폴더별 페이지 구성
  - 카드: Question (굵은 글씨) + Answer + 이미지
  - A4 세로 레이아웃
  - 한글 폰트 지원 필요 (Google Fonts 또는 NotoSansKR 번들)
  - Progress callback 패턴

- **IMPORTS**: `package:pdf/pdf.dart`, `package:pdf/widgets.dart`
- **GOTCHA**:
  - Flutter pdf 패키지는 `pw.Document`, `pw.Page`, `pw.Text` 등 사용
  - 이미지는 `pw.MemoryImage` 또는 `pw.Image` (File → bytes)
  - 한글 깨짐 방지: TTF 폰트 로딩 필수
- **VALIDATE**: PDF 내보내기 → 파일 열어서 한글/이미지 확인

### Task 3.5: CREATE `lib/screens/export_screen.dart` — 파일 만들기 화면

PRD Section 7.6 참조.

- **IMPLEMENT**:
  ```
  ┌────────────────────────────┐
  │ ← 파일 만들기           생성 │
  ├────────────────────────────┤
  │ 폴더 선택:                  │
  │ ☑ 영단어 (123장)           │
  │ ☐ 히라가나 (45장)          │
  │ ☑ 한자 (67장)              │
  │                            │
  │ 파일 형식:                  │
  │ ● .memk  ○ PDF             │
  │                            │
  │ [진행률 표시]                │
  └────────────────────────────┘
  ```
  - 폴더 다중 선택 체크박스
  - 형식 선택 (Radio)
  - 생성 버튼 → 내보내기 서비스 호출
  - 완료 후 파일 목록으로 이동 또는 공유

- **VALIDATE**: .memk + PDF 내보내기 → 파일 생성 확인

### Task 3.6: CREATE `lib/screens/file_list_screen.dart` — 파일 목록 화면

- **IMPLEMENT**:
  - `exported_files` 테이블에서 파일 목록 로드
  - 각 항목: 파일명, 크기, 날짜, 형식 아이콘
  - 액션:
    - 공유 (Share intent)
    - 삭제 (파일 + DB 레코드)
    - .memk 파일 복원 (ImportScreen으로 이동)

- **VALIDATE**: 파일 목록 표시, 공유/삭제 동작

### Task 3.7: Phase 3 빌드 & 검증

- **VALIDATE**: 빌드 + 테스트
- **ACCEPTANCE**:
  - [ ] .memk 가져오기: 기존 폴더 선택 가능
  - [ ] .memk 내보내기: 폴더 선택적 내보내기
  - [ ] PDF 내보내기: 한글 + 이미지 정상
  - [ ] 파일 목록: 목록 표시, 공유/삭제/복원

---

## PHASE 4: 알림, 잠금화면, 설정 & 마무리

### Task 4.1: CREATE `lib/screens/push_notification_settings.dart` — 푸시 알림 설정

PRD Section 7.7 참조.

- **IMPLEMENT**:
  ```
  ┌────────────────────────────┐
  │ ← 카드 푸시 알림            │
  ├────────────────────────────┤
  │ 알림 [ON/OFF 스위치]        │
  │                            │
  │ 반복 요일:                  │
  │ [일][월][화][수][목][금][토] │  ← ChoiceChip
  │                            │
  │ 시간 알람:                  │
  │ ┌──────────────────────┐   │
  │ │ 오후 12:00    [ON] 🗑 │   │
  │ │ 오후 8:00     [ON] 🗑 │   │
  │ │ + 알람 추가           │   │
  │ └──────────────────────┘   │
  │                            │
  │ 폴더: [영단어 ▼]            │  ← 드롭다운
  │                            │
  │ 알림음 [ON/OFF 스위치]       │
  └────────────────────────────┘
  ```
  - `push_alarms` 테이블 CRUD
  - 각 시간 알람: 개별 ON/OFF + 삭제
  - 알람 추가: TimePicker 다이얼로그
  - 폴더 선택: 드롭다운
  - 저장 시 `flutter_local_notifications`으로 스케줄링

- **PATTERN**: 기존 `notification_service.dart` 확장
- **GOTCHA**:
  - 여러 시간대 알림 → 각각 고유 notification ID
  - 요일 필터: 월~금만 선택 가능
  - 앱 재시작 시 알람 복원 (BOOT_COMPLETED)
- **VALIDATE**: 알림 설정 → 지정 시간에 알림 수신

### Task 4.2: UPDATE `lib/services/notification_service.dart` — 다중 알림 지원

- **IMPLEMENT**:
  - `scheduleMultipleAlarms(List<PushAlarm> alarms)`: 여러 시간대 스케줄링
  - `cancelAllAlarms()`: 전체 취소
  - `cancelAlarm(int alarmId)`: 개별 취소
  - 알림 탭 시 해당 카드/폴더로 이동 (payload)
  - 알림 형태: "[폴더명] / [Question]"

- **VALIDATE**: 다중 시간 알림 스케줄링 + 취소

### Task 4.3: UPDATE `lib/screens/lock_screen_settings.dart` — 설정 화면 개선

- **IMPLEMENT**:
  - 기존 구조 유지하되 PRD UI에 맞게 개선
  - 배경 색상 6개 프리셋 (기존 유지)
  - 폴더 다중 선택 (기존 유지)
  - UI Polish: Material 3 스타일

- **VALIDATE**: 잠금화면 ON/OFF, 폴더 선택, 배경색 변경

### Task 4.4: CREATE `lib/screens/settings_screen.dart` — 설정 화면

PRD Section 4 (In Scope - 설정) 참조.

- **IMPLEMENT**:
  ```
  ┌────────────────────────────┐
  │ ← 설정                     │
  ├────────────────────────────┤
  │ 정답 접기 펼치기 기본값      │
  │   ○ 펼치기  ● 접기          │
  │                            │
  │ 정답 보이고 가리기 기본값     │
  │   ● 보이기  ○ 가리기        │
  │                            │
  │ 카드 위치 기억 [ON/OFF]      │
  │                            │
  │ 카드 번호 표시 [ON/OFF]      │
  │                            │
  │ 카드 목록 스크롤바 [ON/OFF]   │
  │                            │
  │ 이미지 품질                  │
  │   ○ 상  ● 중  ○ 하         │
  │                            │
  │ 테마                        │
  │   ○ 시스템  ○ 라이트  ○ 다크 │
  └────────────────────────────┘
  ```
  - `settings` 테이블 read/write
  - 각 설정값은 `DatabaseHelper.upsertSetting()` / `getAllSettings()`
  - 테마 변경 시 앱 전체에 반영 (ThemeMode 변경)

- **GOTCHA**:
  - 테마 변경은 `MemoraApp`의 `themeMode`를 동적으로 변경해야 함
  - `ValueNotifier<ThemeMode>` 또는 `ChangeNotifier` 패턴 사용
  - 설정값은 앱 시작 시 로드하여 전역 상태로 관리
- **VALIDATE**: 설정 변경 → 앱 재시작 후 설정값 유지

### Task 4.5: UPDATE `lib/app.dart` — 동적 테마 지원

- **IMPLEMENT**:
  - `ValueNotifier<ThemeMode>` 전역 변수
  - 앱 시작 시 settings 테이블에서 theme_mode 로드
  - `ValueListenableBuilder`로 MaterialApp의 themeMode 동적 변경
  - 설정 화면에서 테마 변경 시 notifier 업데이트

- **VALIDATE**: 설정에서 다크모드 선택 → 즉시 앱 전체 다크모드 적용

### Task 4.6: 다크모드 전체 화면 점검

- **IMPLEMENT**: 모든 화면에서 하드코딩된 색상 제거
  - `Colors.white` → `Theme.of(context).colorScheme.surface`
  - `Colors.black` → `Theme.of(context).colorScheme.onSurface`
  - 직접 색상 지정 제거 → Material 3 시스템 색상 사용
- **VALIDATE**: 다크모드에서 모든 화면 가독성 확인

### Task 4.7: 홈 화면 드로어 메뉴 연결

- **IMPLEMENT**: Phase 1에서 placeholder였던 메뉴 항목들을 실제 화면으로 연결
  - 카드 푸시 알림 → `PushNotificationSettingsScreen`
  - 설정 → `SettingsScreen`
  - 파일 만들기 → `ExportScreen`
  - 파일 목록 → `FileListScreen`

- **VALIDATE**: 모든 드로어 메뉴 → 각 화면 이동 정상

### Task 4.8: 전체 테스트 작성

- **IMPLEMENT**:
  - `test/models/card_test.dart` — 기존 유지 + 확장
  - `test/models/folder_test.dart` — `isBundle` round-trip 추가
  - `test/services/memk_import_service_test.dart` — 폴더 매핑 테스트
  - `test/services/memk_export_service_test.dart` — 선택적 내보내기 테스트

- **VALIDATE**: `flutter test` 전체 통과

### Task 4.9: Phase 4 최종 빌드 & 검증

- **VALIDATE**:
  ```bash
  rm -rf /tmp/amki_wang && cp -r . /tmp/amki_wang && cd /tmp/amki_wang
  C:/flutter/bin/flutter analyze
  C:/flutter/bin/flutter test
  C:/flutter/bin/flutter build apk --debug
  # APK를 기기에 설치
  adb install -r build/app/outputs/flutter-apk/app-debug.apk
  ```

---

## TESTING STRATEGY

### Unit Tests
- **모델 round-trip**: CardModel, Folder — JSON ↔ Dart ↔ DB 변환
- **서비스 로직**: Import (폴더 매핑), Export (선택적), 검색 (우선순위)
- **DB 쿼리**: searchCards, batch operations

### Integration Tests (수동)
- .memk 가져오기 → 기존 폴더에 카드 삽입 → 카드 수 확인
- 다중 선택 → 삭제/이동 → 카드 수 업데이트 확인
- 푸시 알림 설정 → 시간 경과 → 알림 수신 확인
- 잠금화면 ON → 화면 잠금 → 카드 표시 확인

### Edge Cases
- 빈 폴더에 가져오기
- 10,000+ 카드 폴더에서 검색 성능
- .memk 파일에 손상된 이미지 포함
- 동시에 import + export 시도
- 묶음 폴더 삭제 시 하위 폴더 처리
- 다크모드에서 모든 텍스트 가독성

---

## VALIDATION COMMANDS

### Level 1: Syntax & Style
```bash
cd /tmp/amki_wang
C:/flutter/bin/flutter analyze
```

### Level 2: Unit Tests
```bash
cd /tmp/amki_wang
C:/flutter/bin/flutter test
```

### Level 3: Build
```bash
cd /tmp/amki_wang
C:/flutter/bin/flutter build apk --debug
```

### Level 4: Device Install
```bash
adb install -r /tmp/amki_wang/build/app/outputs/flutter-apk/app-debug.apk
```

### Level 5: Manual Validation
- 앱 실행 → 홈 화면 표시
- 폴더 생성/편집/삭제
- 카드 생성/편집/삭제
- .memk import (기존 폴더 선택)
- .memk export (폴더 선택)
- 검색 (Question 우선순위)
- 다중 선택 → 삭제/이동
- 잠금화면 ON/OFF
- 푸시 알림 설정
- 다크모드 전환
- 설정 저장/복원

---

## ACCEPTANCE CRITERIA

- [ ] 앱 이름 "Memora", Coral Orange 테마
- [ ] 다크모드 지원 (시스템/수동 전환)
- [ ] 폴더 CRUD + 묶음 폴더
- [ ] 카드 CRUD + 이미지 최대 5장/면
- [ ] 카드 리스트: Question 접기 + Answer 숨기기
- [ ] 카드 검색: Question 우선순위 + 키패드 버그 수정
- [ ] 다중 선택 & 일괄 삭제/이동
- [ ] .memk 가져오기: 기존 폴더 선택
- [ ] .memk + PDF 내보내기 (폴더 선택)
- [ ] 파일 목록 관리
- [ ] 푸시 알림 (다중 시간, 요일, 폴더)
- [ ] 잠금화면 (폴더, 정답옵션, 순서, 배경색)
- [ ] 설정 화면 (6개 항목 + 테마)
- [ ] 10,000+ 카드 성능 유지
- [ ] 모든 테스트 통과
- [ ] flutter analyze 경고 0개

---

## COMPLETION CHECKLIST

- [ ] Phase 1 완료 & 빌드 성공
- [ ] Phase 2 완료 & 빌드 성공
- [ ] Phase 3 완료 & 빌드 성공
- [ ] Phase 4 완료 & 빌드 성공
- [ ] 전체 테스트 통과
- [ ] flutter analyze 0 warnings
- [ ] 기기 설치 & 수동 테스트 완료
- [ ] .memk 호환성 확인 (암기짱 파일 import 성공)

---

## NOTES

### 리셋 전략
"전체 리셋"이지만 실제로는 **기존 파일을 대폭 수정하는 방식**. 기존에 잘 동작하는 코드 (models, database_helper, services, Android native)를 처음부터 다시 쓰면 시간 낭비이므로, **검증된 핵심을 유지하면서 UI/UX와 기능을 PRD에 맞게 재구현**한다.

삭제 대상: `card_view_screen.dart`, `study_screen.dart`, `card_flip_widget.dart` (PRD에 없음)

### 의존성 추가 (pubspec.yaml)
- Phase 3: `pdf: ^3.x` (PDF 생성), `printing: ^5.x` (PDF 미리보기/인쇄) — 또는 `pdf` 만
- Phase 4: `shared_preferences: ^2.x` (이미 AndroidNative에서 사용 중이지만 Flutter 측에서도 사용 가능)

### 한글 경로 빌드 이슈
모든 빌드는 반드시 `/tmp/amki_wang/`에 복사 후 실행. Flutter SDK: `C:\flutter\bin\flutter`.

### DB 마이그레이션
기존 사용자 (v1 DB)가 앱 업데이트 시 `onUpgrade`가 호출되어 새 테이블/컬럼 추가됨. 데이터 손실 없음.

### CardModel 100+ 필드
PRD에서 음성/손글씨는 Out of Scope이지만, .memk 호환을 위해 모든 필드를 유지한다. UI에서는 사용하지 않지만 import/export 시 데이터 보존.

### 구현 순서 중요
Phase 1 → 2 → 3 → 4 순서를 반드시 지킬 것. 각 Phase의 Task도 번호 순서대로 실행. 이전 Task가 완료되어야 다음 Task가 정상 동작함.

### Confidence Score: 8/10
- 기존 검증된 코드(모델, DB, 서비스)를 재사용하므로 안정적
- Android Native 코드 변경 최소 (잘 동작 중)
- PDF 한글 폰트가 가장 큰 리스크 (TTF 번들링 필요)
- 다크모드 하드코딩 색상 제거는 세밀한 작업 필요
