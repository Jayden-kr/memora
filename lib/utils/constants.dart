class AppConstants {
  AppConstants._();

  // DB
  static const String dbName = 'amki_wang.db';
  static const int dbVersion = 1;

  // 테이블 이름
  static const String tableCards = 'cards';
  static const String tableFolders = 'folders';
  static const String tableCounters = 'counters';
  static const String tableSettings = 'settings';

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
}
