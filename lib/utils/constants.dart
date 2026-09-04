class AppConstants {
  AppConstants._();

  // DB
  static const String dbName = 'memora.db';
  static const int dbVersion = 3;

  // 테이블 이름
  static const String tableCards = 'cards';
  static const String tableFolders = 'folders';
  static const String tableCounters = 'counters';
  static const String tableSettings = 'settings';
  static const String tableExportedFiles = 'exported_files';
  static const String tablePushAlarms = 'push_alarms';

  // 이미지 저장 디렉토리
  static const String imageDir = 'images';

  // 잠금화면 배경 이미지 저장 디렉토리. images/와 완전히 분리 —
  // DatabaseHelper.cleanupOrphanMediaFiles()가 imageDir만 스캔하므로 이 디렉토리 안의
  // 파일은 앱 시작 시 고아 정리 대상이 되지 않는다(카드가 참조하지 않아도 안전).
  static const String lockBgImageDir = 'lock_bg';

  // .memk 호환 이미지 경로 prefix (레거시)
  static const String legacyImagePrefix =
      '/data/user/0/com.metastudiolab.memorize/files/image/';

  // 페이지네이션
  static const int pageSize = 50;

  // .memk Import/Export
  static const int importBatchSize = 100;
  static const String memkFoldersJson = 'folders.json';
  static const String memkCardsJson = 'cards.json';
  static const String memkCounterJson = 'counter.json';
  static const String memkPrefsJson = 'prefs.json';

  // 설정 키
  static const String settingAnswerFold = 'answer_fold';
  static const String settingAnswerVisibility = 'answer_visibility';
  static const String settingCardPositionMemory = 'card_position_memory';
  static const String settingCardNumber = 'card_number';
  static const String settingCardScroll = 'card_scroll';
  static const String settingImageQuality = 'image_quality';
  static const String settingThemeMode = 'theme_mode';

  // 내보내기 디렉토리
  static const String exportDir = 'exports';
}
