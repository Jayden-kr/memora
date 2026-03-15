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
      name: map['name'] as String,
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
      'parent_folder_name': parentFolderName,
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
      modified: modified == _absent ? this.modified : modified as String?,
      parent: parent ?? this.parent,
      parentFolderId: parentFolderId == _absent
          ? this.parentFolderId
          : parentFolderId as int?,
      parentFolderName: parentFolderName == _absent
          ? this.parentFolderName
          : parentFolderName as String?,
      isSpecialFolder: isSpecialFolder ?? this.isSpecialFolder,
      isBundle: isBundle ?? this.isBundle,
    );
  }
}
