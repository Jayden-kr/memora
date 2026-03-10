# 암기짱 (Memorize) APK 역공학 분석 결과

**APK**: `암기짱 - 직접 만드는 단어장, 영단어, 플래시 카드_2.9.1_APKPure.xapk`
**패키지**: `com.metastudiolab.memorize`
**버전**: 2.9.1 (versionCode 63)
**Min SDK**: 23 (Android 6.0) | **Target SDK**: 36
**Build Tool**: Android Gradle Plugin 8.13.2
**언어**: Java 기반 (Kotlin은 라이브러리/glue 용)

---

## 1. Activities (25개)

| Activity | 역할 |
|---|---|
| `MainActivity` | 메인 런처, `.memk` 파일 열기 intent-filter 처리 |
| `CardListActivity` | 폴더 내 카드 목록 |
| `AddCardActivity` | 카드 생성/편집 |
| `AddFolderActivity` | 폴더 생성/편집 |
| `AddGroupFolderActivity` | 그룹(부모) 폴더 생성/편집 |
| `ExamActivity` | 퀴즈/시험 모드 |
| `ExamPreparationActivity` | 시험 설정 화면 |
| `ExamFinishActivity` | 시험 결과 화면 |
| `LockScreenLandingActivity` | 잠금화면 온보딩 |
| `LockScreenDesignSetupActivity` | 잠금화면 배경 커스터마이징 |
| `NotificationSetupActivity` | 푸시 알림 스케줄러 |
| `BackupRestoreActivity` | 클라우드/로컬 백업 |
| `BackupRestoreChooseAccountActivity` | Google/Dropbox 계정 선택 |
| `SettingsActivity` | 설정 |
| `StoreActivity` | 인앱 구매 스토어 |
| `AboutAdsActivity` | 광고 설정 |
| `SubscriptionActivity` | 구독 관리 |
| `PhotoZoomActivity` | 전체 화면 이미지 뷰어 |
| `DrawingActivity` | 손글씨 캔버스 |
| `ImageEditActivity` | 이미지 크롭/편집 |
| `QRCodeCaptureActivity` | QR 코드 스캐너 |
| `WebCardImportActivity` | 웹 URL에서 카드 import |
| `FileCreationActivity` | PDF/XLSX 파일 export |
| `FileListActivity` | .memk/.pdf 파일 목록 |
| `PopupNotificationActivity` | 알림 카드 팝업 |
| `SimpleBroswerActivity` / `PopupBroswerActivity` | 인앱 브라우저 |
| `DebugActivity` | 개발 디버그 화면 |
| `TestActivity` | 개발 테스트 화면 |
| `lockscreen.LockScreenActivity` | 잠금화면 오버레이 Activity (taskAffinity=`com.metastudiolab.Locker`, `showWhenLocked=true`, `excludeFromRecents=true`) |
| `lockscreen.LockScreenSetupActivity` | 잠금화면 ON/OFF 및 폴더 선택 |

---

## 2. Services (8개)

| Service | Type | 역할 |
|---|---|---|
| `lockscreen.LockScreenService` | `FOREGROUND_SERVICE_SPECIAL_USE` | 잠금화면 상시 Foreground Service |
| `lockscreen.LockScreenViewService` | (none) | WindowManager 오버레이로 잠금화면 카드 뷰 생성/관리 |
| `pdf.PdfGenerateService` | `DATA_SYNC` | PDF 생성 |
| `backup.dropbox.DropboxBackupService` | `DATA_SYNC` | Dropbox 백업/복원 |
| `backup.googledrive.GoogleDriveBackupService` | `DATA_SYNC` | Google Drive 백업/복원 |
| `backup.localstorage.ExternalMemoryBackupService` | `DATA_SYNC` | SD카드/로컬 백업 |
| `backup.RestoreFileService` | `DATA_SYNC` | 백업 파일 복원 |
| `MemkFirebaseMessagingService` | - | Firebase Cloud Messaging |

---

## 3. BroadcastReceivers (4개)

| Receiver | 트리거 |
|---|---|
| `lockscreen.LockScreenStartReceiver` | `BOOT_COMPLETED`, `PACKAGE_REPLACED`, `MY_PACKAGE_REPLACED` → 잠금화면 서비스 자동 시작 |
| `lockscreen.ScreenReceiver` | `SCREEN_OFF` → 잠금화면 표시 트리거 |
| `notification.LocalNotificationReceiver` | `BOOT_COMPLETED`, `SHOW_NOTIFICATION`, `SHOW_DAILY_NOTIFICATION`, `NOTIFICATION_SETUP`, `PACKAGE_REPLACED` |
| `pdf.PdfServiceActionReceiver` | PDF 생성 취소 액션 |

---

## 4. ContentProviders (2개)

| Provider | 역할 |
|---|---|
| `androidx.core.content.FileProvider` | 파일 공유 (backup, tmp, audio, image, pdf, root) |
| `androidx.startup.InitializationProvider` | emoji2, WorkManager, lifecycle, OkHttp, ProfileInstaller 초기화 |

---

## 5. 권한 (Permissions)

| Permission | 용도 |
|---|---|
| `RECEIVE_BOOT_COMPLETED` | 부팅 후 잠금화면 서비스 + 알림 재스케줄 |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` | 잠금화면 Foreground Service |
| `FOREGROUND_SERVICE_DATA_SYNC` | 백업/복원 + PDF 생성 서비스 |
| `WAKE_LOCK` | 잠금화면 표시 시 CPU 유지 |
| `DISABLE_KEYGUARD` | 시스템 잠금화면 dismiss |
| `SYSTEM_ALERT_WINDOW` | WindowManager 오버레이 (잠금화면) |
| `POST_NOTIFICATIONS` | 푸시 알림 (Android 13+) |
| `CAMERA` | QR 코드 스캐닝 |
| `RECORD_AUDIO` | 카드 음성 녹음 |
| `READ/WRITE_EXTERNAL_STORAGE` | .memk 파일 접근, SD카드 백업 |
| `INTERNET` + `ACCESS_NETWORK_STATE` | 클라우드 백업, 광고, 웹 카드 import |
| `GET_ACCOUNTS` | Google Drive 계정 선택 |
| `READ_PHONE_STATE` | 디바이스 식별 |
| `BILLING` | 인앱 구매 |
| `AD_ID` + `ACCESS_ADSERVICES_*` | AdMob + Facebook Audience Network |

---

## 6. 데이터베이스 (greenDAO ORM)

**ORM**: greenDAO (`de.greenrobot.dao`) — Room이 아님.

### Card 테이블 (CardDao) — 전체 필드

**텍스트:**
- `id` (Long) — PK
- `uuid` (String) — 고유 식별자
- `folderId` (Long) — FK → Folder
- `folderName` (String)
- `question` (String) — 앞면 텍스트
- `answer` (String) — 뒷면 텍스트

**이미지 (각 면 최대 5장):**
- `questionImagePath` ~ `questionImagePath5` (String)
- `questionImageRatio` ~ `questionImageRatio5` (Double)
- `answerImagePath` ~ `answerImagePath5` (String)
- `answerImageRatio` ~ `answerImageRatio5` (Double)

**손글씨 이미지 (각 면 최대 5장):**
- `questionHandImagePath` ~ `questionHandImagePath5` (String)
- `questionHandImageRatio` (Double)
- `answerHandImagePath` ~ `answerHandImagePath5` (String)
- `answerHandImageRatio` (Double)

**음성 녹음 (각 면 최대 10개):**
- `questionVoiceRecordPath` ~ `questionVoiceRecordPath10` (String)
- `questionVoiceRecordLength` (Integer)
- `answerVoiceRecordPath` ~ `answerVoiceRecordPath10` (String)
- `answerVoiceRecordLength` (Integer)

**상태:**
- `starred` (Boolean?) — 별표
- `starLevel` (int) — 별점 레벨
- `finished` (Boolean?) — 암기 완료
- `reversed` (Boolean?) — Q/A 반전
- `selected` (Boolean?) — 다중 선택

**정렬:**
- `sequence`, `sequence2`, `sequence3`, `sequence4` (int)

**메타:**
- `modified` (Date)

### Folder 테이블 (FolderDao)

- `id` (Long) — PK
- `name` (String)
- `cardCount` (Long)
- `folderCount` (Long)
- `sequence` (Long), `originalSequence` (Long)
- `parent` (Boolean) — 그룹(부모) 폴더 여부
- `parentFolderId` (Long) — 상위 폴더 FK
- `parentFolderName` (String)
- `modified` (Date)

### Counter 테이블 (CounterDao)

- `id` (Long)
- `card_sequence` / `card_minus_sequence` (Long)
- `folder_sequence` / `folder_minus_sequence` (Long)

### 특수 폴더 ID (DataManager)

- `TOTAL_FOLDER_ID` — 전체 카드
- `STAR_FOLDER_ID` — 별표 카드
- `FINISHED_FOLDER_ID` — 암기 완료 카드
- `WORKING_FOLDER_ID` — 암기 중 카드

---

## 7. 잠금화면 구현 상세 (Phase 4 핵심)

### 아키텍처

**2중 구조:**
1. `LockScreenActivity` — Activity 기반 (`showWhenLocked=true`)
2. `LockScreenViewService` — WindowManager 오버레이 방식

### 동작 흐름

```
[부팅/앱 설치]
    ↓
LockScreenStartReceiver (BOOT_COMPLETED / PACKAGE_REPLACED)
    ↓
LockScreenService.startForeground() — 상시 Foreground Service
    ↓ (ScreenReceiver 등록)

[화면 꺼짐]
    ↓
ScreenReceiver (SCREEN_OFF broadcast)
    ↓
LockScreenViewService 시작
    ↓
WindowManager.addView() — 전체 화면 오버레이 생성
    ↓
오버레이 UI 표시:
  ├── mContainer (FrameLayout) — 메인 컨테이너
  ├── mBackground (RelativeLayout) — 배경
  ├── mViewPager + LockScreenCardPagerAdapter — 카드 좌우 스와이프
  ├── mLocker (LockerView) — 스와이프로 잠금 해제
  ├── mStar (ImageView) — 별표 토글
  ├── mFolderNameView (TextView) — 현재 폴더명
  ├── mStatusBarBg — 상태바 배경
  └── mAdContainer / mAdView — 광고 (우리는 제외)
```

### 핵심 클래스

| 클래스 | 역할 |
|---|---|
| `LockScreenService` | Foreground Service 유지. `createLockscreenNotification()` 으로 상시 알림 생성. `FOREGROUND_SERVICE_SPECIAL_USE` 타입. |
| `LockScreenViewService` | WindowManager (`wm` 필드)로 오버레이 뷰 추가/제거. 카드 데이터 로드 및 표시. |
| `LockScreenViewManager` | 오버레이 뷰 라이프사이클 관리 |
| `ScreenReceiver` | `SCREEN_OFF` 인텐트 수신 → LockScreenViewService 트리거 |
| `LockScreenStartReceiver` | `BOOT_COMPLETED` 수신 → LockScreenService 시작 |
| `LockScreenCardManager` | 표시할 카드 관리 (폴더/상태 필터 적용) |
| `LockScreenCardOrder` | 카드 순서 (순차/랜덤) 관리 |
| `LockScreenConfigManager` | 잠금화면 설정 관리 |
| `LockScreenCardOption` | 카드 표시 옵션 |
| `LockScreenCardPagerAdapter` | ViewPager 어댑터 (카드 페이지) |
| `LockerView` | 커스텀 뷰 — 스와이프로 잠금 해제 |
| `LockScreenDesignSetupFragment` | 배경 디자인 설정 (BackgroundAdapter) |

### LockScreenActivity 속성

```xml
<activity
    android:name=".lockscreen.LockScreenActivity"
    android:taskAffinity="com.metastudiolab.Locker"
    android:showWhenLocked="true"
    android:excludeFromRecents="true"
    android:launchMode="singleTop" />
```

- `taskAffinity` 별도 설정으로 메인 앱과 독립 태스크
- `showWhenLocked=true`로 잠금화면 위에 표시
- `excludeFromRecents`로 최근 앱 목록에서 제외

---

## 8. .memk 파일 처리

### Export (백업)

- `BackupManager` 클래스가 담당
- ZIP 내 포함 파일: `CARD_JSON_FILE_NAME`, `FOLDER_JSON_FILE_NAME`, `COUNTER_JSON_FILE_NAME`, `PREFS_JSON_FILE_NAME`
- `COMPRESSION_LEVEL` 설정 가능
- JSON 직렬화: `GsonUtil` (커스텀 `DateDeserializer` 포함)

### Import (복원)

- `WebCardImport`: URL 기반 import (`DownloadMemkTask` → `DownloadMetaDataTask` → `RestoreMemkTask`)
- `ZipUtil.unzip()`: ZIP 해제
- `RestoreFileService`: 실제 DB 복원
- `BackupIntentReceiver`: 백업 완료 이벤트 수신

### Intent Filters (.memk 파일 열기 — MainActivity)

4개 intent-filter 등록:
1. `file://` scheme + `pathPattern=.*\.memk` + `mimeType=*/*`
2. Any host + `pathPattern=.*\.memk` + `mimeType=application/octet-stream`
3. Any host + `pathPattern=.*\.memk` + `mimeType=application/memk`
4. Any host + `pathPattern=.*\.memk` + `mimeType=application/x-memk`

### 파일 경로 (file_paths.xml — FileProvider)

- `files/backup/`
- `files/tmp/`
- `files/audio/`
- `files/image/`
- `external-files/backup/`
- `external-files/pdf/`
- Root path `.` (레거시 파일 접근)

---

## 9. 서드파티 라이브러리

| 라이브러리 | 버전 | 용도 |
|---|---|---|
| **greenDAO** (`de.greenrobot.dao`) | (난독화) | SQLite ORM |
| **Glide** (`com.bumptech.glide`) | (번들) | 이미지 로딩/캐시 (GlideApp, GlideConfiguration, GlideOptions) |
| **OkHttp3** | (번들) | HTTP 클라이언트 |
| **Gson** (`GsonUtil`) | (번들) | .memk JSON 직렬화 |
| **Jackson** (`com.fasterxml.jackson.core`) | (번들) | JSON (Dropbox SDK용) |
| **Dropbox SDK** (`com.dropbox.core`) | (번들) | Dropbox 클라우드 백업 (DropboxClientFactory) |
| **Google Play Billing** | 8.3.0 | 인앱 구매/구독 |
| **Google AdMob** (`play-services-ads`) | 23.6.0 | 배너/전면 광고 |
| **Facebook Audience Network** (`com.facebook.ads`) | (번들) | 보조 광고 네트워크 |
| **Firebase Analytics** | 23.0.0 | 사용 분석 |
| **Firebase Crashlytics** | (번들) | 크래시 리포팅 |
| **Firebase Cloud Messaging** | (번들) | 푸시 알림 |
| **Firebase Remote Config** | (번들) | 피처 플래그 (`cardlist_ads_prob`, `import_memk_ads_prob`, `pro_version_event`) |
| **Google Sign-In** (`play-services-auth`) | 21.4.0 | Google Drive 인증 |
| **Google Drive API** | (GoogleDriveServiceHelper) | 클라우드 백업 |
| **ZXing / journeyapps barcode scanner** | (번들) | QR 코드 스캐닝 |
| **SimpleCropView** (`com.isseiaoki.simplecropview`) | (번들) | 이미지 크롭 |
| **libHaru** (`org.libharu`) | (번들) | 네이티브 PDF 생성 |
| **AndroidX Room** | 2.2.5 | 메인 DB에는 미사용 (WorkManager/시스템용) |
| **AndroidX DataStore** | 1.1.7 | 설정 저장 (SharedPreferences 대체, `OptionStore`) |
| **AndroidX Work** | 2.7.0 | 백그라운드 작업 스케줄링 |
| **AndroidX Lifecycle** | 2.9.4 | 라이프사이클 인식 컴포넌트 |
| **AndroidX ViewPager2** | (번들) | 카드 스와이프 UI |
| **AndroidX RecyclerView Selection** | (번들) | 카드/폴더 다중 선택 |
| **AndroidX Browser** (CustomTabs) | (번들) | 인앱 브라우징 |
| **Kotlin Coroutines** | (번들) | 비동기 처리 |
| **Google UMP** (User Messaging Platform) | 3.0.0 | GDPR 광고 동의 |

**Google AdMob App ID**: `ca-app-pub-8816243190908007~8790474798`

---

## 10. UI 화면 (Layout XML 기반)

**메인**: Main (폴더 목록 + bottom sheet + navigation drawer), CardList, AddCard, AddFolder, AddGroupFolder

**학습/시험**: ExamPreparation, Exam (카드 pager + 타이머), ExamFinish, MemoryMode, MemoryModePreparation, MemoryModeFinish

**잠금화면**: LockScreen (카드 오버레이), LockScreenLanding, LockScreenSetup, LockScreenDesignSetup

**카드 기능**: PhotoZoom, Drawing (캔버스 + 팔레트/지우개/툴바), ImageEdit, VoiceRecorder (다이얼로그), AudioBottomSheet, MediaPlayer, SharePreview, FontSizeBottomSheet

**파일/백업**: FileList, FileCreation (PDF/XLSX export), BackupRestore, CloudBackupRestore, SDCardBackupRestore, BackupRestoreChooseAccount, WebCardImport

**설정**: Settings, NotificationSetup, AboutAds, PopupNotification

**스토어/결제**: Store, Subscription, PurchaseDialog

**기타**: QR scanner, Browser, Help, Debug

### 커스텀 뷰

| 뷰 | 용도 |
|---|---|
| `LockerView` | 스와이프 잠금 해제 |
| `ClockView` | 시계 표시 |
| `CircularProgressView` | 원형 진행률 |
| `AutoResizeTextView` / `FontFitTextView` | 텍스트 자동 크기 조절 |
| `DrawingView` / `DrawingPalette` / `DrawingToolBar` | 손글씨 그리기 |
| `RecyclerViewFastScroller` | 빠른 스크롤바 |
| `ViewPagerDotIndicator` | 페이지 인디케이터 |
| `ExpandableItemIndicator` | 그룹 폴더 확장/축소 |

---

## 11. Assets

- `KaiGenGothicKR-Regular.ttf` — 한국어 폰트 (KaiGen Gothic)
- `audience_network/` — Facebook Audience Network DEX (동적 로딩)
- `dexopt/` — Baseline profiles
- `PublicSuffixDatabase.list` — OkHttp public suffix list

---

## 12. 설정 관리

| 클래스 | 역할 |
|---|---|
| `ConfigurationManager` | 앱 전체 설정 (9개 inner lambda/callback) |
| `LockScreenConfigManager` | 잠금화면 설정 |
| `NotificationConfigManager` | 알림 설정 |
| `RemoteConfigManager` | Firebase Remote Config |
| `GlobalSettings` | 글로벌 설정 |
| `OptionStore` | DataStore 기반 설정 저장 |

---

## 13. 앱 아키텍처 요약

- **패턴**: Activity + Fragment + DataBinding. MVVM/ViewModel은 극소수(`FileCreationViewModel`, `SubscriptionViewModel`, `CardTextSizeBottomSheetViewModel`)만 사용. 대부분 클래식 Android 아키텍처.
- **데이터 레이어**: greenDAO ORM → SQLite. `DataManager`가 중앙 데이터 접근 싱글톤 (정렬, 필터, 특수 폴더 로직).
- **백업/Export**: `.memk` = ZIP (cards.json + folders.json + counter.json + prefs.json + 이미지/오디오 파일). Dropbox, Google Drive, 로컬 저장소 지원.
- **잠금화면**: 2모드 — `LockScreenActivity` (Activity 기반, `showWhenLocked`) + `LockScreenViewService` (WindowManager 오버레이). `ScreenReceiver`가 `SCREEN_OFF`에 반응하여 트리거. `LockScreenService` Foreground Service가 상시 유지.
- **수익화**: Freemium + 광고(AdMob + Facebook Audience Network) + 인앱 구매(Google Play Billing 8.3.0). Remote Config으로 광고 확률 제어. `InAppBillingManager`로 상품/구매 관리.
