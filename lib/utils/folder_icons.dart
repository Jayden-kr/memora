import 'package:flutter/material.dart';

/// 폴더 아이콘 규칙. 폴더 아이콘은 이제 두 가지뿐이다: 기본 아이콘(폴더/묶음 폴더)과 사용자가
/// 직접 넣은 글자·이모지('t:…', [Folder.iconTextOf] — FolderIconView가 그린다).
///
/// 예전에는 여기에 24개짜리 키→아이콘 표(`folderIcons`)가 있었고 DB/.mra에는 키 문자열('star' 등)이
/// 저장됐다. 표는 사용자 요청(2026-10-06)으로 없앴지만 **저장된 키는 지우지 않는다** — 옛 데이터·
/// 가져오기/내보내기는 그대로 키를 읽고 쓰고(Folder 모델), 그릴 때만 기본 아이콘으로 떨어진다.
///
/// ⚠️ 아이콘 값은 반드시 `Icons.*` 상수로만 적는다. 코드포인트를 숫자로 직접 만든 아이콘
/// 객체는 릴리스 빌드의 아이콘 폰트 트리 셰이킹이 막혀 빌드가 실패한다
/// (테스트: folder_icons_test의 소스 스캔).
/// 폴더가 그릴 머티리얼 아이콘 — 묶음 여부에 맞는 기본 아이콘이다. [key]는 무엇이든(null,
/// 예전 표의 키 'star'·'heart' 등, 다른 버전이 만든 모르는 키, 빈 문자열, 't:…') 같은 기본
/// 아이콘으로 떨어진다 — 저장된 키가 화면을 깨뜨리면 안 되고, DB에 있는 키 자체는 건드리지
/// 않는다. 글자 아이콘('t:…')의 글자는 FolderIconView가 그린다.
IconData folderIconData(String? key, {required bool isBundle}) =>
    isBundle ? Icons.folder_special : Icons.folder;

/// 폴더 아이콘 색. null이면 테마 기본색(밝은/어두운 테마를 따라간다), 값이 있으면
/// 사용자가 고른 색을 테마와 무관하게 그대로 쓴다.
///
/// 알파는 항상 0xFF로 올린다: 폴더 아이콘 색은 불투명만 의미가 있는데(선택 창이 투명도를
/// 감춘다), 다른 경로(가져온 데이터 등)로 알파 0이 저장돼 있으면 `Color(argb)`를 그대로
/// 쓸 때 아이콘이 보이지 않게 된다.
Color folderIconColor(int? argb, ColorScheme scheme) =>
    argb == null ? scheme.primary : Color(argb | 0xFF000000);
