class AppConstants {
  AppConstants._();

  // DB
  static const String dbName = 'amki_wang.db';
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

  // 암기짱 호환 이미지 경로 prefix
  static const String amkizzangImagePrefix =
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
