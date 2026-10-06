/// copyWith에서 nullable 필드를 명시적으로 null로 설정하기 위한 sentinel
const _absent = Object();

class Folder {
  final int? id;
  final String name;
  final int cardCount;
  final int folderCount;
  final int sequence;
  final int originalSequence;
  final String? modified;
  final bool parent;
  final int? parentFolderId;
  final String? parentFolderName;
  final bool isSpecialFolder;
  final bool isBundle;

  /// 폴더 아이콘 키(예: 'star'). 코드포인트가 아니라 키를 저장한다 — null이면 기본
  /// 아이콘. 알 수 없는 키도 그대로 보존한다(앱 버전 간 왕복에서 값을 잃지 않게).
  final String? icon;

  /// 아이콘 색 ARGB(0xAARRGGBB). null이면 테마 기본색.
  final int? iconColor;

  Folder({
    this.id,
    required this.name,
    this.cardCount = 0,
    this.folderCount = 0,
    this.sequence = 0,
    this.originalSequence = 0,
    this.modified,
    this.parent = false,
    this.parentFolderId,
    this.parentFolderName,
    this.isSpecialFolder = false,
    this.isBundle = false,
    this.icon,
    this.iconColor,
  });

  /// .memk JSON → Dart (camelCase 키)
  factory Folder.fromJson(Map<String, dynamic> json) {
    return Folder(
      id: (json['id'] as num?)?.toInt(),
      name: json['name'] as String? ?? '',
      cardCount: (json['cardCount'] as num?)?.toInt() ?? 0,
      folderCount: (json['folderCount'] as num?)?.toInt() ?? 0,
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      originalSequence: (json['originalSequence'] as num?)?.toInt() ?? 0,
      modified: json['modified']?.toString(),
      parent: _parseBool(json['parent']),
      parentFolderId: (json['parentFolderId'] as num?)?.toInt(),
      parentFolderName: json['parentFolderName'] as String?,
      isSpecialFolder: _parseBool(json['isSpecialFolder']),
      isBundle: _parseBool(json['isBundle']),
      icon: _parseIconKey(json['icon']),
      iconColor: _parseIconColor(json['iconColor']),
    );
  }

  /// 아이콘 키로 받아들이는 모양: 소문자·밑줄 1~32자. folder_icons.dart의 키는 전부 이
  /// 모양이고, 표에 아직 없는 '모양은 맞는' 키(다른 앱 버전이 만든 것)는 그대로 보존한다.
  /// 모양이 틀린 값은 버린다 — 조작된 .mra가 수 MB짜리 문자열을 넣으면 그 행이 Android
  /// CursorWindow의 "row too big"을 일으켜 폴더 조회가 매번 실패한다(검증 L3).
  /// ⚠️ 키 길이/문자 집합을 넓힐 때는 folder_test의 icon 경계 테스트를 함께 볼 것.
  static final RegExp _iconKeyPattern = RegExp(r'^[a-z_]{1,32}$');

  /// JSON value → 아이콘 키. 폴더 파싱은 import의 try 바깥에서 도니(Folder.fromJson이
  /// 던지면 가져오기 전체가 죽는다) 이 두 필드는 타입이 틀려도 던지지 않고 null로 본다.
  static String? _parseIconKey(dynamic value) =>
      value is String && _iconKeyPattern.hasMatch(value) ? value : null;

  /// JSON value → ARGB 색. 0..0xFFFFFFFF 범위의 **정수값**만 받는다. 그 밖은 전부
  /// null(테마 기본색): NaN/±Infinity(JSON `1e400`은 Infinity로 읽히고, 이 값의 toInt()는
  /// UnsupportedError를 던져 가져오기 전체를 죽인다 — 검증 L1), 음수, 32비트 초과,
  /// 소수(1.5처럼 ARGB가 될 수 없는 값. 버림하면 0x00000001 같은 투명색이 돼 아이콘이
  /// 안 보이므로 기본색으로 되돌리는 쪽이 낫다). 4280391411.0처럼 정수값인 실수는 받는다.
  /// 범위 비교를 toInt() 앞에서 하는 이유: 유한하지만 아주 큰 실수(1e300)의 toInt()는
  /// 플랫폼마다 동작이 다르다.
  static int? _parseIconColor(dynamic value) {
    if (value is! num || !value.isFinite) return null;
    if (value < 0 || value > 0xFFFFFFFF) return null;
    if (value % 1 != 0) return null;
    return value.toInt();
  }

  /// JSON value → bool (handles bool, int 0/1, String "true"/"1", null)
  static bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == '1';
    return false;
  }

  /// Dart → .memk JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'cardCount': cardCount,
      'folderCount': folderCount,
      'sequence': sequence,
      'originalSequence': originalSequence,
      'modified': modified,
      'parent': parent,
      'parentFolderId': parentFolderId,
      'parentFolderName': parentFolderName,
      'isSpecialFolder': isSpecialFolder,
      'isBundle': isBundle,
      'icon': icon,
      'iconColor': iconColor,
      'isDirty': false,
      'isSelected': false,
    };
  }

  /// SQLite row → Dart (snake_case 키)
  factory Folder.fromDb(Map<String, dynamic> map) {
    return Folder(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      cardCount: map['card_count'] as int? ?? 0,
      folderCount: map['folder_count'] as int? ?? 0,
      sequence: map['sequence'] as int? ?? 0,
      originalSequence: map['original_sequence'] as int? ?? 0,
      modified: map['modified'] as String?,
      parent: (map['parent'] as int? ?? 0) == 1,
      parentFolderId: map['parent_folder_id'] as int?,
      parentFolderName: map['parent_folder_name'] as String?,
      isSpecialFolder: (map['is_special_folder'] as int? ?? 0) == 1,
      isBundle: (map['is_bundle'] as int? ?? 0) == 1,
      icon: map['icon'] as String?,
      iconColor: map['icon_color'] as int?,
    );
  }

  /// Dart → SQLite row
  Map<String, dynamic> toDb() {
    final map = <String, dynamic>{
      'name': name,
      'card_count': cardCount,
      'folder_count': folderCount,
      'sequence': sequence,
      'original_sequence': originalSequence,
      'modified': modified,
      'parent': parent ? 1 : 0,
      'parent_folder_id': parentFolderId,
      // parent_folder_name은 여기서 안 쓴다. 그 컬럼은 실제로 존재하지만(레거시,
      // database_helper.dart의 CREATE TABLE 참고) 믿을 수 없는 값이다 — 묶음 편집은
      // parent_folder_id만 UPDATE하므로 이 컬럼은 이름이 바뀌어도 낡은 채 남는다.
      // 그래서 getNonBundleFolders/getChildFolders는 이 컬럼을 아예 안 읽고 LEFT
      // JOIN으로 그때그때 새로 채운다. getAllFolders()는 `SELECT *`라 원본 컬럼을
      // 그대로 읽지만, **그 결과에서 parentFolderName을 읽는 코드는 현재 하나도
      // 없다**(읽는 곳은 folderDisplayPath 하나뿐이고 그건 JOIN이 채운 값을 받는다).
      // 그러니 이건 지금 터지는 버그가 아니라 지뢰다: 조회로 받은(JOIN이 채운) Folder를
      // 여기서 되쓰면 그 순간의 부모 이름이 원본 컬럼에 영구 고정되고, 나중에 누가
      // getAllFolders() 결과에서 이 값을 읽기 시작하면 낡은 이름을 보게 된다 —
      // updateFolder를 지운 이유였던 D1-03/D8-09가 다른 경로로 돌아온다.
      'is_special_folder': isSpecialFolder ? 1 : 0,
      'is_bundle': isBundle ? 1 : 0,
      'icon': icon,
      'icon_color': iconColor,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }

  Folder copyWith({
    int? id,
    String? name,
    int? cardCount,
    int? folderCount,
    int? sequence,
    int? originalSequence,
    Object? modified = _absent,
    bool? parent,
    Object? parentFolderId = _absent,
    Object? parentFolderName = _absent,
    bool? isSpecialFolder,
    bool? isBundle,
    Object? icon = _absent,
    Object? iconColor = _absent,
  }) {
    return Folder(
      id: id ?? this.id,
      name: name ?? this.name,
      cardCount: cardCount ?? this.cardCount,
      folderCount: folderCount ?? this.folderCount,
      sequence: sequence ?? this.sequence,
      originalSequence: originalSequence ?? this.originalSequence,
      modified: identical(modified, _absent) ? this.modified : modified as String?,
      parent: parent ?? this.parent,
      parentFolderId: identical(parentFolderId, _absent)
          ? this.parentFolderId
          : parentFolderId as int?,
      parentFolderName: identical(parentFolderName, _absent)
          ? this.parentFolderName
          : parentFolderName as String?,
      isSpecialFolder: isSpecialFolder ?? this.isSpecialFolder,
      isBundle: isBundle ?? this.isBundle,
      icon: identical(icon, _absent) ? this.icon : icon as String?,
      iconColor:
          identical(iconColor, _absent) ? this.iconColor : iconColor as int?,
    );
  }
}
