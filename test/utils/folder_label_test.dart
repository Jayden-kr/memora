// 폴더 표시 경로(lib/utils/folder_label.dart) 검증.
//
// 홈 화면이 묶음 자식을 감추게 된 뒤로, 폴더 선택 목록에서 같은 이름의 폴더 둘을
// 구분할 방법이 이 경로 표기뿐이다.
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/models/folder.dart';
import 'package:memora/utils/folder_label.dart';

void main() {
  group('folderDisplayPath', () {
    test('묶음에 속하면 "묶음 > 폴더"로 보여준다', () {
      final f = Folder(id: 2, name: '단어', parentFolderId: 1, parentFolderName: '영어');
      expect(folderDisplayPath(f), '영어 > 단어');
    });

    test('최상위 폴더는 이름만 보여준다', () {
      expect(folderDisplayPath(Folder(id: 3, name: '단어')), '단어');
    });

    test('묶음 이름이 비어 있으면 이름만 보여준다', () {
      // 존재하지 않는 묶음을 가리키는 고아 폴더는 JOIN이 null을 준다 — 여기서
      // "null > 단어" 같은 문자열이 새면 안 된다.
      expect(
        folderDisplayPath(
            Folder(id: 4, name: '단어', parentFolderId: 999, parentFolderName: '')),
        '단어',
      );
      expect(
        folderDisplayPath(Folder(id: 5, name: '단어', parentFolderId: 999)),
        '단어',
      );
    });
  });
}
