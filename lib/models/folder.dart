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
    );
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
    );
  }
}
