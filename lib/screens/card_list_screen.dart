import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
// material.dart는 RenderSliverMultiBoxAdaptor를 내보내지 않는다 — 소량 목록(ListView)의
// 보이는 칸 위치를 렌더 트리에서 직접 읽어야 해서 필요하다 (card_edit_screen.dart와 같은 이유).
// 대량 목록의 "target보다 위쪽 칸인가"(역방향 sliver)를 렌더 트리에서 읽는 데도 쓴다
// (GrowthDirection·RenderSliver, laidOutAboveListTarget). 누른 칸의 위치를 목록 뷰포트 기준으로
// 렌더 트리에서 직접 읽는 데도 쓴다(RenderAbstractViewport, tappedItemEdges).
import 'package:flutter/rendering.dart'
    show
        GrowthDirection,
        RenderAbstractViewport,
        RenderSliver,
        RenderSliverMultiBoxAdaptor;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../database/database_helper.dart';
import '../services/audio_playback_controller.dart';
import '../l10n/app_localizations.dart';
import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';
import '../utils/folder_label.dart';
import '../app.dart' show routeObserver;
import '../widgets/card_tile.dart';
import '../widgets/confirm_delete_dialog.dart';
import '../widgets/folder_name_dialog.dart';
import 'card_edit_screen.dart';

/// 화면에 보이는 칸 중 맨 위(인덱스가 가장 작은) 칸의 인덱스. 보이는 칸이 없으면 null.
///
/// [positions]는 순서가 보장되지 않으므로 첫 원소가 아니라 최솟값을 고른다.
/// 뒤쪽 가장자리가 0 이하인 칸은 화면 위로 완전히 지나간 칸이라 제외한다
/// (_currentVisibleIndex·_onItemPositionsChanged의 `itemTrailingEdge > 0`과 같은 기준).
@visibleForTesting
int? firstVisibleItemIndex(Iterable<ItemPosition> positions) {
  int? best;
  for (final p in positions) {
    if (p.itemTrailingEdge <= 0) continue; // 화면 위로 완전히 지나간 칸 제외
    if (best == null || p.index < best) best = p.index;
  }
  return best;
}

/// 닫기 직전 검색 결과 목록에서 [index]번째 칸의 카드 id. 범위 밖이거나 [index]가 null이면 null.
///
/// 화면 맨 위에 보이던 결과(인덱스)를 "카드 id"로 바꿔 둔다 — 인덱스는 결과 목록 기준이라
/// 전체 목록이 올라온 뒤에는 의미가 없고, 카드 id만 전체 목록에서 다시 찾을 수 있다.
@visibleForTesting
int? resultIdAt(List<int?> resultIds, int? index) {
  if (index == null || index < 0 || index >= resultIds.length) return null;
  return resultIds[index];
}

/// 검색을 닫을 때 전체 목록에서 맨 위에 둘 카드의 id를 고른다.
///
/// 우선순위: 마지막으로 누른 카드 > 닫기 직전 화면 맨 위에 보이던 결과 > 없음(null).
/// 두 후보 모두 **다시 불러온 전체 목록([fullListIds])에 있을 때만** 쓴다 — 결과 목록이 아니라
/// 전체 목록 기준이다. 누른 카드를 편집해 검색어와 안 맞게 돼서 결과에서는 사라졌어도 전체
/// 목록에는 그대로 있으니 그 카드에 머물러야 한다. 전체 목록에도 없으면(삭제·이동) 다음 후보로
/// 넘어간다. 둘 다 없으면 null이고, 호출자가 목록 맨 위로 보낸다.
@visibleForTesting
int? pickSearchExitAnchor({
  required int? tappedCardId,
  required int? firstVisibleCardId,
  required Iterable<int?> fullListIds,
}) {
  if (tappedCardId != null && fullListIds.contains(tappedCardId)) {
    return tappedCardId;
  }
  if (firstVisibleCardId != null && fullListIds.contains(firstVisibleCardId)) {
    return firstVisibleCardId;
  }
  return null;
}

/// 새 검색 결과 묶음이 올라왔을 때 계속 들고 갈 "누른 카드" id.
///
/// 검색어를 한 글자씩 지우면("apple"→"appl"→…→"") 글자마다 새 결과 묶음이 올라온다. 누른 카드가
/// 새 결과에도 있으면 그 카드를 계속 앵커로 둔다 — 묶음마다 앵커를 비우면 검색을 닫을 때 누른
/// 카드가 아니라 맨 위 결과로 가 버린다. 새 결과에 없으면 null(앵커는 "지금 떠 있는 결과에서
/// 누른 카드"일 때만 의미가 있고, 없는 카드를 쥐고 있으면 안 눌렀을 때의 규칙으로 못 돌아간다).
@visibleForTesting
int? keepAnchorForNewResults({
  required int? tappedCardId,
  required Iterable<int?> newResultIds,
}) {
  if (tappedCardId != null && newResultIds.contains(tappedCardId)) {
    return tappedCardId;
  }
  return null;
}

/// 누른 카드를 화면에서 그 자리에 붙잡아 둘 정렬값(뷰포트 대비 위쪽 가장자리 비율).
///
/// ScrollablePositionedList는 target 카드의 위쪽 가장자리를 이 정렬 위치에 두고 배치한다.
/// 이 목록의 뷰포트는 0~1 밖의 값도 받아들이므로 범위 제한 때문에 막는 것은 아니다.
/// 이 함수는 **화면 안(0~1)** 정렬값만 돌려주고, 위로 잘린 카드(음수)는 null이다 — 위로 잘린 카드의
/// 위쪽 가장자리 붙잡기는 [topPinAlignmentFor]가 맡는다.
///
/// 접기/보이기가 붙잡는 규칙 ([resizePinFor]가 의도별로 고른다):
/// - 질문 탭(접기/펴기)·답 보이기(커짐): **누른 카드의 위쪽 가장자리를 항상 고정**한다. 위쪽이 잘려
///   있어도 마찬가지다 — 아래쪽을 고정하면 손가락이 보던 질문 줄이 카드와 함께 위로 밀려 나가거나
///   (펴기) 손가락 밑이 윗 카드가 된다(접기). target 이상 칸(정방향 sliver)은 원래 위쪽이 고정이라
///   그대로 두고, target 위쪽 칸(역방향 sliver)만 그 카드를 지금 위치 그대로 target으로 삼아 다시 마운트한다.
/// - 답 숨기기(줄어듦): 위로 잘렸고 아래쪽이 화면 안이면 **아래쪽 가장자리**를 고정한다(위쪽을 화면
///   밖에 고정하면 줄어든 카드가 통째로 위로 사라져 손가락 밑이 다음 카드가 된다). target 위쪽 칸은 원래
///   아래쪽이 고정이라 그대로 두고, target 이상 칸은 다음 칸을 이 카드의 아래쪽 가장자리에 맞춰
///   target으로 삼는다. 그 밖(위쪽이 화면 안)은 위쪽 가장자리를 고정한다.
/// 화면 아래로 벗어난 카드(1 초과)는 눌릴 수 없다. NaN도 null이어야 한다.
@visibleForTesting
double? pinAlignmentFor(double itemLeadingEdge) =>
    (itemLeadingEdge >= 0 && itemLeadingEdge <= 1) ? itemLeadingEdge : null;

/// 위쪽 가장자리를 그 자리에 붙잡을 정렬값 — [pinAlignmentFor]와 달리 **위로 잘린 카드(음수)도** 허용한다.
/// 카드가 조금이라도 보여야(아래쪽 가장자리 > 0) 하고 위쪽이 화면 아래로 벗어나지(> 1) 않아야 한다.
/// NaN·무한대는 null. (SPL 뷰포트 anchor는 음수도 받아들이고, 스크롤 범위도 그만큼 넓혀 준다 — 테스트로 확인.)
@visibleForTesting
double? topPinAlignmentFor(double itemLeadingEdge, double itemTrailingEdge) {
  if (!itemLeadingEdge.isFinite || !itemTrailingEdge.isFinite) return null;
  if (itemTrailingEdge <= 0 || itemLeadingEdge > 1) return null;
  return itemLeadingEdge;
}

/// 접기/보이기 탭의 종류. [resizePinFor]가 기하(잘림 여부)로 짐작하지 않고 호출자가 말해 주는 의도로
/// 붙잡는 방식을 고른다 (잘린 카드의 질문 탭을 "줄어드는 탭"으로 오해하면 손가락 밑 카드가 바뀐다).
enum CardResizeKind {
  /// 질문 탭(접기/펴기). 늘어나든 줄어들든 위쪽 가장자리를 고정한다.
  questionToggle,

  /// 답 보이기(숨김 모드에서 가려진 답을 펼침, 카드가 커짐). 위쪽 가장자리를 고정한다.
  answerReveal,

  /// 답 숨기기(숨김 모드에서 보이던 답을 가림, 카드가 줄어듦). 위로 잘리고 아래쪽이 화면 안이면
  /// 아래쪽 가장자리를 고정하고, 아니면 위쪽 가장자리를 고정한다.
  answerHide,
}

/// 답 영역 탭이 어떤 붙잡기를 해야 하는가. 붙잡을 필요가 없으면 null.
///
/// ⚠️ 숨김 모드([allAnswersHidden])가 아니면 답은 항상 보여서 이 탭은 카드 높이를 바꾸지 않는다 — 붙잡으면
/// 목록을 다시 마운트해 물결·접근성 포커스만 끊으니 null이어야 한다. 숨김 모드에서는 지금 보이는 답을
/// 가리는 탭([answerRevealed] true)이 줄어듦(answerHide), 가려진 답을 펼치는 탭이 커짐(answerReveal)이다.
@visibleForTesting
CardResizeKind? answerTapResizeKind({
  required bool allAnswersHidden,
  required bool answerRevealed,
}) {
  if (!allAnswersHidden) return null;
  return answerRevealed ? CardResizeKind.answerHide : CardResizeKind.answerReveal;
}

/// 접기/보이기로 [tappedIndex] 카드 높이가 바뀔 때 target을 누른 카드로 옮겨 붙잡아야 하는가.
///
/// ScrollablePositionedList는 target 카드부터 아래쪽을 target 위쪽 가장자리에서 아래로 쌓고,
/// target 위쪽 칸들은 target에서 위로 쌓는다. 그래서 target 이하 칸(인덱스 ≥ target)은 높이가
/// 바뀌어도 위쪽 가장자리가 움직이지 않고, target보다 위에 있는 칸(인덱스 < target)만 위쪽으로
/// 자라거나 줄어들어 손가락 밑 카드가 바뀐다. 필요 없는데 target을 바꾸면 보이는 칸이 전부
/// 다시 만들어져 물결(ripple)이 끊기고 접근성(TalkBack) 포커스를 잃는다.
///
/// [targetIndex]는 화면이 마지막으로 지정한 값이라 목록이 줄어든 뒤에는 실제 target보다 클 수
/// 있다(SPL은 itemCount - 1로 줄여 쓴다) — 같은 규칙으로 줄여서 비교한다.
@visibleForTesting
bool tappedCardNeedsPin({
  required int tappedIndex,
  required int targetIndex,
  required int itemCount,
}) {
  if (itemCount <= 0 || tappedIndex < 0 || tappedIndex >= itemCount) {
    return false;
  }
  return tappedIndex < targetIndex.clamp(0, itemCount - 1);
}

/// [itemContext]의 칸이 ScrollablePositionedList의 target보다 위쪽(역방향으로 자라는 sliver)에
/// 놓여 있는가. target 위쪽 칸만 높이가 바뀔 때 아래쪽 가장자리가 고정되고(위쪽 가장자리가 움직임),
/// target 이상 칸은 위쪽 가장자리가 고정된다 — 붙잡아야 하는 칸을 렌더 트리에서 직접 판별한다.
/// [itemContext]는 칸 안쪽(Builder)의 BuildContext여야 하고, 레이아웃이 끝난 칸이어야 한다.
@visibleForTesting
bool laidOutAboveListTarget(BuildContext itemContext) {
  RenderObject? node = itemContext.findRenderObject()?.parent;
  while (node != null && node is! RenderSliver) {
    node = node.parent;
  }
  return node is RenderSliver &&
      node.constraints.growthDirection == GrowthDirection.reverse;
}

/// 누른 칸([itemContext])의 위/아래 가장자리를 목록 뷰포트 높이 대비 비율로 돌려준다.
///
/// ⚠️ 위치는 **렌더 트리에서 지금 값**을 읽는다. [positions](ItemPositionsListener)는 스크롤이나
/// 새 레이아웃 때만 갱신돼서, 스크롤 없이 칸 높이만 바뀌면(예: 이미지 디코딩이 끝나 카드가 커짐) 낡은
/// 값이 남는다 — 그 값으로 붙잡으면 카드가 그만큼 튄다. 렌더 트리를 못 읽을 때(안 붙음·크기 없음·
/// 뷰포트 없음)만 [positions]의 [index] 칸으로 대신하고, 거기에도 없으면 null.
@visibleForTesting
({double leading, double trailing})? tappedItemEdges({
  required BuildContext itemContext,
  required Iterable<ItemPosition> positions,
  required int index,
}) {
  if (itemContext.mounted) {
    final box = itemContext.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      // RenderAbstractViewport는 인터페이스라 RenderBox로 승격이 안 된다 — RenderObject로 받는다.
      final RenderObject? viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport is RenderBox && viewport.hasSize && viewport.size.height > 0) {
        final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
        final h = viewport.size.height;
        return (leading: top / h, trailing: (top + box.size.height) / h);
      }
    }
  }
  for (final p in positions) {
    if (p.index == index) {
      return (leading: p.itemLeadingEdge, trailing: p.itemTrailingEdge);
    }
  }
  return null;
}

/// 접기/보이기로 [index] 칸 높이가 바뀌기 전에, 그 칸을 화면 그 자리에 붙잡을 정렬값. 붙잡을 필요가
/// 없거나(target 이상 칸) 붙잡을 수 없으면(화면 밖·위로 잘림, pinAlignmentFor가 null) null.
///
/// target 이상 칸은 어차피 위쪽 가장자리가 안 움직이므로 건드리지 않는다 — 건드리면 보이는 칸이
/// 전부 다시 만들어져 물결·접근성 포커스가 끊긴다([tappedCardNeedsPin]).
/// 위치는 [tappedItemEdges](렌더 트리 우선)로 읽는다.
@visibleForTesting
double? reanchorAlignmentBeforeResize({
  required BuildContext itemContext,
  required Iterable<ItemPosition> positions,
  required int index,
}) {
  if (!laidOutAboveListTarget(itemContext)) return null;
  final edges =
      tappedItemEdges(itemContext: itemContext, positions: positions, index: index);
  return edges == null ? null : pinAlignmentFor(edges.leading);
}

/// 접기/보이기로 [index] 칸 높이가 바뀌기 직전에, 목록을 어느 칸을 어디에 두고 다시 마운트해야
/// 눌린 카드가 손가락 밑에 남는지. 다시 마운트할 필요가 없으면 null.
///
/// 붙잡는 방식은 호출자가 넘기는 [kind](의도)로 정한다 — 잘림 같은 기하로 짐작하지 않는다.
/// ⚠️ 위로 잘린 카드의 **질문 탭**은 손가락이 보이는 질문 줄 위에 있다. 이걸 "줄어드는 카드"로 보고
/// 아래쪽 가장자리를 고정하면 접을 때 카드가 아래로 밀려 손가락 밑이 윗 카드가 되고, 펼 때는 질문 줄이
/// 화면 위로 밀려 나간다(실카드 검증으로 확인). 질문 탭·답 보이기는 항상 위쪽 가장자리 고정이다.
///
/// 위쪽 가장자리 고정([CardResizeKind.questionToggle]·[CardResizeKind.answerReveal],
/// [CardResizeKind.answerHide]의 기본):
/// - target 이상 칸(정방향 sliver): 위쪽이 원래 고정이라 잘렸든 아니든 그대로 둔다 (null).
/// - target 위쪽 칸(역방향 sliver, [laidOutAboveListTarget]): 아래쪽이 고정이고 위쪽이 움직이므로, 그 칸을
///   지금 위쪽 위치 그대로([topPinAlignmentFor], 위로 잘렸으면 음수) target으로 삼아 다시 마운트한다.
///
/// 아래쪽 가장자리 고정 ([CardResizeKind.answerHide]이면서 **위로 잘리고**(위쪽 < 0) 아래쪽이 화면
/// 안(0 < 아래쪽 <= 1)일 때만): 위쪽을 화면 밖에 고정하면 줄어든 카드가 통째로 위로 사라진다.
/// - target 위쪽 칸: 아래쪽이 원래 고정이라 그대로 둔다 (null).
/// - target 이상 칸: 다음 칸([index] + 1)을 이 카드의 **현재 아래쪽 가장자리**에 맞춰 target으로 삼는다.
///   그러면 이 카드가 target 위쪽 칸(역방향)이 되어 아래쪽이 고정된다. 마지막 칸이면 다음 칸이 없어서
///   하지 않는다 — 목록 끝이라 스크롤 범위 제한이 카드를 화면에 남긴다(테스트로 확인).
///
/// [targetIndex]는 값싼 사전 검사([tappedCardNeedsPin])에만 쓰고 최종 판단은 렌더 트리가 한다.
@visibleForTesting
({int index, double alignment})? resizePinFor({
  required BuildContext itemContext,
  required Iterable<ItemPosition> positions,
  required int index,
  required int targetIndex,
  required int itemCount,
  required CardResizeKind kind,
}) {
  if (itemCount <= 0 || index < 0 || index >= itemCount) return null;
  final edges =
      tappedItemEdges(itemContext: itemContext, positions: positions, index: index);
  if (edges == null) return null;
  final above = tappedCardNeedsPin(
        tappedIndex: index,
        targetIndex: targetIndex,
        itemCount: itemCount,
      ) &&
      laidOutAboveListTarget(itemContext);
  final bottomAnchor = kind == CardResizeKind.answerHide &&
      edges.leading < 0 &&
      edges.trailing > 0 &&
      edges.trailing <= 1;
  if (bottomAnchor) {
    if (above) return null; // 역방향 sliver는 원래 아래쪽 가장자리가 고정이다
    if (index + 1 < itemCount) {
      return (index: index + 1, alignment: edges.trailing);
    }
    return null;
  }
  // 위쪽 가장자리 고정: target 이상 칸은 원래 고정이라 건드리지 않는다.
  if (!above) return null;
  final a = topPinAlignmentFor(edges.leading, edges.trailing);
  return a == null ? null : (index: index, alignment: a);
}

// ─── 대량 목록(ScrollablePositionedList) 점프 = 다시 마운트 ───

/// ScrollablePositionedList를 [jumpTo]마다 **새로 마운트**해서 원하는 칸을 원하는 위치에 놓는다.
///
/// ⚠️ SPL(0.3.8)의 `ItemScrollController.jumpTo(index)`는 목록을 새로 만들지 않고 target만 바꾼다.
/// 그런데 지금 target에서 뷰포트 캐시 범위(뷰포트의 2배)보다 먼 칸으로 점프하면, 재활용된 SliverList
/// 칸이 옛 칸의 레이아웃 오프셋을 물려받아(그 칸에 다른 카드가 들어온다) 레이아웃이 스크롤 오프셋을
/// 보정하면서 **페이지 전체가 밀린다** (실기기·하니스에서 확인: 새 검색 결과가 맨 위가 아닌 곳에서 열림,
/// 검색을 닫은 뒤 앵커가 화면 위로 벗어남, 접기/보이기 때 누른 카드가 튐). 그래서 이 화면은 SPL
/// jumpTo를 쓰지 않고 이 컨트롤러로만 점프한다 — `ValueKey(epoch)`를 바꿔 목록을 새로 만들고
/// `initialScrollIndex`/`initialAlignment`로 시작 위치를 준다(처음 레이아웃부터 정확히 그 자리).
///
/// ⚠️ 시작 위치는 새로 만든 SPL이 읽은 뒤 바로 0으로 되돌린다([jumpTo]의 post-frame). 안 그러면
/// 스피너→목록, 소량 목록(ListView)→대량 목록 같은 "점프가 아닌" 새 마운트가 옛 시작 위치로 열린다.
/// 되돌리기는 그 사이 더 새로운 [jumpTo]가 있었으면 하지 않는다(그 점프의 시작 위치를 지우면 안 된다).
///
/// ⚠️ [build]는 SPL을 `SizedBox.expand` 안에 둔다. Stack처럼 자식 목록을 가진 부모의 "직계 자식"이
/// 키가 바뀌면 새 자식을 먼저 만든 뒤 옛 자식을 치워서, ItemScrollController에 옛 SPL이 아직 붙어
/// 있는 채로 새 SPL이 붙으려다 assert가 나고 그 뒤 isAttached가 false가 된다. 단일 자식 부모
/// 아래에서는 옛 자식을 먼저 치우므로 안전하다.
///
/// ⚠️ [build]는 SPL을 자기만의 `PageStorage`(빈 PageStorageBucket) 안에 둔다. 위쪽에 PageStorageKey가
/// 있는 화면(탭·라우트 구성이 바뀌는 경우)에서도 새로 마운트된 SPL의 ScrollPosition이 PageStorage에서
/// 옛 스크롤 위치를 복원해 `initialScrollIndex`를 이겨 버리는 것을 막는다(검증: PageStorageKey 조상이
/// 있으면 30번을 요청해도 0번에서 열렸다). 버킷은 [build]마다 새로 만들어 — 점프든 점프 아닌 새
/// 마운트든 — 새 SPL이 읽을 옛 값이 없게 한다. 이 PageStorage를 지우면 안 된다.
@visibleForTesting
class SplRemountController {
  SplRemountController({
    required this.itemScrollController,
    required this.itemPositionsListener,
  });

  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;

  int _epoch = 0;
  int _initialIndex = 0;
  double _initialAlignment = 0;
  int _targetIndex = 0;

  // 스크롤바 썸 드래그 중 마지막으로 실제로 점프한 칸·그때의 epoch ([thumbDragJumpTo]).
  int _lastDragJumpIndex = -1;
  int _lastDragJumpEpoch = -1;

  /// 목록 키. 바뀔 때마다 SPL이 새로 마운트된다.
  int get epoch => _epoch;

  /// 다음에 마운트되는 SPL의 시작 칸/정렬 (점프 직후에만 0이 아니다).
  int get initialIndex => _initialIndex;
  double get initialAlignment => _initialAlignment;

  /// SPL의 target(배치 기준 칸) 인덱스 — [jumpTo]로 마지막에 지정한 값. SPL은 target을 읽는 API가
  /// 없다. 접기/보이기 때 "누른 카드가 target 위쪽인가"(= 붙잡아야 하나)를 가르는 사전 검사에 쓴다
  /// ([tappedCardNeedsPin]). 점프가 아닌 새 마운트는 target이 0인데 이 값은 그대로라 실제보다 클
  /// 수 있는데, 그때는 붙잡을 필요 없는 카드를 사전 검사가 통과시킬 뿐이고 최종 판단은 렌더 트리
  /// ([laidOutAboveListTarget])가 한다. 실제보다 작아지는 경우는 없다(target은 [jumpTo]로만 커진다).
  int get targetIndex => _targetIndex;

  /// [index] 칸을 뷰포트 위쪽에서 [alignment](0~1) 비율 위치에 두도록 목록을 새로 마운트한다.
  /// [setState]는 이 컨트롤러를 쓰는 State의 setState (목록을 다시 빌드시킨다).
  /// 같은 프레임에 여러 번 불려도 마지막 호출만 남는다.
  void jumpTo(
    int index, {
    double alignment = 0,
    required void Function(VoidCallback fn) setState,
  }) {
    _targetIndex = index;
    final epochAtJump = ++_epoch;
    _initialIndex = index;
    _initialAlignment = alignment;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_epoch != epochAtJump) return; // 더 새로운 점프가 자기 시작 위치를 들고 있다
      _initialIndex = 0;
      _initialAlignment = 0;
    });
  }

  /// 스크롤바 썸 드래그가 시작될 때마다 부른다 — 첫 점프는 항상 실제로 한다.
  void beginThumbDrag() {
    _lastDragJumpIndex = -1;
    _lastDragJumpEpoch = -1;
  }

  /// 썸 드래그 중의 점프. 같은 드래그에서 **같은 칸**으로 또 점프하고 그 사이에 다른 점프가 없었으면
  /// (epoch가 마지막 드래그 점프 때 그대로) 건너뛴다 — 이미 그 칸에 가 있다. 다시 마운트는 보이는 칸을
  /// 전부 새로 만들어서(프레임당 약 1800 요소, 디버그 60~85ms) 칸이 안 바뀌는 작은 드래그에서도 매
  /// 프레임 치르면 낭비다. 실제로 점프했으면 true.
  ///
  /// ⚠️ 다시 마운트는 그대로 쓴다(SPL의 raw jumpTo로 되돌리지 말 것 — [jumpTo] 문서). 건너뛰는 것은
  /// "같은 칸 + 같은 epoch"일 때뿐이라, 그 사이에 접기/새 결과/검색 닫기 같은 다른 점프가 있었으면
  /// (epoch가 바뀐다) 반드시 새로 점프한다.
  bool thumbDragJumpTo(
    int index, {
    double alignment = 0,
    required void Function(VoidCallback fn) setState,
  }) {
    if (index == _lastDragJumpIndex && _epoch == _lastDragJumpEpoch) {
      return false;
    }
    jumpTo(index, alignment: alignment, setState: setState);
    _lastDragJumpIndex = index;
    _lastDragJumpEpoch = _epoch;
    return true;
  }

  /// 키·시작 위치가 붙은 SPL. 부모가 Stack이어도 안전하도록 `SizedBox.expand`로, 위쪽 PageStorage
  /// 복원을 막도록 자기만의 `PageStorage`로 감싼다(위 ⚠️ 둘).
  Widget build({
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    ScrollPhysics? physics,
  }) {
    return SizedBox.expand(
      child: PageStorage(
        bucket: PageStorageBucket(),
        child: ScrollablePositionedList.builder(
          key: ValueKey(_epoch),
          initialScrollIndex: _initialIndex,
          initialAlignment: _initialAlignment,
          itemCount: itemCount,
          itemBuilder: itemBuilder,
          itemScrollController: itemScrollController,
          itemPositionsListener: itemPositionsListener,
          physics: physics,
        ),
      ),
    );
  }
}

/// 접기/보이기로 [index] 칸 높이가 바뀌기 직전에, 눌린 카드가 손가락 밑에 남도록 필요할 때만 목록을
/// 다시 마운트한다([resizePinFor]가 어느 칸을 어디에 둘지 정한다). 다시 마운트했으면 true.
/// [kind]는 무슨 탭인지(질문/답 보이기/답 숨기기) — 호출자가 명시한다([CardResizeKind]).
///
/// target 이상 칸은 위쪽 가장자리가 원래 고정이라 (답 숨기기로 위로 잘린 칸의 아래쪽 고정을 빼고는)
/// 건드리지 않는다 — 건드리면 보이는 칸이 전부 다시 만들어져 물결·접근성 포커스가 끊긴다. 호출자가 바로 뒤에서 setState로 높이를 바꾸므로, 여기서 건 setState와
/// 같은 프레임에 합쳐져 처음 레이아웃부터 새 높이로 그려진다.
@visibleForTesting
bool reanchorTappedCard({
  required SplRemountController spl,
  required BuildContext itemContext,
  required int index,
  required int itemCount,
  required CardResizeKind kind,
  required void Function(VoidCallback fn) setState,
}) {
  if (!spl.itemScrollController.isAttached) return false;
  final pin = resizePinFor(
    itemContext: itemContext,
    positions: spl.itemPositionsListener.itemPositions.value,
    index: index,
    targetIndex: spl.targetIndex,
    itemCount: itemCount,
    kind: kind,
  );
  if (pin == null) return false;
  spl.jumpTo(pin.index, alignment: pin.alignment, setState: setState);
  return true;
}

// ─── 소량 목록(ListView) 위치 읽기 · 탐색 ───
//
// 소량 목록은 ScrollablePositionedList가 아니라 ListView라 _itemPositionsListener가 갱신되지
// 않는다(대량 목록에서 남은 낡은 값이 들어 있다). 칸 위치를 렌더 트리에서 직접 읽는다.
// 화면 상태(sqlite)에 의존하지 않도록 최상위 함수로 두어 평범한 ListView로 테스트한다.

/// 소량 목록(ListView)에서 레이아웃된 칸들을 ScrollablePositionedList의 ItemPosition과 같은
/// 단위(뷰포트 대비 비율)로 만든다. 레이아웃 전이거나 렌더 객체를 못 찾으면 빈 목록.
///
/// ListView.builder는 화면 밖 칸을 만들지 않으므로(캐시 범위 밖) 결과에는 지금 레이아웃된
/// 칸만 들어 있다.
@visibleForTesting
List<ItemPosition> simpleListItemPositions(ScrollController controller) {
  if (!controller.hasClients) return const [];
  final position = controller.position;
  // 붙기만 하고 아직 레이아웃을 안 거친 ListView는 pixels/viewportDimension이 null이라
  // 읽는 순간 null 검사 오류가 난다 — 먼저 확인한다.
  if (!position.hasPixels || !position.hasViewportDimension) return const [];
  final viewport = position.viewportDimension;
  if (viewport <= 0) return const [];
  final root = position.context.storageContext.findRenderObject();
  if (root == null) return const [];
  RenderSliverMultiBoxAdaptor? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderSliverMultiBoxAdaptor) {
      found = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(root);
  final sliver = found; // 클로저에서 대입된 변수라 승격이 안 되므로 지역 변수로 복사
  if (sliver == null || sliver.geometry == null) return const [];
  final positions = <ItemPosition>[];
  for (RenderBox? child = sliver.firstChild;
      child != null;
      child = sliver.childAfter(child)) {
    if (!child.hasSize) continue;
    final top = sliver.constraints.precedingScrollExtent +
        (sliver.childScrollOffset(child) ?? 0) -
        position.pixels;
    positions.add(ItemPosition(
      index: sliver.indexOf(child),
      itemLeadingEdge: top / viewport,
      itemTrailingEdge: (top + child.size.height) / viewport,
    ));
  }
  return positions;
}

/// 레이아웃이 끝난 소량 목록을 맨 위로 보낸다. 움직였으면 true.
/// 붙기만 하고 레이아웃 전이면 jumpTo가 null 검사 오류를 던지므로 건드리지 않는다
/// (레이아웃 전의 새 목록은 어차피 맨 위에서 시작한다).
@visibleForTesting
bool jumpToStartIfLaidOut(ScrollController controller) {
  if (!controller.hasClients) return false;
  final position = controller.position;
  if (!position.hasPixels ||
      !position.hasContentDimensions ||
      !position.hasViewportDimension) {
    return false;
  }
  position.jumpTo(0);
  return true;
}

/// 검색을 닫은 직후 소량 목록이 모든 칸을 첫 프레임에 한꺼번에 레이아웃하게 하는 캐시 범위(px).
/// 이 목록은 30장 이하라서 전부 만들어도 비용이 작고, 칸이 전부 레이아웃돼 있어야 누른 카드의
/// 정확한 위치를 한 번에 읽어 단 한 번의 점프로 맨 위에 올릴 수 있다. 탐색이 끝나면 평소 값으로
/// 되돌려 화면 밖 칸을 다시 해제한다(이미지가 많은 카드의 메모리 때문에 평소엔 쓰지 않는다).
@visibleForTesting
const double kSearchExitSeekCacheExtent = 1e7;

/// 위치를 잡는 중([settling])에만 큰 캐시 범위, 평소엔 null(ListView 기본값).
@visibleForTesting
double? searchExitCacheExtent({required bool settling}) =>
    settling ? kSearchExitSeekCacheExtent : null;

/// 위치를 잡는 중([settling])에는 목록을 투명하게 둔다. 전체 목록이 처음 그려지는 프레임은
/// 아직 결과 목록에서 물려받은 엉뚱한 위치라, 그 프레임을 보이면 엉뚱한 카드가 한 프레임
/// 번쩍인다. 레이아웃은 그대로 이뤄지므로(칸 위치를 읽을 수 있다) 보이기만 막는다.
@visibleForTesting
double searchExitListOpacity({required bool settling}) => settling ? 0.0 : 1.0;

@visibleForTesting
enum SimpleListSeekStep {
  /// 카드를 맨 위에 올렸다 (끝).
  arrived,

  /// 카드가 아직 레이아웃되지 않아, 레이아웃된 칸 중 카드 쪽 끝으로 한 걸음 옮겼다.
  stepped,

  /// 아직 읽을 수 있는 레이아웃이 없거나 더 움직일 수 없다 — 다음 프레임에 다시.
  notReady,
}

/// 소량 목록에서 [index] 칸을 맨 위로 올리는 한 걸음.
///
/// 칸이 레이아웃돼 있으면 그 칸의 실제 위치로 점프한다. 아니면 비율로 어림하지 않고,
/// 레이아웃된 칸 중 [index] 쪽 끝 칸의 가장자리(실제 위치)가 뷰포트 끝에 오도록 옮긴다 —
/// 그러면 다음 레이아웃에서 그 바로 옆 칸들이 반드시 새로 만들어져 매 걸음 최소 한 칸씩
/// 전진하고(빈 화면 프레임 없음), 칸 높이가 제각각이어도 어림 오차로 지나치지 않는다.
///
/// 목록 끝 칸([itemCount] - 1)이 아직 레이아웃되지 않았으면 maxScrollExtent가 어림값이라 점프
/// 위치가 그 어림값에 막혀 앵커가 맨 위에 못 닿을 수 있다. 그렇게 막혀서 움직인 경우는
/// [SimpleListSeekStep.stepped]로 돌려 다음 프레임(더 정확해진 max)에 한 번 더 확인한다.
/// 끝 칸이 레이아웃돼 있으면 max가 정확하므로(앵커 아래 내용의 길이를 다 안다) 막혔어도 도착이다
/// — 목록 끝에 가까운 카드는 맨 위에 못 오는 게 정상이다.
@visibleForTesting
SimpleListSeekStep seekSimpleListStep(
  ScrollController controller,
  int index, {
  required int itemCount,
}) {
  final positions = simpleListItemPositions(controller);
  if (positions.isEmpty) return SimpleListSeekStep.notReady;
  final position = controller.position;
  if (!position.hasContentDimensions) return SimpleListSeekStep.notReady;
  final viewport = position.viewportDimension;
  final pixels = position.pixels;

  ItemPosition? self;
  var first = positions.first;
  var last = positions.first;
  for (final p in positions) {
    if (p.index == index) self = p;
    if (p.index < first.index) first = p;
    if (p.index > last.index) last = p;
  }

  final double to;
  if (self != null) {
    to = pixels + self.itemLeadingEdge * viewport;
  } else if (index > last.index) {
    to = pixels + last.itemTrailingEdge * viewport; // 마지막 칸 끝이 뷰포트 맨 위에
  } else if (index < first.index) {
    to = pixels + first.itemLeadingEdge * viewport - viewport; // 첫 칸 시작이 뷰포트 맨 아래에
  } else {
    return SimpleListSeekStep.notReady; // 레이아웃된 칸은 연속이라 여기 올 수 없다 (방어)
  }
  final clamped = to.clamp(position.minScrollExtent, position.maxScrollExtent);
  final moved = (clamped - pixels).abs() >= 0.5;
  if (self == null) {
    if (!moved) return SimpleListSeekStep.notReady; // 더 움직일 수 없다 (끝에 닿음)
    position.jumpTo(clamped);
    return SimpleListSeekStep.stepped;
  }
  if (moved) position.jumpTo(clamped);
  final blockedByEstimatedMax =
      moved && to > clamped + 0.5 && last.index < itemCount - 1;
  return blockedByEstimatedMax
      ? SimpleListSeekStep.stepped
      : SimpleListSeekStep.arrived;
}

/// 소량 목록에서 [indexOf]가 가리키는 칸을 맨 위로 올린다. 프레임이 끝날 때마다 한 걸음씩
/// ([seekSimpleListStep]) 진행하며, 칸이 전부 레이아웃돼 있으면(캐시 범위를 크게 잡았을 때)
/// 첫 프레임에서 한 번의 점프로 끝난다.
///
/// - [indexOf]는 콜백 안에서 매번 다시 부른다 — 예약 시점의 인덱스는 그 사이 목록이 바뀌면
///   틀어진다(⚠️ 스크롤 목표는 실제로 로드된 목록 기준). 음수면 그 카드가 사라진 것이라 끝낸다.
/// - [isCurrent]가 false가 되면(화면이 닫히거나 더 새로운 로드가 시작됨) 손대지 않고 끝낸다.
/// - [onDone]은 어떤 경우에도(도착·포기·중단) 정확히 한 번 불린다 — 목록을 가려 둔 화면이
///   반드시 다시 보이게 하는 장치라, 예외가 나도 호출된다.
/// - [itemCount]도 콜백 안에서 매번 다시 읽는다. 걸음 수는 [maxAttempts]번(기본 시작 시점의
///   [itemCount] + 6)으로 제한한다. 매 걸음 최소 한 칸씩 전진하고
///   max 어림값을 다듬는 재확인이 몇 번 더 붙을 뿐이라 그 안에 끝난다 — 넘으면 포기하고 끝낸다.
@visibleForTesting
void seekSimpleListToIndex(
  ScrollController controller, {
  required int Function() indexOf,
  required bool Function() isCurrent,
  required int Function() itemCount,
  int? maxAttempts,
  VoidCallback? onDone,
}) {
  final attemptLimit = maxAttempts ?? itemCount() + 6;
  void attempt(int n) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      var done = true;
      try {
        if (!isCurrent() || !controller.hasClients) return;
        final index = indexOf();
        if (index < 0) return;
        final step =
            seekSimpleListStep(controller, index, itemCount: itemCount());
        if (step == SimpleListSeekStep.arrived || n + 1 >= attemptLimit) return;
        // jumpTo만으로는 프레임이 안 잡힐 수 있어 직접 깨운다 (card_edit_screen과 같은 이유).
        WidgetsBinding.instance.ensureVisualUpdate();
        done = false;
        attempt(n + 1);
      } finally {
        if (done) onDone?.call();
      }
    });
  }

  attempt(0);
  WidgetsBinding.instance.ensureVisualUpdate();
}

/// 카드 위(카드 바깥 여백 포함)에서 일어난 "누름"(탭/롱프레스 — 스크롤 드래그 제외)을 관찰만 한다.
///
/// Listener는 제스처 아레나에 끼지 않는 순수 포인터 관찰자라 안쪽 CardTile의 탭/롱프레스
/// 처리(특히 ⚠️ 선택모드에서 콜백이 null이어야 InkWell이 탭을 받는 규칙)에 영향이 없다.
/// HitTestBehavior.translucent라서 자식이 직접 받지 않는 곳(카드 margin·카드 사이 틈)을 눌러도
/// 기록되고, 같은 자리의 다른 위젯 처리도 막지 않는다. [child]가 margin까지 포함한 크기여야
/// 여백이 덮인다(CardTile은 Card의 margin이 위젯 크기에 들어 있다).
@visibleForTesting
class PressObserver extends StatefulWidget {
  const PressObserver({super.key, required this.onPress, required this.child});

  /// 누름이 끝났을 때(손가락을 뗐고 touch slop 안에서만 움직였을 때) 불린다.
  final VoidCallback onPress;
  final Widget child;

  @override
  State<PressObserver> createState() => _PressObserverState();
}

class _PressObserverState extends State<PressObserver> {
  int? _pointer;
  Offset? _downPosition;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointer = e.pointer;
        _downPosition = e.position;
      },
      onPointerUp: (e) {
        final down = _downPosition;
        if (e.pointer != _pointer || down == null) return;
        _pointer = null;
        _downPosition = null;
        if ((e.position - down).distance > kTouchSlop) return; // 스크롤 드래그는 누름이 아님
        widget.onPress();
      },
      child: widget.child,
    );
  }
}

class CardListScreen extends StatefulWidget {
  final Folder folder;
  final bool allCards;
  final int? scrollToCardId;
  final int? autoEditCardId;

  const CardListScreen({
    super.key,
    required this.folder,
    this.allCards = false,
    this.scrollToCardId,
    this.autoEditCardId,
  });

  @override
  State<CardListScreen> createState() => _CardListScreenState();
}

class _CardListScreenState extends State<CardListScreen> with RouteAware {
  final List<CardModel> _cards = [];
  bool _loading = true;
  bool _disposed = false; // precacheImage 등 비동기 작업 중단용
  int _totalCount = 0;

  // Answer 접기/숨기기 상태
  bool _allAnswersFolded = false;
  bool _allAnswersHidden = false;
  final Set<int> _foldedCards = {};
  final Set<int> _revealedCards = {};

  // 정렬
  String _sortOrder = 'sequence';

  // 다중 선택
  bool _isSelectionMode = false;
  final Set<int> _selectedCardIds = {};
  // batch action 재진입 차단 (delete/move 중에는 다른 batch action 못 시작하게)
  bool _isBatchActioning = false;

  // 검색
  bool _isSearching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  String _searchQuery = '';
  int _searchGeneration = 0;
  // 지금 _cards에 들어 있는 검색 결과의 검색어 (null = 전체 목록). _searchQuery는
  // 입력/닫기 즉시 바뀌지만 이 값은 결과가 실제로 화면에 올라온 시점에만 바뀐다 —
  // "새 결과 묶음인가"(맨 위로 시작)와 "검색을 닫는 중인가"(누른 카드 유지)를 가르는 기준.
  // _cards를 통째로 바꾸는 곳 4군데(_initLoad·_loadCards 알림 분기·_loadCards 일반 분기=null,
  // _performSearch=검색어)가 전부 이 값을 같이 갱신해야 한다.
  String? _resultsQuery;
  // 검색 결과에서 마지막으로 누른 카드 (검색을 닫을 때 전체 목록에서 그 카드를 맨 위에 둔다).
  // 결과가 화면에 떠 있는 동안에만 non-null — 전체 목록이 올라오면 비우고, 새 결과 묶음이
  // 올라오면 그 카드가 새 결과에도 있을 때만 이어 간다(keepAnchorForNewResults).
  int? _searchAnchorCardId;
  // 검색을 닫고 전체 목록이 올라온 직후, 누른 카드 위치로 옮기는 동안 true.
  // 그동안 목록을 투명하게 둬서(첫 프레임은 결과 목록에서 물려받은 엉뚱한 위치) 엉뚱한 카드가 한
  // 프레임 보이지 않게 하고, 소량 목록(ListView)은 캐시 범위를 크게 잡아 모든 칸을 레이아웃시킨다.
  // ⚠️ true로 만든 setState 뒤에는 반드시 _finishSearchExitSettle로 끝나는 예약이 따라와야 한다 —
  // 안 그러면 목록이 영영 안 보인다 (_settleAfterSearchExit의 모든 경로가 끝에서 부른다).
  bool _settlingSearchExit = false;

  // 잠금화면 편집 후 pop 감지용 (one-shot)
  bool _autoEditRefreshPending = false;

  // 설정값
  bool _showCardNumber = false;
  bool _showScrollbar = false;

  // 스크롤 위치 표시 (ValueNotifier로 라벨만 리빌드)
  /// 0 = 라벨 숨김, 1+ = 현재 보이는 카드 인덱스
  final _scrollLabelNotifier = ValueNotifier<int>(0);
  Timer? _scrollLabelTimer;

  // 스크롤 인디케이터용 fraction (0.0 ~ 1.0)
  final _scrollFractionNotifier = ValueNotifier<double>(0.0);

  // 커스텀 스크롤 썸 드래그 상태
  final _isDraggingThumb = ValueNotifier<bool>(false);

  // scrollToCardId용 하이라이트
  int? _highlightCardId;
  Timer? _highlightTimer;

  // ScrollablePositionedList (index 기반 스크롤 — 전체 모드 공통)
  // ListView.builder의 pixel 기반 jumpTo는 대량 카드에서 크래시 유발
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  // 대량 목록의 점프는 전부 이 컨트롤러(= 목록 다시 마운트)로만 한다 — 입구는 _jumpSplTo와
  // (스크롤바 썸 드래그의) _spl.thumbDragJumpTo뿐이다.
  // ⚠️ _itemScrollController.jumpTo/scrollTo를 직접 부르지 말 것: SPL 0.3.8의 jumpTo는 먼 칸으로
  // 점프할 때 페이지 전체를 민다(SplRemountController 문서). target 인덱스(_spl.targetIndex)도
  // 이 컨트롤러가 점프와 같이 기록한다.
  late final SplRemountController _spl = SplRemountController(
    itemScrollController: _itemScrollController,
    itemPositionsListener: _itemPositionsListener,
  );

  // 드래그 점프 스로틀링 (프레임당 최대 1회)
  bool _jumpScheduled = false;
  int _pendingJumpIndex = -1;

  // 소량 카드용 일반 ScrollController (ScrollablePositionedList는 소량에서 스크롤 불가)
  final ScrollController _simpleScrollController = ScrollController();
  static const _smallListThreshold = 30;
  bool get _useSimpleList =>
      _cards.length <= _smallListThreshold && !_isNotificationMode;

  // 알림/잠금화면 편집에서 진입한 모드인지
  bool get _isNotificationMode =>
      widget.scrollToCardId != null || widget.autoEditCardId != null;

  @override
  void initState() {
    super.initState();
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
    _highlightCardId = widget.scrollToCardId;
    _autoEditRefreshPending = widget.autoEditCardId != null;
    _initLoad();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void didPopNext() {
    if (_autoEditRefreshPending) {
      _autoEditRefreshPending = false;
      final autoId = widget.autoEditCardId;
      if (autoId != null) {
        _refreshCardInList(autoId);
      }
    }
  }

  String get _sortSettingKey =>
      'sort_order_${widget.allCards ? "all" : widget.folder.id}';

  Future<void> _initLoad() async {
    if (_isNotificationMode) {
      // 알림 모드: 정확한 indexOf 보장을 위해 id-only 쿼리로 ordering을 먼저
      // 결정한 뒤, 같은 id 리스트를 chunk 단위로 풀(*) 로드한다.
      // 단일 SELECT *로 13988장을 가져오면 Android Binder transaction 한계로
      // 일부 row가 corrupt되어 indexWhere가 -1을 반환하는 문제가 있다.
      // 다른 리로드 경로와 같은 세대 토큰을 발급한다 — 예전엔 이 분기만 토큰이 없어, 대형
      // 라이브러리에서 chunk 로드가 도는 동안(앱바는 이미 활성) 검색·정렬을 바꾸면 늦게 끝난
      // 이 로드가 검색 결과를 전체 목록으로 덮어썼다(검색어는 그대로 남은 채).
      final gen = ++_searchGeneration;
      final settings = await DatabaseHelper.instance.getAllSettings();
      if (!mounted || gen != _searchGeneration) return;
      setState(() => _applySettings(settings));

      // 1. id만 가져와 ordering 결정 (light query, 정확)
      final orderedIds = await _fetchOrderedCardIds();
      if (!mounted || gen != _searchGeneration) return;

      // 2. cards를 chunk 단위로 로드 (transaction 한계 회피)
      final cards = await _loadCardsChunked(orderedIds);
      if (!mounted || gen != _searchGeneration) return;

      // 스크롤 목표는 실제로 로드된 목록 기준으로 잡는다 — id 목록 기준 인덱스는 로드 중
      // 카드가 하나라도 빠지면(삭제 등) 엉뚱한 카드를 가리켰다.
      final targetId = widget.scrollToCardId!;
      final targetIndex = cards.indexWhere((c) => c.id == targetId);

      setState(() {
        _cards
          ..clear()
          ..addAll(cards);
        _totalCount = cards.length;
        _loading = false;
        _resultsQuery = null;
        _searchAnchorCardId = null;
      });

      if (targetIndex >= 0 && targetIndex < cards.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_itemScrollController.isAttached) return;
          _jumpSplTo(targetIndex);
        });
      }

      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _highlightCardId = null);
      });

    } else {
      // 일반 모드: 설정 먼저, 카드 로드
      final settings = await DatabaseHelper.instance.getAllSettings();
      if (!mounted) return;
      _applySettings(settings);
      await _loadCards();
    }
  }

  /// allCards 여부에 따라 정렬된 id 목록만 조회 (SELECT * 없이 id 컬럼만).
  Future<List<int>> _fetchOrderedCardIds() {
    if (widget.allCards) {
      return DatabaseHelper.instance.getAllCardIds(sortBy: _sortOrder);
    }
    return DatabaseHelper.instance
        .getCardIdsByFolderIdSorted(widget.folder.id!, _sortOrder);
  }

  /// id 목록을 chunk 단위(getCardsByIdsBatch)로 조회해 CardModel 리스트로 변환.
  /// 대량 카드를 SELECT *로 한 번에 가져오면 Android Binder transaction(1MB)
  /// 한계로 일부 row가 silently corrupt되므로, 카드를 실제로 로드하는 모든
  /// 경로가 이 헬퍼를 거치도록 한다 (id ordering은 그대로 보존).
  Future<List<CardModel>> _loadCardsChunked(List<int> orderedIds) async {
    final cardsById =
        await DatabaseHelper.instance.getCardsByIdsBatch(orderedIds);
    return orderedIds
        .map((id) => cardsById[id])
        .whereType<CardModel>()
        .toList();
  }

  void _applySettings(Map<String, String> settings) {
    final saved = settings[_sortSettingKey];
    if (saved != null) _sortOrder = saved;
    if (settings[AppConstants.settingAnswerFold] == 'collapsed') {
      _allAnswersFolded = true;
    }
    if (settings[AppConstants.settingAnswerVisibility] == 'hidden') {
      _allAnswersHidden = true;
    }
    _showCardNumber = settings[AppConstants.settingCardNumber] == 'true';
    _showScrollbar = settings[AppConstants.settingCardScroll] == 'true';
  }

  @override
  void dispose() {
    // 감사 D2-07: 재생기는 이제 위젯이 아니라 AudioPlaybackController가 소유한다 —
    // 스크롤/접기/선택모드로 타일이 사라져도 계속 재생되는 게 목적이지만, 목록 화면
    // 자체를 나가면 멈추는 게 맞다(안 그러면 어디서도 못 끄는 소리가 남는다).
    AudioPlaybackController.instance.stop().ignore();
    routeObserver.unsubscribe(this);
    _itemPositionsListener.itemPositions.removeListener(_onItemPositionsChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _disposed = true;
    _simpleScrollController.dispose();
    _debounceTimer?.cancel();
    _scrollLabelTimer?.cancel();
    _highlightTimer?.cancel();
    _scrollLabelNotifier.dispose();
    _scrollFractionNotifier.dispose();
    _isDraggingThumb.dispose();
    super.dispose();
  }

  /// 대량 목록(SPL)을 [index] 칸이 [alignment] 위치에 오도록 **다시 마운트**하고 target 인덱스를
  /// 기록한다. 호출 전에 isAttached를 확인할 것(목록이 떠 있을 때만 의미가 있다). mounted일 때만 부를 것.
  ///
  /// SPL 점프는 이 화면 안에서 반드시 이 함수(또는 같은 컨트롤러의 thumbDragJumpTo)로만 한다 — SPL의 jumpTo는 먼 칸으로 점프하면 페이지
  /// 전체를 밀기 때문에(접기/보이기 붙잡기·새 검색 결과 맨 위·검색 닫기 앵커·위치 복원이 모두
  /// 어긋났다) 쓰지 않는다. 기록이 빠지면 접기/보이기의 "붙잡아야 하나" 판단도 틀어진다(_spl.targetIndex).
  /// 같은 프레임에 여러 번 불리면 마지막 호출만 남는다.
  void _jumpSplTo(int index, {double alignment = 0}) {
    _spl.jumpTo(index, alignment: alignment, setState: setState);
  }

  /// ItemPositionsListener 콜백 (스크롤 위치 추적)
  void _onItemPositionsChanged() {
    if (_disposed || _isDraggingThumb.value) return;
    _scrollLabelNotifier.value = _currentVisibleIndex;
    _scrollLabelTimer?.cancel();
    _scrollLabelTimer = Timer(const Duration(seconds: 1), () {
      if (!_disposed) _scrollLabelNotifier.value = 0;
    });
    // 인디케이터 fraction 업데이트
    if (_cards.isNotEmpty) {
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isNotEmpty) {
        final visible = positions.where((p) => p.itemTrailingEdge > 0);
        if (visible.isNotEmpty) {
          final firstIndex =
              visible.reduce((a, b) => a.index < b.index ? a : b).index;
          final total = _cards.length - 1;
          if (total > 0) {
            _scrollFractionNotifier.value =
                (firstIndex / total).clamp(0.0, 1.0);
          }
        }
      }
    }
  }

  int get _currentVisibleIndex {
    if (_cards.isEmpty) return 0;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return 1;
    final visible = positions.where((p) => p.itemTrailingEdge > 0);
    if (visible.isEmpty) return 1;
    final firstVisible =
        visible.reduce((a, b) => a.index < b.index ? a : b);
    return firstVisible.index + 1;
  }

  // precache 세대 토큰 (새 로드 시 이전 precache 중단)
  int _precacheGeneration = 0;

  /// 카드 이미지를 백그라운드에서 미리 디코딩 (처음 50장만 — OOM 방지)
  Future<void> _precacheCardImages() async {
    final generation = ++_precacheGeneration;
    final limit = _cards.length.clamp(0, 50);
    for (int i = 0; i < limit; i++) {
      if (_disposed || !mounted || generation != _precacheGeneration) return;
      final card = _cards[i];
      for (final path in card.questionImagePaths) {
        if (_disposed || !mounted || generation != _precacheGeneration) return;
        try {
          await precacheImage(
            ResizeImage(FileImage(File(path)), width: 600),
            context,
          );
        } catch (_) {}
      }
      for (final path in card.answerImagePaths) {
        if (_disposed || !mounted || generation != _precacheGeneration) return;
        try {
          await precacheImage(
            ResizeImage(FileImage(File(path)), width: 600),
            context,
          );
        } catch (_) {}
      }
    }
  }

  /// 전체 카드 로드 (페이지네이션 없음 — 전체 로드 방식)
  Future<void> _loadCards() async {
    // _searchGeneration을 모든 리로드 경로의 세대 토큰으로 사용 — 이 호출보다
    // 늦게 시작된 다른 _loadCards/_performSearch가 있으면 그쪽이 이긴다.
    // (검색 중 X버튼으로 검색을 닫으면 이 리로드가 늦게 도착한 검색 결과에
    // 덮어써지는 것을 방지)
    final gen = ++_searchGeneration;
    // 검색 결과가 떠 있다가 이 로드로 전체 목록으로 돌아가는 중인가. 첫 await 전에 — 결과
    // 목록이 아직 화면에 그대로 있을 때 — 후보 두 개(누른 카드, 화면 맨 위 결과)의 id를 잡아 둔다.
    // 둘 중 무엇을 쓸지는 전체 목록이 로드된 뒤 그 목록 기준으로 고른다(_settleAfterSearchExit):
    // 누른 카드가 편집으로 결과에서는 빠졌어도 전체 목록에 있으면 그 카드를 써야 한다.
    // 알림 모드/일반 모드 양쪽 분기가 같은 값을 쓴다.
    final leavingSearch = _resultsQuery != null && _searchQuery.isEmpty;
    final exitTappedId = leavingSearch ? _searchAnchorCardId : null;
    final exitFirstVisibleId = leavingSearch ? _firstVisibleResultId() : null;
    // 알림 모드에서 검색 아닌 리로드는 전체 리로드
    if (_isNotificationMode && _searchQuery.isEmpty) {
      // 카운트도 세대 검사 뒤에 대입한다 — 취소된(stale) 리로드가 앱바 숫자를 오염시키던 구멍.
      final int total;
      if (widget.allCards) {
        total = await DatabaseHelper.instance.getTotalCardCount();
      } else {
        total = await DatabaseHelper.instance
            .countCardsByFolderId(widget.folder.id!);
      }
      // 대량 카드에서 SELECT *를 한 번에 실행하면 row corruption이 발생할 수
      // 있어 id-only 쿼리 + chunk 로드(getCardsByIdsBatch)로 우회한다.
      final orderedIds = await _fetchOrderedCardIds();
      final cards = await _loadCardsChunked(orderedIds);
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _totalCount = total;
        _cards
          ..clear()
          ..addAll(cards);
        _loading = false;
        _resultsQuery = null;
        _searchAnchorCardId = null;
        // 위치를 잡는 동안 목록을 가린다 (⚠️ 아래 _settleAfterSearchExit가 반드시 해제한다).
        if (leavingSearch) _settlingSearchExit = true;
        _pruneSelection();
      });
      _precacheCardImages();
      if (leavingSearch) {
        _settleAfterSearchExit(exitTappedId, exitFirstVisibleId, gen);
      }
      return;
    }

    // 스크롤 위치 저장 (리로드 후 복원용)
    // 검색을 닫는 중이면 저장하지 않는다 — 이 시점의 위치는 "결과 목록" 기준인데
    // (_searchQuery는 이미 ''), 전체 목록에 그대로 적용되면 엉뚱한 카드로 튄다.
    // 그 경우엔 아래 _settleAfterSearchExit가 누른 카드 기준으로 위치를 잡는다.
    int? savedIndex;
    if (!leavingSearch && _cards.isNotEmpty && _searchQuery.isEmpty) {
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isNotEmpty) {
        final visible = positions.where((p) => p.itemTrailingEdge > 0);
        if (visible.isNotEmpty) {
          savedIndex =
              visible.reduce((a, b) => a.index < b.index ? a : b).index;
        }
      }
    }

    // 초기 로딩에만 스피너 표시. 리로드 시에는 기존 카드 유지하여 깜빡임 방지
    final isInitialLoad = _cards.isEmpty;
    if (isInitialLoad && mounted) {
      setState(() {
        _loading = true;
      });
    }

    if (_searchQuery.isNotEmpty) {
      await _performSearch(gen);
      return;
    }

    final int total;
    if (widget.allCards) {
      total = await DatabaseHelper.instance.getTotalCardCount();
    } else {
      total = await DatabaseHelper.instance
          .countCardsByFolderId(widget.folder.id!);
    }
    // 대량 카드에서 SELECT *를 한 번에 실행하면 row corruption이 발생할 수
    // 있어 id-only 쿼리 + chunk 로드(getCardsByIdsBatch)로 우회한다.
    final orderedIds = await _fetchOrderedCardIds();
    final cards = await _loadCardsChunked(orderedIds);
    if (!mounted || gen != _searchGeneration) return;
    setState(() {
      _totalCount = total;
      _cards
        ..clear()
        ..addAll(cards);
      _loading = false;
      _resultsQuery = null;
      _searchAnchorCardId = null;
      // 위치를 잡는 동안 목록을 가린다 (⚠️ 아래 _settleAfterSearchExit가 반드시 해제한다).
      if (leavingSearch) _settlingSearchExit = true;
      _pruneSelection();
    });
    _precacheCardImages();
    // 검색을 닫고 돌아온 경우: 누른 카드(없으면 맨 위 결과)를 맨 위에 두고 끝낸다.
    if (leavingSearch) {
      _settleAfterSearchExit(exitTappedId, exitFirstVisibleId, gen);
      return;
    }
    // 스크롤 위치 복원
    if (savedIndex != null && savedIndex > 0 && _cards.isNotEmpty) {
      final idx = savedIndex.clamp(0, _cards.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _itemScrollController.isAttached) {
          _jumpSplTo(idx);
        }
      });
    }
  }

  // ─── 검색을 닫을 때 위치 유지 ───

  /// 닫기 직전 화면 맨 위에 보이던 검색 결과의 카드 id (없으면 null).
  /// 반드시 _cards가 아직 결과 목록일 때(_loadCards의 첫 await 전에) 불러야 한다.
  /// 소량 목록(ListView)은 _itemPositionsListener가 갱신되지 않아 렌더 트리에서 직접 읽는다.
  int? _firstVisibleResultId() {
    final firstVisibleIndex = _useSimpleList
        ? firstVisibleItemIndex(simpleListItemPositions(_simpleScrollController))
        : firstVisibleItemIndex(_itemPositionsListener.itemPositions.value);
    return resultIdAt([for (final c in _cards) c.id], firstVisibleIndex);
  }

  /// 위치 잡기가 끝나면(도착·포기·중단 어느 경우든) 가려 둔 목록을 다시 보이게 한다.
  void _finishSearchExitSettle() {
    if (!mounted || !_settlingSearchExit) return;
    setState(() => _settlingSearchExit = false);
  }

  /// 검색을 닫고 전체 목록이 올라온 직후: 앵커 카드를 맨 위에 두고 5초 하이라이트
  /// (알림으로 들어왔을 때와 같은 표시). 앵커가 없으면 맨 위로 보낸다.
  ///
  /// 앵커는 여기서 **방금 불러온 전체 목록 기준으로** 고른다 — 누른 카드[tappedId]가 있으면
  /// 그것, 전체 목록에 없으면(삭제·이동) 닫기 직전 맨 위 결과[firstVisibleId], 그것도 없으면 없음
  /// (pickSearchExitAnchor). [gen]은 _loadCards가 발급한 세대 토큰 — 그 사이 더 새로운
  /// 로드/검색이 시작됐으면 위치는 건드리지 않는다.
  ///
  /// 호출 직전 setState에서 _settlingSearchExit를 true로 올렸으므로 모든 경로가 끝에서
  /// _finishSearchExitSettle로 해제해야 한다 (목록이 가려진 채 남지 않게).
  void _settleAfterSearchExit(int? tappedId, int? firstVisibleId, int gen) {
    final anchorId = pickSearchExitAnchor(
      tappedCardId: tappedId,
      firstVisibleCardId: firstVisibleId,
      fullListIds: [for (final c in _cards) c.id],
    );
    if (anchorId != null) {
      setState(() => _highlightCardId = anchorId);
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _highlightCardId = null);
      });
      if (_useSimpleList) {
        // 캐시 범위를 크게 잡아 둔 덕에 첫 프레임에 모든 칸이 레이아웃돼 있어 한 번에 끝난다.
        seekSimpleListToIndex(
          _simpleScrollController,
          // 스크롤 목표는 프레임 시점의 실제 목록 기준으로 다시 찾는다 (_initLoad의 ⚠️와 같은 이유).
          indexOf: () => _cards.indexWhere((c) => c.id == anchorId),
          isCurrent: () => mounted && gen == _searchGeneration && _useSimpleList,
          itemCount: () => _cards.length,
          onDone: _finishSearchExitSettle,
        );
        return;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (!mounted || gen != _searchGeneration) return;
        if (_useSimpleList) {
          jumpToStartIfLaidOut(_simpleScrollController);
          return;
        }
        if (!_itemScrollController.isAttached) return;
        // 스크롤 목표는 프레임 시점의 실제 목록 기준으로 다시 찾는다 (_initLoad의 ⚠️와 같은 이유).
        final idx =
            anchorId == null ? -1 : _cards.indexWhere((c) => c.id == anchorId);
        _jumpSplTo(idx >= 0 ? idx : 0);
      } finally {
        _finishSearchExitSettle();
      }
    });
    // setState가 이미 프레임을 예약했지만, 호출 시점에 따라 아닐 수 있어 확실히 한다.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 카드 1장만 DB에서 다시 가져와 _cards 같은 인덱스에 in-place 교체.
  /// random 정렬에서 _loadCards() 호출 시 ORDER BY RANDOM()이 재셔플되어
  /// 편집한 카드가 다른 위치로 사라지는 버그 방지.
  Future<void> _refreshCardInList(int cardId) async {
    final updated = await DatabaseHelper.instance.getCardById(cardId);
    if (!mounted) return;
    final index = _cards.indexWhere((c) => c.id == cardId);
    if (index == -1) return;
    setState(() {
      if (updated == null) {
        _cards.removeAt(index);
        if (_totalCount > 0) _totalCount -= 1;
      } else if (!widget.allCards && updated.folderId != widget.folder.id) {
        _cards.removeAt(index);
        if (_totalCount > 0) _totalCount -= 1;
      } else {
        _cards[index] = updated;
      }
    });
    _precacheCardImages();
    // 이름순 정렬에서 질문을 고치면 자리가 바뀌어야 한다 — 위 in-place 교체 뒤 재정렬.
    if (updated != null && _sortOrder.startsWith('name')) {
      unawaited(_loadCards());
    }
  }

  /// 주어진 id 카드들을 _cards 리스트에서 제거 (DB 작업은 호출자가 이미 수행).
  /// random 정렬 보존을 위해 _loadCards() 대신 사용.
  void _removeCardsLocally(Iterable<int> ids) {
    final idSet = ids.toSet();
    final removed = _cards.where((c) => idSet.contains(c.id)).length;
    if (removed == 0) return;
    setState(() {
      _cards.removeWhere((c) => idSet.contains(c.id));
      _totalCount = (_totalCount - removed).clamp(0, _totalCount);
    });
  }

  /// 이동된 카드들의 folderId를 _cards 리스트에서 in-place 갱신
  /// (DB 이동은 호출자가 이미 수행). allCards 모드는 카드를 리스트에서
  /// 빼지 않으므로 이걸 안 하면 CardModel.folderId가 stale로 남아,
  /// 그 카드를 곧바로 편집→저장할 때 stale folderId == originalFolderId로
  /// 판정되어 moveCard가 스킵되고 updateCard가 옛 folder_id를 그대로
  /// 되써서 방금 한 이동이 조용히 되돌아가는 버그 방지.
  void _updateCardsFolderLocally(Iterable<int> ids, int newFolderId) {
    final idSet = ids.toSet();
    setState(() {
      for (var i = 0; i < _cards.length; i++) {
        if (idSet.contains(_cards[i].id)) {
          _cards[i] = _cards[i].copyWith(folderId: newFolderId);
        }
      }
    });
  }

  /// 새로 만든 카드 1장을 _cards 특정 위치에 삽입.
  /// afterCardId가 주어지면 그 카드 다음에, 없으면 맨 앞에 삽입.
  Future<void> _insertCardLocally(int newCardId, {int? afterCardId}) async {
    final card = await DatabaseHelper.instance.getCardById(newCardId);
    if (!mounted || card == null) return;
    if (!widget.allCards && card.folderId != widget.folder.id) return;
    setState(() {
      var insertAt = 0;
      if (afterCardId != null) {
        final idx = _cards.indexWhere((c) => c.id == afterCardId);
        if (idx >= 0) insertAt = idx + 1;
      }
      _cards.insert(insertAt, card);
      _totalCount += 1;
    });
    _precacheCardImages();
    // 이름순 정렬에선 "맨 앞/원본 뒤" 삽입 위치가 DB 정렬과 다르다(재진입하면 딴 자리) —
    // 화면을 즉시 갱신한 뒤 정확한 자리로 조용히 재정렬한다. random/기본 정렬은 위치 보존.
    if (_sortOrder.startsWith('name')) unawaited(_loadCards());
  }

  /// [generation]은 호출자(_loadCards)가 진입 시점에 이미 발급한 세대 토큰을
  /// 그대로 넘겨받는다 — 여기서 별도로 다시 발급하면 _loadCards의 다른 분기
  /// (알림 모드 리로드, 기본 리로드)가 검색과 같은 세대를 공유하지 못해
  /// 서로의 stale 여부를 못 걸러낸다 (검색 도중 검색을 닫아도 늦게 끝난
  /// 검색 결과가 리로드 결과를 덮어쓰는 문제).
  Future<void> _performSearch(int generation) async {
    // 이 호출이 찾는 검색어를 먼저 고정한다 — 아래 _resultsQuery와 DB 조회가 같은 값을 보게.
    final query = _searchQuery;
    List<CardModel> results;
    if (widget.allCards) {
      results = await DatabaseHelper.instance.searchAllCards(query);
    } else {
      results = await DatabaseHelper.instance
          .searchCards(widget.folder.id!, query);
    }
    // stale 결과 무시 (더 새로운 검색이 시작된 경우)
    if (!mounted || generation != _searchGeneration) return;
    // 검색어가 바뀐 "새 결과 묶음"이면 맨 위에서 시작한다. 같은 검색어의 재조회(삭제·이동·
    // 편집 뒤 갱신)는 보던 자리를 그대로 둔다. 전체 목록(_resultsQuery == null)에서 처음
    // 검색할 때도 새 묶음이다 — 안 그러면 결과가 전체 목록의 스크롤 상태를 물려받아
    // 중간부터 열린다.
    final isNewResultSet = _resultsQuery != query;
    setState(() {
      _cards.clear();
      _cards.addAll(results);
      _totalCount = results.length;
      _loading = false;
      _resultsQuery = query;
      // 앵커는 "지금 떠 있는 결과 묶음에서 누른 카드"만 의미가 있다. 새 묶음에도 그 카드가
      // 있으면 이어 가고(검색어를 한 글자씩 지울 때 앵커가 매번 초기화되던 문제), 없으면 비운다.
      if (isNewResultSet) {
        _searchAnchorCardId = keepAnchorForNewResults(
          tappedCardId: _searchAnchorCardId,
          newResultIds: [for (final c in results) c.id],
        );
      }
      _pruneSelection();
    });
    if (isNewResultSet) {
      // 레이아웃 전의 ListView는 jumpTo가 던지므로 확인 뒤에만 (새 목록은 어차피 맨 위에서 시작).
      jumpToStartIfLaidOut(_simpleScrollController);
      if (_itemScrollController.isAttached) _jumpSplTo(0);
    }
  }

  void _onSearchChanged(String query) {
    // suffixIcon(X 버튼) 즉시 표시를 위해 리빌드
    setState(() {});
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _searchQuery = query.trim());
      _loadCards();
    });
  }

  // ─── Card actions ───

  /// 카드의 모든 파일 경로를 수집 (이미지, handImage, voiceRecord)
  List<String> _collectCardFilePaths(CardModel card) => card.allMediaPaths;

  /// 파일 경로 리스트의 파일들을 디스크에서 삭제 — 다른 카드가 아직 참조하는 파일은 남긴다
  /// (레거시 .memk는 여러 카드가 같은 파일을 가리킬 수 있다, D8-04). DB 삭제가 커밋된 뒤 호출.
  Future<void> _deleteFiles(List<String> paths) =>
      DatabaseHelper.instance.deleteUnreferencedMediaFiles(paths);

  Future<void> _deleteCard(CardModel card) async {
    final t = AppLocalizations.of(context);
    final confirmed = await confirmDelete(
      context,
      title: t.cardDeleteTitle,
      message: t.cardDeleteSingleConfirm,
    );
    if (!confirmed || !mounted) return;

    final filePaths = _collectCardFilePaths(card);
    try {
      await DatabaseHelper.instance.deleteCard(card.id!);
      await DatabaseHelper.instance.updateFolderCardCount(card.folderId);
    } catch (e) {
      debugPrint('[CARD_LIST] card delete failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardDeleteFail)),
      );
      return;
    }
    await _deleteFiles(filePaths);
    if (!mounted) return;
    if (_searchQuery.isNotEmpty) {
      await _loadCards();
    } else {
      _removeCardsLocally([card.id!]);
    }
  }

  Future<void> _duplicateCard(CardModel card) async {
    int newCardId;
    try {
      newCardId = await DatabaseHelper.instance.duplicateCard(card.id!);
      if (newCardId < 0) throw Exception('duplicate returned -1');
    } catch (e) {
      debugPrint('[CARD_LIST] card duplicate failed: $e');
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardDuplicateFail)),
      );
      return;
    }
    if (!mounted) return;
    if (_searchQuery.isNotEmpty) {
      await _loadCards();
    } else {
      // random 정렬 보존: 원본 카드 바로 뒤에 새 카드 삽입
      await _insertCardLocally(newCardId, afterCardId: card.id);
    }
  }

  /// 이동 대상 폴더 선택 다이얼로그 (+ 새 폴더 생성 옵션). 취소 시 null.
  /// [folders]는 소스 폴더가 이미 제외된 후보 목록.
  Future<Folder?> _pickTargetFolder({
    required List<Folder> folders,
    required String title,
  }) {
    final t = AppLocalizations.of(context);
    return showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          ...folders.map((f) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f),
                child: Text('${folderDisplayPath(f)} (${f.cardCount})'),
              )),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                t.cardMoveNoOtherFolders,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
          // 이동할 폴더가 없거나, 새 폴더로 옮기고 싶을 때 그 자리에서 생성.
          SimpleDialogOption(
            onPressed: () async {
              final created = await _promptCreateFolderForMove();
              if (created != null && ctx.mounted) {
                Navigator.pop(ctx, created);
              }
            },
            child: Row(
              children: [
                const Icon(Icons.create_new_folder_outlined, size: 20),
                const SizedBox(width: 12),
                Text(t.cardMoveCreateFolderOption),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 이름 입력 → 폴더 생성 → 그 Folder 반환 (홈 화면 생성과 동일 정책).
  /// 취소/빈이름/중복/실패 시 null.
  ///
  /// ⚠️ 예전엔 여기 스코프에 클로저 변수로 `TextEditingController`를 만들고
  /// `try { showDialog(...) } finally { controller.dispose(); }`로 정리했었다 —
  /// push_notification_settings.dart의 `_PushRuleDialog` 문서에 적힌 것과 동일한
  /// '_dependents.isEmpty' 크래시 위험 패턴. 지금은 controller를
  /// [FolderNameDialog]의 State가 소유해 dispose()가 Element unmount 시점에만
  /// 불리도록 고쳤다.
  Future<Folder?> _promptCreateFolderForMove() async {
    final t = AppLocalizations.of(context);
    String name = '';
    try {
      final input = await showDialog<String>(
        context: context,
        builder: (_) => FolderNameDialog(
          title: t.homeNewFolderTitle,
          hint: t.homeFolderNameHint,
          confirmLabel: t.commonCreate,
          // 중복 이름은 다이얼로그 안에서 바로 알린다(모달 뒤 SnackBar는 보이지 않았다).
          validate: (candidate) async {
            final existing =
                await DatabaseHelper.instance.getFolderByName(candidate);
            return existing != null ? t.homeFolderExists(candidate) : null;
          },
        ),
      );
      if (input == null || input.trim().isEmpty || !mounted) return null;
      name = input.trim();

      // 같은 이름이 이미 있으면 새로 만들지 않고 안내 (중복 폴더 생성 방지 — 다이얼로그
      // 검사와 insert 사이의 경합 대비 2차 방어).
      final existing = await DatabaseHelper.instance.getFolderByName(name);
      if (existing != null) {
        if (!mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.homeFolderExists(name))),
        );
        return null;
      }
      final maxSeq = await DatabaseHelper.instance.getMaxFolderSequence();
      final newId = await DatabaseHelper.instance
          .insertFolder(Folder(name: name, sequence: maxSeq + 1));
      if (!mounted) return null;
      return await DatabaseHelper.instance.getFolderById(newId);
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.homeFolderCreateFail(name))),
      );
      return null;
    }
  }

  Future<void> _moveCard(CardModel card) async {
    final t = AppLocalizations.of(context);
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    final sourceFolderId = card.folderId;
    final target = await _pickTargetFolder(
      folders: folders.where((f) => f.id != sourceFolderId).toList(),
      title: t.cardPickFolderTitle,
    );
    if (target == null || !mounted) return;

    final duplicates = await DatabaseHelper.instance
        .findDuplicateCardIdsInFolder([card.id!], target.id!);
    if (!mounted) return;
    if (duplicates.isNotEmpty) {
      final action = await _showDuplicateMoveDialog(
          duplicateCount: 1, totalCount: 1);
      if (action == null || action == 'cancel' || !mounted) return;
      if (action == 'skip') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.cardSkippedDuplicate)),
        );
        return;
      }
    }

    await DatabaseHelper.instance.moveCard(card.id!, target.id!);
    if (!mounted) return;
    if (_searchQuery.isNotEmpty) {
      await _loadCards();
    } else if (widget.allCards) {
      // 모든 카드 모드에서는 카드가 그대로 표시 — 폴더 필드만 갱신
      await _refreshCardInList(card.id!);
    } else {
      // 일반 폴더 모드: 다른 폴더로 이동했으므로 현재 리스트에서 제거
      _removeCardsLocally([card.id!]);
    }
  }

  /// 이동 시 중복 발견 → 사용자 선택. 'skip' / 'all' / 'cancel' / null 반환
  Future<String?> _showDuplicateMoveDialog({
    required int duplicateCount,
    required int totalCount,
  }) {
    final t = AppLocalizations.of(context);
    final msg = totalCount == 1
        ? t.cardDupSingleMessage
        : t.cardDupMultiMessage(totalCount, duplicateCount);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.cardDupTitle,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(msg, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 20),
                _DuplicateOption(
                  icon: Icons.filter_alt_outlined,
                  title: t.cardDupSkip,
                  subtitle: totalCount == 1
                      ? t.cardDupSkipSubSingle
                      : t.cardDupSkipSubMulti,
                  onTap: () => Navigator.pop(ctx, 'skip'),
                ),
                const SizedBox(height: 8),
                _DuplicateOption(
                  icon: Icons.layers_outlined,
                  title: t.cardDupMove,
                  subtitle: totalCount == 1
                      ? t.cardDupMoveSubSingle
                      : t.cardDupMoveSubMulti,
                  onTap: () => Navigator.pop(ctx, 'all'),
                  accent: true,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, 'cancel'),
                    child: Text(t.commonCancel),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _handleCardMenu(CardModel card, String action) {
    switch (action) {
      case 'edit':
        _editCard(card);
      case 'delete':
        _deleteCard(card);
      case 'duplicate':
        _duplicateCard(card);
      case 'move':
        _moveCard(card);
    }
  }

  Future<void> _editCard(CardModel card) async {
    final cardId = card.id;
    final result = await Navigator.push<int?>(
      context,
      MaterialPageRoute(
        builder: (_) => CardEditScreen(
          folderId: card.folderId,
          existingCard: card,
        ),
      ),
    );
    if (!mounted) return;
    // 편집 화면에서 삭제된 경우
    if (result == -1 && cardId != null) {
      _removeCardsLocally([cardId]);
      return;
    }
    // 검색 모드에서는 검색 결과 일관성을 위해 풀 리로드
    if (_searchQuery.isNotEmpty) {
      _loadCards();
      return;
    }
    // random 정렬 보존: 편집한 카드 1장만 in-place 갱신
    if (cardId != null) {
      await _refreshCardInList(cardId);
    }
  }

  // ─── Selection mode ───

  void _enterSelectionMode(CardModel card) {
    if (card.id == null) return;
    setState(() {
      _isSelectionMode = true;
      _selectedCardIds.add(card.id!);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedCardIds.clear();
    });
  }

  void _toggleCardSelection(CardModel card) {
    if (card.id == null) return;
    setState(() {
      if (_selectedCardIds.contains(card.id!)) {
        _selectedCardIds.remove(card.id!);
        if (_selectedCardIds.isEmpty) _isSelectionMode = false;
      } else {
        _selectedCardIds.add(card.id!);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedCardIds.length == _cards.length) {
        _selectedCardIds.clear();
      } else {
        _selectedCardIds.addAll(_cards.where((c) => c.id != null).map((c) => c.id!));
      }
    });
  }

  /// _cards가 통째로 교체된 뒤 _selectedCardIds를 화면에 남은 카드로만 정리.
  /// 선택 모드 중에도 검색창은 그대로 보이고 입력 가능해서(별개 상태값)
  /// 검색어를 바꾸면 _performSearch/_loadCards가 _cards를 다른 결과로
  /// 갈아치우는데, 이걸 안 하면 화면에서 사라진 카드의 선택이 그대로 남아
  /// _deleteSelected가 안 보이는 카드까지 지우면서 그 카드의 파일 경로
  /// 수집(_cards 기반)은 놓쳐 orphan 파일이 생기는 버그 방지.
  void _pruneSelection() {
    if (_selectedCardIds.isEmpty) return;
    _selectedCardIds.retainAll(_cards.map((c) => c.id).whereType<int>());
    if (_selectedCardIds.isEmpty) _isSelectionMode = false;
  }

  Future<void> _deleteSelected() async {
    if (_isBatchActioning) return; // 재진입 차단 (delete/move 동시 시작 방지)
    final t = AppLocalizations.of(context);
    // 진입 즉시 대상을 스냅샷한다 — 확인 다이얼로그가 떠 있는 동안 진행 중인 검색이
    // _pruneSelection으로 선택을 줄이면 "20개 삭제"를 확인했는데 3개만 지워지고 통보도
    // 없었다. 사용자가 확인한 집합 = 이 스냅샷.
    final targetIds = _selectedCardIds.toList();
    if (targetIds.isEmpty) return;
    final confirmed = await confirmDelete(
      context,
      title: t.cardDeleteTitle,
      message: t.cardDeleteMultiConfirm(targetIds.length),
    );
    if (!confirmed || !mounted) return;

    _isBatchActioning = true;
    try {
      // 삭제 전 파일 경로 수집 — 메모리 _cards가 아니라 DB에서: 다이얼로그 사이 검색으로
      // 화면을 떠난 카드도 대상이고, 그 카드의 파일도 함께 지워야 고아가 안 남는다.
      final byId = await DatabaseHelper.instance.getCardsByIdsBatch(targetIds);
      final allFilePaths = <String>[];
      for (final card in byId.values) {
        allFilePaths.addAll(_collectCardFilePaths(card));
      }

      // ⚡ atomic transaction (folder card_count 자동 갱신 포함). 수백 ms 안에 commit.
      final deletedIds = targetIds;
      await DatabaseHelper.instance.deleteCardsBatch(deletedIds);
      if (!mounted) return;

      // commit 직후 즉시 UI 정리 — 사용자 시점에선 여기서 끝.
      _exitSelectionMode();
      if (_searchQuery.isNotEmpty) {
        unawaited(_loadCards());
      } else {
        _removeCardsLocally(deletedIds);
      }

      // 🔄 파일 정리는 fire-and-forget. DB는 이미 commit됨 → swipe해도 카드는 영구 사라짐.
      //    일부 image/voice 파일이 orphan으로 남아도 동작엔 무관.
      unawaited(_deleteFiles(allFilePaths));
    } catch (e) {
      debugPrint('[CARD_LIST] batch card delete failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardDeleteFail)),
      );
    } finally {
      _isBatchActioning = false;
    }
  }

  Future<void> _moveSelected() async {
    if (_isBatchActioning) return; // 재진입 차단
    final t = AppLocalizations.of(context);
    // 스냅샷은 폴더 목록 조회·폴더 선택·중복 확인 다이얼로그보다 먼저 — 그 사이 검색이
    // 선택을 줄이면 사용자가 고른 카드 일부만 이동하고 통보도 없었다(_deleteSelected와 동일).
    final allIds = _selectedCardIds.toList();
    if (allIds.isEmpty) return;
    var folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    if (!widget.allCards) {
      folders = folders.where((f) => f.id != widget.folder.id).toList();
    }
    final target = await _pickTargetFolder(
      folders: folders,
      title: t.cardMoveTargetTitle,
    );
    if (target == null || !mounted) return;

    // '모든 카드' 모드에선 이미 대상 폴더에 있는 카드를 후보에서 뺀다 — 그대로 두면 중복
    // 검사가 자기 자신을 중복으로 잡아 헛경고를 띄우고, skip을 고르면 그 카드만 조용히 빠졌다.
    final candidateIds = widget.allCards
        ? allIds.where((id) {
            final c = _cards
                .cast<CardModel?>()
                .firstWhere((x) => x!.id == id, orElse: () => null);
            return c == null || c.folderId != target.id;
          }).toList()
        : allIds;
    if (candidateIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardMoveNoneToMove)),
      );
      _exitSelectionMode();
      return;
    }
    final duplicates = await DatabaseHelper.instance
        .findDuplicateCardIdsInFolder(candidateIds, target.id!);
    if (!mounted) return;

    var idsToMove = candidateIds;
    var skipped = 0;
    if (duplicates.isNotEmpty) {
      final action = await _showDuplicateMoveDialog(
          duplicateCount: duplicates.length, totalCount: candidateIds.length);
      if (action == null || action == 'cancel' || !mounted) return;
      if (action == 'skip') {
        idsToMove =
            candidateIds.where((id) => !duplicates.contains(id)).toList();
        skipped = candidateIds.length - idsToMove.length;
        if (idsToMove.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.cardMoveNoneToMove)),
          );
          _exitSelectionMode();
          return;
        }
      }
    }

    _isBatchActioning = true;
    try {
      // ⚡ atomic transaction — 800 chunk × 3 stmt, 수백 ms 안에 commit
      await DatabaseHelper.instance.moveCardsBatch(idsToMove, target.id!);
      if (!mounted) return;
      _exitSelectionMode();
      if (_searchQuery.isNotEmpty) {
        unawaited(_loadCards());
      } else if (widget.allCards) {
        // allCards 모드: 카드는 그대로 표시되지만 folderId는 갱신해야 함
        // (안 하면 stale folderId로 인해 이후 편집 저장 시 이동이 되돌아감)
        _updateCardsFolderLocally(idsToMove, target.id!);
      } else {
        // 일반 폴더 모드: 다른 폴더로 이동된 카드들을 현재 리스트에서 제거
        _removeCardsLocally(idsToMove);
      }

      // 결과는 항상 알린다 — 스냅샷 밖에서 선택이 줄었어도 "몇 장이 옮겨졌는지"를 사용자가 안다.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.cardMoveResult(idsToMove.length, skipped))),
        );
      }
    } catch (e) {
      // 삭제 쪽엔 있던 실패 통보가 이동엔 없어 실패가 무음으로 사라졌다.
      debugPrint('[CARD_LIST] batch card move failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardMoveFail)),
      );
    } finally {
      _isBatchActioning = false;
    }
  }

  // ─── Answer fold/hide ───

  /// 대량 목록(ScrollablePositionedList)에서 접기/보이기로 카드 높이가 바뀔 때, 누른 카드가 손가락
  /// 밑에 남게 한다. 이 목록은 target 카드를 기준으로 배치하는데 target보다 위쪽 칸은 target에서
  /// 위로 쌓여서, 그런 카드의 높이가 바뀌면 위쪽으로 밀려 올라가 손가락 밑에 다른 카드가 미끄러져
  /// 온다(예: 검색 결과가 전체 목록 target을 물려받은 경우). 그래서 setState 전에 누른 카드를 "지금
  /// 화면 위치 그대로" target으로 삼아 목록을 다시 마운트한다(SPL jumpTo는 쓰지 않는다 — _jumpSplTo 문서).
  /// 규칙은 [kind](의도)로 정한다 — 질문 탭·답 보이기는 **위쪽 가장자리 고정**(위로 잘려 있어도),
  /// 답 숨기기만 위로 잘리고 아래쪽이 화면 안일 때 아래쪽 고정(resizePinFor). target 이상 칸은 위쪽이
  /// 원래 고정이라 건드리지 않는다 — 다시 마운트하면 보이는 칸이 전부 새로 만들어져 물결·접근성 포커스가
  /// 끊긴다(reanchorTappedCard).
  /// 소량 목록(ListView)은 픽셀 오프셋 기준이라 해당 없음. 화면 밖이거나 아래로 벗어난 카드는 건드리지 않는다.
  /// [itemContext]는 눌린 칸 안쪽(_buildCardItem의 Builder)의 컨텍스트 — 렌더 트리로 위치를 읽는다.
  void _keepTappedCardInPlace(
      int cardId, BuildContext itemContext, CardResizeKind kind) {
    if (_useSimpleList) return;
    final index = _cards.indexWhere((c) => c.id == cardId);
    if (index < 0) return;
    reanchorTappedCard(
      spl: _spl,
      itemContext: itemContext,
      index: index,
      itemCount: _cards.length,
      kind: kind,
      setState: setState,
    );
  }

  void _toggleQuestionFold(CardModel card, BuildContext itemContext) {
    final cardId = card.id;
    if (cardId == null) return;
    // 질문 탭은 늘어나든 줄어들든 항상 위쪽 가장자리 고정 (손가락은 질문 줄 위에 있다).
    _keepTappedCardInPlace(cardId, itemContext, CardResizeKind.questionToggle);
    setState(() {
      if (_foldedCards.contains(cardId)) {
        _foldedCards.remove(cardId);
      } else {
        _foldedCards.add(cardId);
      }
    });
  }

  void _toggleAnswerReveal(CardModel card, BuildContext itemContext) {
    final cardId = card.id;
    if (cardId == null) return;
    // ⚠️ 숨김 모드가 아니면 높이가 안 바뀌어 kind가 null이다 → 붙잡지 않는다 (answerTapResizeKind 문서).
    // 보이는 중이던 답을 가리면 줄어듦(answerHide), 가려진 답을 펼치면 커짐(answerReveal).
    final kind = answerTapResizeKind(
      allAnswersHidden: _allAnswersHidden,
      answerRevealed: _revealedCards.contains(cardId),
    );
    if (kind != null) _keepTappedCardInPlace(cardId, itemContext, kind);
    setState(() {
      if (_revealedCards.contains(cardId)) {
        _revealedCards.remove(cardId);
      } else {
        _revealedCards.add(cardId);
      }
    });
  }

  bool _isCardFolded(CardModel card) {
    if (_allAnswersFolded) {
      return !_foldedCards.contains(card.id);
    }
    return _foldedCards.contains(card.id);
  }

  bool _isCardRevealed(CardModel card) {
    if (_allAnswersHidden) {
      return _revealedCards.contains(card.id);
    }
    return true;
  }

  // ─── 카드 아이템 빌더 (공통) ───

  Widget _buildCardItem(BuildContext context, int index) {
    final card = _cards[index];
    final isHighlighted = _highlightCardId == card.id;
    // PressObserver(Listener)는 제스처 아레나에 끼지 않는 순수 포인터 관찰자라 아래 CardTile의
    // 탭/롱프레스 처리(특히 ⚠️ 선택모드 규칙)에 영향이 없다. 검색 결과에서 "마지막으로 누른
    // 카드"를 기록해 두었다가, 검색을 닫을 때 전체 목록에서 그 카드를 맨 위에 둔다.
    // CardTile의 바깥 여백(Card margin)은 CardTile 크기에 들어 있어 여백·카드 사이 틈을
    // 눌러도 기록된다(리스트 자체에는 padding이 없다).
    // Builder: 접기/보이기가 "이 칸이 target 위쪽(역방향 sliver)인가"를 렌더 트리로 판별하려면
    // 칸 안쪽의 BuildContext가 필요하다(laidOutAboveListTarget). 칸을 감싸는 컴포넌트일 뿐이다.
    return Builder(
      builder: (itemContext) => PressObserver(
        onPress: () {
          if (_resultsQuery == null) return; // 검색 결과가 떠 있을 때만
          _searchAnchorCardId = card.id; // setState 불필요(화면에 안 그림)
        },
        child: CardTile(
          card: card,
          isFolded: _isCardFolded(card),
          isHidden: _allAnswersHidden,
          isRevealed: _isCardRevealed(card),
          isSelectionMode: _isSelectionMode,
          isSelected: _selectedCardIds.contains(card.id),
          isHighlighted: isHighlighted,
          cardNumber: _showCardNumber ? index + 1 : null,
          searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
          // 선택모드에선 접기/보이기 제스처를 끊는다 — 안쪽 GestureDetector(opaque)가 제스처
          // 아레나에서 이겨 카드 본문 탭이 선택을 토글하지 못하고 왼쪽 동그라미만 반응했다
          // (실기기 확인). 콜백이 null이면 인식기가 만들어지지 않아 InkWell.onTap이 받는다.
          onQuestionTap: _isSelectionMode
              ? null
              : () => _toggleQuestionFold(card, itemContext),
          onAnswerTap: _isSelectionMode
              ? null
              : () => _toggleAnswerReveal(card, itemContext),
          onTap: _isSelectionMode
              ? () => _toggleCardSelection(card)
              : () => _editCard(card),
          onLongPress: _isSelectionMode
              ? null
              : () => _enterSelectionMode(card),
          onMenuAction: (action) => _handleCardMenu(card, action),
        ),
      ),
    );
  }

  /// 카드 리스트
  /// 소량 카드(≤30)는 ListView.builder (ScrollablePositionedList 소량 스크롤 버그 회피)
  /// 대량 카드는 ScrollablePositionedList (index 기반 점프, 드래그 인디케이터)
  Widget _buildCardList() {
    final Widget list;
    if (_useSimpleList) {
      final simple = ListView.builder(
        controller: _simpleScrollController,
        itemCount: _cards.length,
        itemBuilder: _buildCardItem,
        physics: const ClampingScrollPhysics(),
        // 검색을 닫고 위치를 잡는 동안만 모든 칸을 레이아웃시킨다 (평소엔 null = 기본값).
        cacheExtent: searchExitCacheExtent(settling: _settlingSearchExit),
      );
      list = _showScrollbar
          ? Scrollbar(
              controller: _simpleScrollController,
              thumbVisibility: true,
              child: simple,
            )
          : simple;
    } else {
      // 점프는 목록을 다시 마운트하는 방식이라(_spl) 키·시작 위치가 붙은 SPL을 컨트롤러에서 받는다.
      list = _spl.build(
        itemCount: _cards.length,
        itemBuilder: _buildCardItem,
        physics: const ClampingScrollPhysics(),
      );
    }
    // 항상 감싸 둔다(트리 모양이 바뀌면 목록이 새로 만들어져 스크롤 상태를 잃는다). 위치를
    // 잡는 동안만 투명 — 레이아웃은 그대로라 칸 위치를 읽을 수 있고, 엉뚱한 위치의 첫 프레임만
    // 가려진다. 불투명(1.0)일 때는 추가 레이어 없이 그대로 그려진다.
    return Opacity(
      opacity: searchExitListOpacity(settling: _settlingSearchExit),
      child: list,
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelectionMode) {
          _exitSelectionMode();
        }
      },
      child: Scaffold(
        appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Column(
          children: [
            // 검색바 (상단 고정)
            if (_isSearching)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).cardListSearchHint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: _onSearchChanged,
                ),
              ),
            // 카드 리스트
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _cards.isEmpty
                      ? Center(
                          child: Text(_searchQuery.isNotEmpty
                              ? AppLocalizations.of(context).cardListSearchEmpty
                              : AppLocalizations.of(context).cardListEmpty),
                        )
                      : Stack(
                          children: [
                            _buildCardList(),
                            // 스크롤 위치 인디케이터 (대량 카드에서만 — 소량은 ListView 사용)
                            if (_showScrollbar && !_useSimpleList && _cards.length > 1)
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                width: 80,
                                child: _buildScrollIndicator(),
                              ),
                          ],
                        ),
            ),
          ],
        ),
        bottomNavigationBar: _isSelectionMode ? _buildSelectionBar() : null,
        floatingActionButton: _isSelectionMode || widget.allCards
            ? null
            : FloatingActionButton(
                onPressed: () async {
                  final newId = await Navigator.push<int?>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          CardEditScreen(folderId: widget.folder.id!),
                    ),
                  );
                  if (!mounted) return;
                  // 검색 모드에서 새 카드 생성 시 검색 초기화 (새 카드가 안 보이는 버그 방지)
                  if (_searchQuery.isNotEmpty) {
                    // setState 없이 지우면 검색창의 ✕ 아이콘이 한 프레임 남는다(감사 Y1-03).
                    setState(() {
                      _searchController.clear();
                      _searchQuery = '';
                    });
                    _loadCards();
                    return;
                  }
                  if (newId != null) {
                    // random 정렬 보존: 새 카드를 맨 앞에 삽입 (즉시 확인 가능)
                    await _insertCardLocally(newId);
                  }
                },
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  /// 스크롤 위치 인디케이터 (드래그로 빠른 이동 지원)
  /// GestureDetector는 전체 트랙 높이를 차지하되, deferToChild로
  /// 인디케이터 위치에 직접 터치했을 때만 제스처가 시작됨.
  /// 드래그 시작 후에는 전체 트랙에서 자유롭게 이동 가능.
  Widget _buildScrollIndicator() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        const indicatorHeight = 28.0;
        final maxOffset = trackHeight - indicatorHeight;

        return GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onVerticalDragStart: (details) {
            _isDraggingThumb.value = true;
            _scrollLabelTimer?.cancel();
            _spl.beginThumbDrag(); // 이 드래그의 첫 점프는 항상 실제로 한다
            _jumpToFraction(
                details.localPosition.dy, trackHeight, indicatorHeight);
          },
          onVerticalDragUpdate: (details) {
            _jumpToFraction(
                details.localPosition.dy, trackHeight, indicatorHeight);
          },
          onVerticalDragEnd: (_) {
            _isDraggingThumb.value = false;
            _scrollLabelTimer?.cancel();
            _scrollLabelTimer = Timer(const Duration(seconds: 1), () {
              if (!_disposed) _scrollLabelNotifier.value = 0;
            });
          },
          child: ValueListenableBuilder<int>(
            valueListenable: _scrollLabelNotifier,
            builder: (context, labelIndex, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: _isDraggingThumb,
                builder: (context, isDragging, _) {
                  return AnimatedOpacity(
                    opacity: (labelIndex > 0 || isDragging) ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _scrollFractionNotifier,
                      builder: (context, fraction, _) {
                        final top =
                            (fraction * maxOffset).clamp(0.0, maxOffset);
                        final currentIndex = _cards.isEmpty
                            ? 0
                            : (fraction * (_cards.length - 1)).round() + 1;

                        return Stack(
                          children: [
                            Positioned(
                              top: top,
                              right: 0,
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.25),
                                    borderRadius: const BorderRadius.only(
                                      topLeft: Radius.circular(14),
                                      bottomLeft: Radius.circular(14),
                                    ),
                                  ),
                                  child: Text(
                                    '$currentIndex/${_cards.length}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontFamily: 'Pretendard',
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.7),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  /// 드래그 시 스크롤 위치 점프 (프레임당 1회 스로틀링)
  void _jumpToFraction(
      double localY, double trackHeight, double indicatorHeight) {
    final fraction = ((localY - indicatorHeight / 2) /
            (trackHeight - indicatorHeight))
        .clamp(0.0, 1.0);
    _scrollFractionNotifier.value = fraction;

    final currentIndex = _cards.isEmpty
        ? 0
        : (fraction * (_cards.length - 1)).round() + 1;
    _scrollLabelNotifier.value = currentIndex;

    if (_cards.isEmpty || !_itemScrollController.isAttached) return;

    _pendingJumpIndex = (fraction * (_cards.length - 1)).round();

    if (!_jumpScheduled) {
      _jumpScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpScheduled = false;
        if (!mounted || !_itemScrollController.isAttached) return;
        // 같은 드래그에서 같은 칸이면 건너뛴다(다시 마운트는 비싸다) — thumbDragJumpTo 문서.
        _spl.thumbDragJumpTo(_pendingJumpIndex, setState: setState);
      });
    }
  }

  PreferredSizeWidget _buildNormalAppBar() {
    final t = AppLocalizations.of(context);
    return AppBar(
      title: Text(
        widget.allCards
            // '모든 카드' 검색은 1000건에서 잘린다(searchAllCards LIMIT) — 잘린 걸 전체 매치
            // 수처럼 보이지 않게 "1000+"로 표기.
            ? (_searchQuery.isNotEmpty && _totalCount >= 1000
                ? t.cardListAllCardsTitleCapped
                : t.cardListAllCardsTitle(_totalCount))
            : '${widget.folder.name} ($_totalCount)',
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 18,
        ),
      ),
      actions: [
        IconButton(
          icon: Icon(_isSearching ? Icons.close : Icons.search),
          onPressed: () {
            setState(() {
              if (_isSearching) {
                _isSearching = false;
                _searchController.clear();
                _searchQuery = '';
                _debounceTimer?.cancel();
                _loadCards();
              } else {
                _isSearching = true;
                if (_isSelectionMode) {
                  _isSelectionMode = false;
                  _selectedCardIds.clear();
                }
                Future.microtask(() => _searchFocusNode.requestFocus());
              }
            });
          },
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'sort_sequence':
              case 'sort_newest':
              case 'sort_oldest':
              case 'sort_name_asc':
              case 'sort_random':
                _sortOrder = value.replaceFirst('sort_', '');
                DatabaseHelper.instance
                    .upsertSetting(_sortSettingKey, _sortOrder);
                // 검색 모드에서 정렬 변경 시 검색 초기화 (정렬이 반영되도록)
                if (_searchQuery.isNotEmpty) {
                  setState(() {
                    _searchController.clear();
                    _searchQuery = '';
                  });
                }
                _loadCards();
              case 'fold_toggle':
                setState(() {
                  _allAnswersFolded = !_allAnswersFolded;
                  _foldedCards.clear();
                });
                DatabaseHelper.instance.upsertSetting(
                  AppConstants.settingAnswerFold,
                  _allAnswersFolded ? 'collapsed' : 'expanded',
                );
              case 'hide_toggle':
                setState(() {
                  _allAnswersHidden = !_allAnswersHidden;
                  _revealedCards.clear();
                });
                DatabaseHelper.instance.upsertSetting(
                  AppConstants.settingAnswerVisibility,
                  _allAnswersHidden ? 'hidden' : 'visible',
                );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'sort_sequence',
              child: _menuItem(t.cardListSortDefault, _sortOrder == 'sequence'),
            ),
            PopupMenuItem(
              value: 'sort_newest',
              child: _menuItem(t.cardListSortNewest, _sortOrder == 'newest'),
            ),
            PopupMenuItem(
              value: 'sort_oldest',
              child: _menuItem(t.cardListSortOldest, _sortOrder == 'oldest'),
            ),
            PopupMenuItem(
              value: 'sort_name_asc',
              child: _menuItem(t.cardListSortName, _sortOrder == 'name_asc'),
            ),
            PopupMenuItem(
              value: 'sort_random',
              child: _menuItem(t.cardListSortRandom, _sortOrder == 'random'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'fold_toggle',
              child: Text(_allAnswersFolded
                  ? t.cardListAnswerExpand
                  : t.cardListAnswerCollapse),
            ),
            PopupMenuItem(
              value: 'hide_toggle',
              child: Text(_allAnswersHidden
                  ? t.cardListAnswerShow
                  : t.cardListAnswerHide),
            ),
          ],
        ),
      ],
    );
  }

  Widget _menuItem(String label, bool selected) {
    return Row(
      children: [
        if (selected)
          Icon(Icons.check,
              size: 18, color: Theme.of(context).colorScheme.primary)
        else
          const SizedBox(width: 18),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final t = AppLocalizations.of(context);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectionMode,
      ),
      title: Text(t.cardListSelectedCount(_selectedCardIds.length)),
      actions: [
        Row(
          children: [
            Text(t.cardListSelectAll),
            Checkbox(
              value: _selectedCardIds.length == _cards.length &&
                  _cards.isNotEmpty,
              onChanged: (_) => _toggleSelectAll(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionBar() {
    final t = AppLocalizations.of(context);
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            onPressed:
                _selectedCardIds.isEmpty ? null : _deleteSelected,
            icon: const Icon(Icons.delete),
            label: Text(t.commonDelete),
          ),
          TextButton.icon(
            onPressed:
                _selectedCardIds.isEmpty ? null : _moveSelected,
            icon: const Icon(Icons.drive_file_move),
            label: Text(t.cardListMove),
          ),
        ],
      ),
    );
  }
}

class _DuplicateOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool accent;

  const _DuplicateOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = accent ? cs.primaryContainer : cs.surfaceContainerHighest;
    final fg = accent ? cs.onPrimaryContainer : cs.onSurface;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: fg.withValues(alpha: 0.85), size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: fg.withValues(alpha: 0.7),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
