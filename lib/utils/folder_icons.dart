import 'package:flutter/material.dart';

/// 폴더 아이콘 목록. DB/.mra에는 코드포인트가 아니라 **키 문자열**을 저장한다 —
/// 코드포인트는 Flutter/머티리얼 아이콘 폰트가 바뀌면 다른 그림을 가리킬 수 있지만
/// 키는 이 표만 고치면 되기 때문이다.
///
/// ⚠️ 키는 저장된 데이터와의 약속이다. 이름을 바꾸거나 지우면 이미 그 키로 저장된
/// 폴더가 기본 아이콘으로 돌아간다. 추가만 할 것(순서는 선택 창에 보이는 순서).
/// ⚠️ 값은 반드시 `Icons.*` 상수로만 적는다. 코드포인트를 숫자로 직접 만든 아이콘
/// 객체는 릴리스 빌드의 아이콘 폰트 트리 셰이킹이 막혀 빌드가 실패한다
/// (테스트: folder_icons_test의 소스 스캔).
/// ⚠️ DB 값은 null / 이 표의 키 / 't:'+글자(Folder.iconTextOf) 셋 중 하나다. 키에 ':'를
/// 쓰지 말 것 — 키와 글자 두 모양이 안 겹친다는 전제다(folder_icons_test가 고정).
const Map<String, IconData> folderIcons = {
  'book': Icons.menu_book,
  'language': Icons.translate,
  'star': Icons.star,
  'heart': Icons.favorite,
  'school': Icons.school,
  'science': Icons.science,
  'music': Icons.music_note,
  'work': Icons.work,
  'idea': Icons.lightbulb,
  'flag': Icons.flag,
  'bookmark': Icons.bookmark,
  'math': Icons.calculate,
  'code': Icons.code,
  'globe': Icons.public,
  'mind': Icons.psychology,
  'history': Icons.history_edu,
  'art': Icons.palette,
  'sports': Icons.sports_soccer,
  'travel': Icons.flight,
  'medical': Icons.medical_services,
  'pets': Icons.pets,
  'food': Icons.restaurant,
  'chat': Icons.chat_bubble,
  'home': Icons.home,
};

/// 폴더가 그릴 아이콘. 키가 없거나(null) 표에 없으면(다른 버전이 만든 키, 빈 문자열
/// 등) 묶음 여부에 맞는 기본 아이콘으로 떨어진다 — 알 수 없는 키가 화면을 깨뜨리면
/// 안 된다. DB에 있는 키 자체는 건드리지 않는다.
/// 글자 아이콘('t:…')도 키가 아니므로 여기선 기본 아이콘이다 — 글자는 FolderIconView가
/// 그린다. 키만 아는 빌드는 이 폴백 덕에 글자 아이콘 폴더도 기본 아이콘으로 보여 준다.
IconData folderIconData(String? key, {required bool isBundle}) =>
    folderIcons[key] ?? (isBundle ? Icons.folder_special : Icons.folder);

/// 폴더 아이콘 색. null이면 테마 기본색(밝은/어두운 테마를 따라간다), 값이 있으면
/// 사용자가 고른 색을 테마와 무관하게 그대로 쓴다.
///
/// 알파는 항상 0xFF로 올린다: 폴더 아이콘 색은 불투명만 의미가 있는데(선택 창이 투명도를
/// 감춘다), 다른 경로(가져온 데이터 등)로 알파 0이 저장돼 있으면 `Color(argb)`를 그대로
/// 쓸 때 아이콘이 보이지 않게 된다.
Color folderIconColor(int? argb, ColorScheme scheme) =>
    argb == null ? scheme.primary : Color(argb | 0xFF000000);
