# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**Memora** (구 암기왕)는 Flutter + SQLite 기반의 Android 플래시카드 학습 앱이다. 암기짱(com.metastudiolab.memorize)의 기능을 기반으로 하되, 불필요한 기능을 제거하고 UX를 개선한 앱. `.memk` 파일 호환성을 유지하며, 카드 CRUD, 폴더 관리, 검색, 푸시 알림, 잠금화면 기능을 제공한다.

**PRD**: `PRD.md` 참조 (전체 기능 명세, 화면별 상세, 구현 Phase)

---

## Tech Stack

| Technology | Version | Purpose |
|------------|---------|---------|
| Flutter | ^3.11.1 | UI 프레임워크 |
| Dart | ^3.x | 프로그래밍 언어 |
| SQLite (sqflite) | ^2.4.2 | 로컬 데이터베이스 |
| Material Design 3 | built-in | UI 컴포넌트 시스템 |
| archive | ^4.0.4 | ZIP 압축/해제 (.memk) |
| file_picker | ^8.1.7 | 파일 선택 다이얼로그 |
| image_picker | ^1.2.1 | 카메라/갤러리 이미지 선택 |
| flutter_local_notifications | ^19.0.0 | 푸시 알림 |
| permission_handler | ^11.4.0 | 런타임 권한 요청 |
| Kotlin (Android Native) | - | Foreground Service, MethodChannel |

---

## Commands

```bash
# 빌드 (한글 경로 우회 필수)
cp -r . /tmp/amki_wang && cd /tmp/amki_wang
C:/flutter/bin/flutter build apk --debug

# 테스트
C:/flutter/bin/flutter test

# 분석
C:/flutter/bin/flutter analyze

# 기기 설치
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

**중요**: 프로젝트가 `바탕 화면` (한글 경로)에 있어서 Flutter 빌드가 실패함. 반드시 `/tmp/`에 복사 후 빌드할 것.

---

## Project Structure

```
lib/
├── main.dart                          # 앱 진입점
├── app.dart                           # MaterialApp, Theme, Routing
├── database/
│   └── database_helper.dart           # SQLite CRUD (Singleton)
├── models/
│   ├── card.dart                      # CardModel (100+ fields)
│   └── folder.dart                    # Folder model
├── screens/
│   ├── home_screen.dart               # 홈 (폴더 리스트)
│   ├── card_list_screen.dart          # 카드 리스트 (폴더 내부)
│   ├── card_edit_screen.dart          # 카드 생성/편집
│   ├── import_screen.dart             # .memk 가져오기
│   └── lock_screen_settings.dart      # 잠금화면 설정
├── services/
│   ├── memk_import_service.dart       # .memk ZIP 해제 & 카드 임포트
│   ├── memk_export_service.dart       # .memk ZIP 생성 & 내보내기
│   ├── lock_screen_service.dart       # MethodChannel → Android Native
│   └── notification_service.dart      # 푸시 알림
├── widgets/
│   ├── card_tile.dart                 # 카드 리스트 아이템
│   ├── folder_tile.dart               # 폴더 리스트 아이템
│   └── image_viewer.dart              # 전체화면 이미지 뷰어
└── utils/
    └── constants.dart                 # AppConstants (DB명, 테이블명, 페이지 사이즈 등)

android/
├── app/src/main/kotlin/.../
│   ├── MainActivity.kt                # MethodChannel 핸들러
│   ├── LockScreenService.kt          # Foreground Service (잠금화면)
│   └── ScreenReceiver.kt             # 화면 ON/OFF 감지
└── app/src/main/AndroidManifest.xml   # 권한, Intent Filter (.memk)
```

---

## Architecture

```
Screen Layer (StatefulWidget)
    ↓ calls
Service Layer (MemkImportService, NotificationService, etc.)
    ↓ calls
Database Layer (DatabaseHelper singleton)
    ↓ reads/writes
SQLite (amki_wang.db)

Screen Layer
    ↓ MethodChannel
Android Native (Foreground Service, Overlay)
```

- **Screen → DB 직접 호출**: 간단한 CRUD는 Screen에서 DatabaseHelper를 직접 호출
- **Screen → Service → DB**: 복잡한 로직(가져오기/내보내기)은 Service를 거침
- **Service는 Progress Callback 패턴**: `onProgress(ImportProgress)` 콜백으로 UI에 진행률 전달

---

## Code Patterns

### Naming Conventions
- **파일**: `snake_case.dart` (예: `card_edit_screen.dart`, `memk_import_service.dart`)
- **클래스**: `PascalCase` (예: `CardModel`, `DatabaseHelper`, `CardEditScreen`)
- **변수/메소드**: `camelCase` (예: `folderId`, `getCardsByFolderId`)
- **상수**: `UPPER_SNAKE_CASE` in `AppConstants` (예: `dbName`, `pageSize`)
- **DB 컬럼**: `snake_case` (예: `folder_id`, `card_count`)
- **JSON 키**: `camelCase` (예: `folderId`, `cardCount`)
- **private**: `_` 접두사 (예: `_cards`, `_loadCards()`)

### Model Serialization (Triple Pattern)
모든 모델은 3가지 직렬화를 지원:
```dart
// JSON (camelCase) - .memk 파일 교환용
factory CardModel.fromJson(Map<String, dynamic> json)
Map<String, dynamic> toJson()

// DB (snake_case) - SQLite 저장용
factory CardModel.fromDb(Map<String, dynamic> map)
Map<String, dynamic> toDb()

// copyWith - 불변 객체 수정용
CardModel copyWith({int? id, String? question, ...})
```

**Bool 변환 규칙**: Dart `bool` ↔ SQLite `int` (0/1), JSON은 `bool` 그대로

### Database Pattern
```dart
// Singleton
static final DatabaseHelper instance = DatabaseHelper._init();
static Database? _database;

// CRUD는 항상 async
Future<int> insertFolder(Folder folder) async {
  final db = await database;
  return await db.insert(tableName, folder.toDb());
}

// 배치 작업은 transaction 사용
await db.transaction((txn) async {
  for (final card in cards) {
    await txn.insert(tableCards, card.toDb());
  }
});
```

### Screen Widget Pattern
```dart
class SomeScreen extends StatefulWidget {
  final Folder folder;  // 필수 파라미터는 required
  const SomeScreen({super.key, required this.folder});
  @override
  State<SomeScreen> createState() => _SomeScreenState();
}

class _SomeScreenState extends State<SomeScreen> {
  // 상태 변수
  bool _loading = true;
  final List<CardModel> _cards = [];

  @override
  void initState() {
    super.initState();
    _loadData();  // 초기 데이터 로딩
  }

  @override
  void dispose() {
    _scrollController.dispose();  // 리소스 정리
    super.dispose();
  }
}
```

### Navigation
```dart
// Push & reload on return
await Navigator.push(context, MaterialPageRoute(builder: (_) => NextScreen()));
_loadData();  // 돌아오면 데이터 리로드
```

### Dialog
```dart
final result = await showDialog<String>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('제목'),
    content: TextField(...),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
      TextButton(onPressed: () => Navigator.pop(ctx, value), child: const Text('확인')),
    ],
  ),
);
if (result == null) return;
```

### Error Handling
```dart
try {
  await operation();
} catch (e) {
  if (!mounted) return;  // 항상 mounted 체크
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('에러: $e')),
  );
}
```

### Service Progress Callback
```dart
// Service
Future<ImportResult> importFile({
  required String filePath,
  required void Function(ImportProgress) onProgress,
}) async { ... }

// Screen
await service.importFile(
  filePath: path,
  onProgress: (progress) {
    if (mounted) setState(() => _progress = progress);
  },
);
```

### Import Order
```dart
// 1. Dart SDK
import 'dart:async';
import 'dart:io';
// 2. Flutter/Package
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
// 3. Project
import '../database/database_helper.dart';
import '../models/card.dart';
```

---

## Testing

- **Run**: `flutter test`
- **Location**: `test/` (mirrors `lib/` structure)
- **Pattern**: `group()` + `test()`, sample data at top level, round-trip 변환 테스트
- **핵심 테스트**: JSON ↔ Dart ↔ DB round-trip (타입 변환 정확성)

```dart
group('CardModel.fromJson → toJson round-trip', () {
  test('기본 필드 보존', () {
    final card = CardModel.fromJson(sampleJson);
    final json = card.toJson();
    expect(json['uuid'], sampleJson['uuid']);
  });
});
```

---

## Key Files

| File | Purpose |
|------|---------|
| `PRD.md` | 전체 기능 명세, 화면별 상세, 구현 Phase |
| `lib/utils/constants.dart` | DB명, 테이블명, 페이지사이즈, .memk 호환 경로 등 모든 상수 |
| `lib/database/database_helper.dart` | SQLite 스키마, 모든 CRUD 메소드 (싱글톤) |
| `lib/models/card.dart` | CardModel (100+ 필드, JSON/DB 직렬화) |
| `lib/models/folder.dart` | Folder 모델 |
| `lib/services/memk_import_service.dart` | .memk ZIP 해제 & 카드 임포트 로직 |
| `lib/services/memk_export_service.dart` | .memk ZIP 생성 & 내보내기 로직 |
| `android/.../MainActivity.kt` | MethodChannel 핸들러 (잠금화면 서비스 제어) |
| `android/.../LockScreenService.kt` | Foreground Service (잠금화면 오버레이) |
| `pubspec.yaml` | 의존성, Flutter SDK 버전 |

---

## .memk File Format

암기짱과 호환되는 ZIP 파일:
```
*.memk (ZIP)
├── folders.json      # 폴더 배열 (camelCase JSON)
├── cards.json        # 카드 배열 (camelCase JSON)
├── counter.json      # 시퀀스 카운터
├── prefs.json        # 설정값
└── images/           # 이미지 파일들
```

**호환성 경로**: 암기짱 이미지 경로 `/data/user/0/com.metastudiolab.memorize/files/image/`에서 파일명만 추출하여 로컬 저장

---

## Theme (Coral Orange)

```dart
// Light
ThemeData(
  colorSchemeSeed: Color(0xFFFF6B6B),  // Coral Orange
  useMaterial3: true,
  brightness: Brightness.light,
)

// Dark
ThemeData(
  colorSchemeSeed: Color(0xFFFF6B6B),
  useMaterial3: true,
  brightness: Brightness.dark,
)
```

| Element | Light | Dark |
|---------|-------|------|
| 상단바/버튼 | #FF6B6B | auto (M3) |
| 배경 | #FFF5F5 | auto (M3) |
| 텍스트 | #2D3436 | auto (M3) |
| 카드배경 | #FFFFFF | auto (M3) |
| 강조 | #FFA8A8 | auto (M3) |

---

## Notes

- **한글 경로 빌드 이슈**: 반드시 `/tmp/`에 복사 후 빌드. `C:\flutter\` SDK 사용
- **DB 버전 관리**: 새 테이블/컬럼 추가 시 `dbVersion` 올리고 `onUpgrade`에서 `ALTER TABLE` 사용
- **.memk 호환성**: 암기짱 .memk 파일을 그대로 가져올 수 있어야 함. JSON 키는 camelCase 유지
- **페이지네이션**: 카드 리스트는 50개씩 로딩 (`AppConstants.pageSize`), ScrollController로 무한 스크롤
- **Boolean ↔ Integer**: SQLite에 bool 저장 시 반드시 0/1 int로 변환
- **mounted 체크**: async 작업 후 `setState()` 전에 반드시 `if (!mounted) return;` 체크
- **MethodChannel**: `com.henry.amki_wang/lockscreen` 채널로 Flutter ↔ Kotlin 통신

---

## Reference

> **원칙**: 확실하지 않을 때 가정을 절대 하지 말 것. 아래 Reference를 먼저 참조하고, 그래도 불확실하면 반드시 사용자에게 질문할 것.

<!--
  [Reference 슬롯 시스템]
  - 추가: 아래 테이블에 새 행 추가 (| ID | 경로 | 설명 |)
  - 제거: 해당 행 삭제
  - 비활성화: ID 앞에 ~ 붙이기 (예: ~REF-02)
-->

| ID | File | Description |
|----|------|-------------|
| REF-01 | `.claude/reference/amkizzang-apk-analysis.md` | 암기짱 APK 역공학 분석 (Activities, DB 스키마, 잠금화면 구현, .memk 파일 처리, 서드파티 라이브러리 등) |
<!-- | REF-02 | `.claude/reference/your-file.md` | 설명 | -->
<!-- | REF-03 | `.claude/reference/your-file.md` | 설명 | -->
