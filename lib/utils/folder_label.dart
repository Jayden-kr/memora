import '../models/folder.dart';

/// 폴더 선택 목록에 쓰는 표시 이름. 묶음에 속한 폴더는 `묶음 이름 > 폴더 이름`으로
/// 보여준다 — 홈 화면에서 묶음 자식이 숨겨진 뒤로는 이 경로가 없으면 같은 이름의
/// 폴더 둘을 구분할 수 없다.
///
/// [Folder.parentFolderName]은 조회 함수(`getNonBundleFolders`/`getChildFolders`)가
/// 묶음 행에서 JOIN으로 채워준다. 비어 있으면 최상위 폴더로 보고 이름만 돌려준다.
/// ⚠️ 이 값을 [Text]로 그릴 땐 `maxLines: 1`을 함께 줄 것. maxLines가 없으면 ellipsis는 '줄바꿈이 불가능한 한 덩어리'일 때만 잘린다. `묶음 > 폴더`처럼 공백이 있는 문자열은 대신 두 줄로 접히는데, DropdownMenuItem은 높이가 고정(48dp)이라 두 번째 줄이 칸 밖으로 삐져나온다(리뷰 P4-01).
String folderDisplayPath(Folder folder) {
  final bundle = folder.parentFolderName;
  if (bundle == null || bundle.isEmpty) return folder.name;
  return '$bundle > ${folder.name}';
}
