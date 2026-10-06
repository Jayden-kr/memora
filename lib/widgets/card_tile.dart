import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderFlex, RenderParagraph;

import '../l10n/app_localizations.dart';
import '../models/card.dart';
import 'card_audio_field.dart';

class CardTile extends StatelessWidget {
  final CardModel card;
  final bool isFolded;
  final bool isHidden;
  final bool isRevealed;
  final bool isSelectionMode;
  final bool isSelected;
  final bool isHighlighted;
  final int? cardNumber;
  final String? searchQuery;
  final VoidCallback? onQuestionTap;
  final VoidCallback? onAnswerTap;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(String action)? onMenuAction;

  const CardTile({
    super.key,
    required this.card,
    this.isFolded = false,
    this.isHidden = false,
    this.isRevealed = false,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.isHighlighted = false,
    this.cardNumber,
    this.searchQuery,
    this.onQuestionTap,
    this.onAnswerTap,
    this.onTap,
    this.onLongPress,
    this.onMenuAction,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final answerVisible = !isHidden || isRevealed;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: null,
      shape: isHighlighted
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.primary, width: 2.5),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Card number
              if (cardNumber != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '#$cardNumber',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              // Question row
              KeyedSubtree(
                key: const ValueKey(_CardTileSlot.questionRow),
                child: Row(
                children: [
                  if (isSelectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        isSelected
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.outline,
                      ),
                    ),
                  Expanded(
                    child: KeyedSubtree(
                      key: const ValueKey(_CardTileSlot.questionArea),
                      child: GestureDetector(
                      onTap: onQuestionTap,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHighlightedText(
                            context,
                            card.question,
                            searchQuery,
                            const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: isFolded ? 1 : null,
                            overflow: isFolded
                                ? TextOverflow.ellipsis
                                : null,
                          ),
                          if (!isFolded &&
                              card.questionImagePaths.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                children:
                                    card.questionImagePaths.map((path) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        File(path),
                                        width: double.infinity,
                                        fit: BoxFit.fitWidth,
                                        cacheWidth: 600,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, _, _) => Container(
                                          height: 80,
                                          width: double.infinity,
                                          color: colorScheme
                                              .surfaceContainerHighest,
                                          child: const Icon(Icons.broken_image,
                                              size: 28),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          // 음성 재생 (질문에 음성 있을 때만; 접힘·선택모드에선 숨김)
                          if (!isFolded &&
                              !isSelectionMode &&
                              (card.questionVoiceRecordPath ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: AudioPlayerButton(
                                key: ValueKey(card.questionVoiceRecordPath),
                                path: card.questionVoiceRecordPath!,
                                durationMs: card.questionVoiceRecordLength,
                                compact: true,
                                lazy: true,
                              ),
                            ),
                        ],
                      ),
                    ),
                    ),
                  ),
                  if (!isSelectionMode && onMenuAction != null)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, size: 20),
                      onSelected: onMenuAction,
                      itemBuilder: (ctx) {
                        final t = AppLocalizations.of(ctx);
                        return [
                          PopupMenuItem(value: 'edit', child: Text(t.cardTileMenuEdit)),
                          PopupMenuItem(value: 'duplicate', child: Text(t.cardTileMenuDuplicate)),
                          PopupMenuItem(value: 'move', child: Text(t.cardTileMenuMove)),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(t.commonDelete, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                          ),
                        ];
                      },
                    ),
                ],
              ),
              ),
              // Answer area (collapsible)
              if (!isFolded)
                KeyedSubtree(
                  key: const ValueKey(_CardTileSlot.answerArea),
                  child: _buildAnswerArea(context, colorScheme, answerVisible),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHighlightedText(
    BuildContext context,
    String text,
    String? query,
    TextStyle style, {
    int? maxLines,
    TextOverflow? overflow,
  }) {
    if (query == null || query.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    // toLowerCase()는 length-preserving이 아닌 유니코드 문자(예: 'İ')가 있으면
    // lowerText/lowerQuery 길이가 원본과 달라질 수 있다. 그러면 lowerText에서 찾은
    // index를 원본 text.substring에 그대로 쓰면 RangeError가 난다 — 그런 경우
    // 하이라이트 없이 원본 텍스트만 렌더링한다.
    if (text.length != lowerText.length || query.length != lowerQuery.length) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }
    final highlightColor = Theme.of(context).colorScheme.primary;
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(TextSpan(
        text: text.substring(index, index + lowerQuery.length),
        style: TextStyle(backgroundColor: highlightColor),
      ));
      start = index + (lowerQuery.isNotEmpty ? lowerQuery.length : 1);
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }

  Widget _buildAnswerArea(BuildContext context, ColorScheme colorScheme, bool answerVisible) {
    return GestureDetector(
      onTap: onAnswerTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: _kDividerHeight),
          if (answerVisible) ...[
            if (card.answer.isNotEmpty)
              _buildHighlightedText(
                context,
                card.answer,
                searchQuery,
                _kAnswerStyle,
              ),
            if (card.answerImagePaths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  children: card.answerImagePaths.map((path) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(path),
                          width: double.infinity,
                          fit: BoxFit.fitWidth,
                          cacheWidth: 600,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => Container(
                            height: 80,
                            width: double.infinity,
                            color: colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.broken_image, size: 28),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
          ] else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: _kHintVerticalPadding),
              child: Text(
                AppLocalizations.of(context).cardViewTapToReveal,
                style: _hintStyle(context),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── 접기/보이기 직전 "바뀐 뒤 높이" 예측 (목록이 누른 카드를 손가락 밑에 남기는 데 쓴다) ───
// ⚠️ 이 예측은 이 파일의 레이아웃(여백·구분선·안내 문구·접힌 질문 1줄)을 그대로 따라 한다 — 레이아웃을
// 바꾸면 card_tile_height_prediction_test가 잡는다.
const double _kDividerHeight = 16;
const double _kHintVerticalPadding = 8;
const TextStyle _kAnswerStyle = TextStyle(fontSize: 16);

TextStyle? _hintStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        );

/// 카드 안쪽 영역 표식 — KeyedSubtree의 키라 렌더 객체도 동작도 바꾸지 않는다.
enum _CardTileSlot { questionRow, questionArea, answerArea }

/// 높이를 바꿀 수 있는 탭.
enum CardTileTap { question, answer }

/// [context] 아래(자기 포함) 첫 CardTile이 [tap] 한 번 뒤 가질 높이(dp, 카드 바깥 여백 포함).
/// 탭 직전(높이를 바꾸는 setState 전)에 부른다. 커지는 것이 확실한 탭(접힌 카드 펴기, 이미지가 있는
/// 답 보이기), 높이가 안 바뀌는 탭(숨김 모드가 아닐 때 답 탭), 렌더 트리를 못 읽을 때는 null.
double? predictCardTileHeightAfterTap(BuildContext context, CardTileTap tap) {
  Element? tileElement;
  void findTile(Element e) {
    if (tileElement != null) return;
    if (e.widget is CardTile) {
      tileElement = e;
      return;
    }
    e.visitChildElements(findTile);
  }

  if (context is Element && context.widget is CardTile) {
    tileElement = context;
  } else {
    context.visitChildElements(findTile);
  }
  final te = tileElement;
  if (te == null) return null;
  final tile = te.widget as CardTile;
  final tileBox = te.findRenderObject();
  if (tileBox is! RenderBox || !tileBox.attached || !tileBox.hasSize) return null;

  final slots = <_CardTileSlot, Element>{};
  void findSlots(Element e) {
    final key = e.widget.key;
    if (key is ValueKey<_CardTileSlot>) slots[key.value] = e;
    e.visitChildElements(findSlots);
  }

  te.visitChildElements(findSlots);
  RenderBox? box(_CardTileSlot s) {
    final r = slots[s]?.findRenderObject();
    return (r is RenderBox && r.attached && r.hasSize) ? r : null;
  }

  final height = tileBox.size.height;

  switch (tap) {
    case CardTileTap.question:
      if (tile.isFolded) return null; // 펴기는 항상 커진다
      final row = box(_CardTileSlot.questionRow);
      final q = box(_CardTileSlot.questionArea);
      if (row == null || q == null) return null;
      RenderParagraph? para;
      void findPara(RenderObject r) {
        if (para != null) return;
        if (r is RenderParagraph) {
          para = r;
          return;
        }
        r.visitChildren(findPara);
      }

      findPara(q);
      final p = para;
      if (p == null) return null;
      final oneLine = _oneLineHeight(p);
      // 줄(Row)의 다른 자식(메뉴 버튼·선택 표시)은 접어도 그대로다. 줄 높이 = 자식 중 최대.
      var others = 0.0;
      if (row is RenderFlex) {
        for (RenderBox? c = row.firstChild; c != null; c = row.childAfter(c)) {
          if (!identical(c, q) && c.hasSize && c.size.height > others) others = c.size.height;
        }
      }
      final foldedRow = oneLine > others ? oneLine : others;
      final answerH = box(_CardTileSlot.answerArea)?.size.height ?? 0;
      return height - row.size.height - answerH + foldedRow;
    case CardTileTap.answer:
      if (!tile.isHidden || tile.isFolded) return null; // 숨김 모드가 아니면 높이가 안 바뀐다
      final a = box(_CardTileSlot.answerArea);
      final areaContext = slots[_CardTileSlot.answerArea];
      if (a == null || areaContext == null) return null;
      final width = a.size.width;
      final double newArea;
      if (tile.isRevealed) {
        // 숨기기: 답 → 구분선 + "탭하여 정답 보기"
        newArea = _kDividerHeight +
            2 * _kHintVerticalPadding +
            _textHeight(areaContext, AppLocalizations.of(areaContext).cardViewTapToReveal,
                _hintStyle(areaContext), width);
      } else {
        // 보이기: 이미지 높이는 디코딩 전엔 모른다 — 이미지가 있으면 커지는 탭으로 본다.
        if (tile.card.answerImagePaths.isNotEmpty) return null;
        newArea = _kDividerHeight +
            (tile.card.answer.isEmpty
                ? 0
                : _textHeight(areaContext, tile.card.answer, _kAnswerStyle, width));
      }
      return height - a.size.height + newArea;
  }
}

/// 살아 있는 질문 문단을 그대로 한 줄(말줄임)로 배치했을 때의 높이 — 접힌 질문과 같은 설정.
double _oneLineHeight(RenderParagraph p) {
  final tp = TextPainter(
    text: p.text,
    textAlign: p.textAlign,
    textDirection: p.textDirection,
    locale: p.locale,
    textScaler: p.textScaler,
    maxLines: 1,
    ellipsis: '\u2026',
    strutStyle: p.strutStyle,
    textWidthBasis: p.textWidthBasis,
    textHeightBehavior: p.textHeightBehavior,
  )..layout(maxWidth: p.constraints.maxWidth);
  final h = tp.height;
  tp.dispose();
  return h;
}

/// Text 위젯이 [context]에서 [style]로 [text]를 [maxWidth] 폭에 그릴 때의 높이 (Text.build와 같은 규칙).
double _textHeight(BuildContext context, String text, TextStyle? style, double maxWidth) {
  final dts = DefaultTextStyle.of(context);
  var effective = (style == null || style.inherit) ? dts.style.merge(style) : style;
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final tp = TextPainter(
    text: TextSpan(style: effective, text: text),
    textAlign: dts.textAlign ?? TextAlign.start,
    textDirection: Directionality.of(context),
    locale: Localizations.maybeLocaleOf(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: dts.maxLines,
    textWidthBasis: dts.textWidthBasis,
    textHeightBehavior: dts.textHeightBehavior ?? DefaultTextHeightBehavior.maybeOf(context),
  )..layout(maxWidth: maxWidth);
  final h = tp.height;
  tp.dispose();
  return h;
}
