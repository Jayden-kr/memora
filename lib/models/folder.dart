import 'package:characters/characters.dart';

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

  /// 폴더 아이콘. 세 모양 중 하나다.
  ///  - null: 기본 아이콘
  ///  - 옛 키(예: 'star'): 예전 키→아이콘 표가 저장해 둔 값. 표는 없어졌으므로 그릴 때는
  ///    기본 아이콘이다(folderIconData). [_iconKeyPattern] 모양이면 그대로 보존한다
  ///    (옛 데이터·다른 앱 버전과의 왕복에서 값을 잃지 않게). 키는 ':'를 갖지 않는다.
  ///  - 't:' + 글자(예: 't:🇮🇱', 't:א', 't:EN'): 사용자가 직접 넣은 이모지·글자 1~2개.
  ///    글자는 [iconTextOf]로 꺼낸다.
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
      icon: _parseIcon(json['icon']),
      iconColor: _parseIconColor(json['iconColor']),
    );
  }

  /// 아이콘 키로 받아들이는 모양: 소문자·밑줄 1~32자. 예전 표의 키는 전부 이 모양이었고,
  /// 모양이 맞는 키(옛 데이터·다른 앱 버전이 만든 것)는 그릴 수 없어도 그대로 보존한다.
  /// 모양이 틀린 값은 버린다 — 조작된 .mra가 수 MB짜리 문자열을 넣으면 그 행이 Android
  /// CursorWindow의 "row too big"을 일으켜 폴더 조회가 매번 실패한다(검증 L3).
  /// ⚠️ 키 길이/문자 집합을 넓힐 때는 folder_test의 icon 경계 테스트를 함께 볼 것.
  static final RegExp _iconKeyPattern = RegExp(r'^[a-z_]{1,32}$');

  /// 글자 아이콘 저장값의 접두사. 영구 약속이다: 이미 이 접두사로 저장된 폴더가 있으니
  /// 바꾸면 그 폴더의 글자가 사라진다. 키는 ':'를 쓰지 않으므로([_iconKeyPattern]이
  /// 소문자·밑줄만 받는다) 키와 글자 모양이 절대 겹치지 않는다 — 글자 'en'을 접두사 없이 저장하면
  /// 모르는 키 'en'과 구분이 안 되기 때문에 접두사는 필수다.
  static const String iconTextPrefix = 't:';

  /// 글자 아이콘이 가질 수 있는 최대 글자 수(그래핌 = 사용자가 보는 글자 단위).
  static const int iconTextMaxGraphemes = 2;

  /// 글자 아이콘 UTF-16 코드 단위 상한. 가족 이모지 2개(22)·스코틀랜드 깃발 2개(28)·
  /// 피부색 키스(30)가 들어가는 크기이고, 조작된 .mra의 수 MB 문자열이나 결합문자 도배
  /// (zalgo)는 막는다. 길이를 가장 먼저 본다(아래 두 함수 모두 — 수 MB를 훑지 않게).
  static const int iconTextMaxCodeUnits = 32;

  /// 입력 → 저장할 글자(앞뒤 공백 제거) 또는 null(쓸 수 없음). 던지지 않는다.
  static String? normalizeIconText(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.length > iconTextMaxCodeUnits) return null; // 길이 먼저(수 MB 방어)
    var visible = false;
    for (final r in text.runes) {
      if (_isForbiddenIconRune(r)) return null;
      if (!isInvisibleIconRune(r)) visible = true;
    }
    if (!visible) return null; // 안 보이는 아이콘 금지(folder_icons.dart의 알파 0 보정과 같은 약속)
    if (text.characters.length > iconTextMaxGraphemes) return null;
    return text;
  }

  /// 저장값 → 그릴 글자. 't:' + 정규형 글자일 때만 글자를 주고, 그 밖(null·키·규칙
  /// 위반)은 null. 한도는 읽을 때 검사한다(가져오기·그리기 모두 이 함수를 지난다).
  static String? iconTextOf(String? stored) {
    if (stored == null || !stored.startsWith(iconTextPrefix)) return null;
    if (stored.length > iconTextPrefix.length + iconTextMaxCodeUnits) return null;
    final text = stored.substring(iconTextPrefix.length);
    return normalizeIconText(text) == text ? text : null; // 정규형만(' star' 거부와 같은 규칙)
  }

  // C0·DEL·C1(개행·탭 포함), 줄/문단 구분자, 짝 없는 서로게이트(.runes가 그대로 줌)
  static bool _isForbiddenIconRune(int r) =>
      r <= 0x1F ||
      (r >= 0x7F && r <= 0x9F) ||
      r == 0x2028 ||
      r == 0x2029 ||
      (r >= 0xD800 && r <= 0xDFFF);

  /// 그려지는 게 없는 서식·채움 문자: 이것만 있으면 안 보이는 아이콘(한글 채움 U+3164,
  /// 점자 빈칸 U+2800, 크메르 내재 모음 U+17B4·U+17B5, 속기 서식 U+1BCA0–1BCA3 포함).
  /// 표의 모든 항목(범위는 양 끝)을 folder_test가 직접 본다 — U+FEFF는 trim()이 먼저
  /// 벗겨 normalizeIconText로는 닿지 않으니 이 함수를 공개해 직접 확인한다. 표를 고치면
  /// 그 테스트의 표도 같이 고칠 것.
  static bool isInvisibleIconRune(int r) =>
      r == 0x00AD ||
      r == 0x034F ||
      r == 0x061C ||
      r == 0x115F ||
      r == 0x1160 ||
      r == 0x17B4 ||
      r == 0x17B5 ||
      (r >= 0x180B && r <= 0x180F) ||
      (r >= 0x1BCA0 && r <= 0x1BCA3) ||
      (r >= 0x200B && r <= 0x200F) ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2060 && r <= 0x206F) ||
      r == 0x2800 ||
      r == 0x3164 ||
      (r >= 0xFE00 && r <= 0xFE0F) ||
      r == 0xFEFF ||
      r == 0xFFA0 ||
      (r >= 0x1D173 && r <= 0x1D17A) ||
      (r >= 0xE0000 && r <= 0xE0FFF);

  /// JSON value → 아이콘(키 또는 't:' 글자). 폴더 파싱은 import의 try 바깥에서 도니
  /// (Folder.fromJson이 던지면 가져오기 전체가 죽는다) 이 두 필드는 타입이 틀려도
  /// 던지지 않고 null로 본다.
  /// ⚠️ 글자 아이콘 한도·문자 집합을 바꿀 때는 folder_test의 '글자 아이콘' 경계 테스트를
  /// 함께 볼 것.
  static String? _parseIcon(dynamic value) {
    if (value is! String) return null;
    if (_iconKeyPattern.hasMatch(value)) return value;
    return iconTextOf(value) == null ? null : value;
  }

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
