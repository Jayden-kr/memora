import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../database/database_helper.dart';
import '../l10n/app_localizations.dart';
import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';
import '../widgets/card_tile.dart';
import 'card_edit_screen.dart';

class CardListScreen extends StatefulWidget {
  final Folder folder;
  final bool allCards;
  final int? scrollToCardId;

  const CardListScreen({
    super.key,
    required this.folder,
    this.allCards = false,
    this.scrollToCardId,
  });

  @override
  State<CardListScreen> createState() => _CardListScreenState();
}

class _CardListScreenState extends State<CardListScreen> {
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

  // 검색
  bool _isSearching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  String _searchQuery = '';
  int _searchGeneration = 0;

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

  // 드래그 점프 스로틀링 (프레임당 최대 1회)
  bool _jumpScheduled = false;
  int _pendingJumpIndex = -1;

  // 소량 카드용 일반 ScrollController (ScrollablePositionedList는 소량에서 스크롤 불가)
  final ScrollController _simpleScrollController = ScrollController();
  static const _smallListThreshold = 30;
  bool get _useSimpleList =>
      _cards.length <= _smallListThreshold && !_isNotificationMode;

  // 알림에서 진입한 모드인지
  bool get _isNotificationMode => widget.scrollToCardId != null;

  @override
  void initState() {
    super.initState();
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
    _highlightCardId = widget.scrollToCardId;
    _initLoad();
  }

  String get _sortSettingKey =>
      'sort_order_${widget.allCards ? "all" : widget.folder.id}';

  Future<void> _initLoad() async {
    if (_isNotificationMode) {
      // 알림 모드: 정확한 indexOf 보장을 위해 id-only 쿼리로 ordering을 먼저
      // 결정한 뒤, 같은 id 리스트를 chunk 단위로 풀(*) 로드한다.
      // 단일 SELECT *로 13988장을 가져오면 Android Binder transaction 한계로
      // 일부 row가 corrupt되어 indexWhere가 -1을 반환하는 문제가 있다.
      final settings = await DatabaseHelper.instance.getAllSettings();
      if (!mounted) return;
      _applySettings(settings);

      // 1. id만 가져와 ordering + targetIndex 계산 (light query, 정확)
      final List<int> orderedIds;
      if (widget.allCards) {
        orderedIds = await DatabaseHelper.instance
            .getAllCardIds(sortBy: _sortOrder);
      } else {
        orderedIds = await DatabaseHelper.instance
            .getCardIdsByFolderIdSorted(widget.folder.id!, _sortOrder);
      }
      if (!mounted) return;

      final targetId = widget.scrollToCardId!;
      final targetIndex = orderedIds.indexOf(targetId);

      // 2. cards를 chunk 단위로 로드 (transaction 한계 회피)
      final cardsById =
          await DatabaseHelper.instance.getCardsByIdsBatch(orderedIds);
      if (!mounted) return;

      // 3. id ordering 보존하며 정렬
      final cards = orderedIds
          .map((id) => cardsById[id])
          .whereType<CardModel>()
          .toList();

      setState(() {
        _cards
          ..clear()
          ..addAll(cards);
        _totalCount = cards.length;
        _loading = false;
      });

      if (targetIndex >= 0 && targetIndex < cards.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_itemScrollController.isAttached) return;
          _itemScrollController.jumpTo(index: targetIndex);
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
    // 알림 모드에서 검색 아닌 리로드는 전체 리로드
    if (_isNotificationMode && _searchQuery.isEmpty) {
      List<CardModel> cards;
      if (widget.allCards) {
        _totalCount = await DatabaseHelper.instance.getTotalCardCount();
        cards = await DatabaseHelper.instance.getAllCards(sortBy: _sortOrder);
      } else {
        _totalCount = await DatabaseHelper.instance
            .countCardsByFolderId(widget.folder.id!);
        cards = await DatabaseHelper.instance.getCardsByFolderIdSorted(
          widget.folder.id!,
          _sortOrder,
        );
      }
      if (!mounted) return;
      setState(() {
        _cards
          ..clear()
          ..addAll(cards);
        _loading = false;
      });
      _precacheCardImages();
      return;
    }

    // 스크롤 위치 저장 (리로드 후 복원용)
    int? savedIndex;
    if (_cards.isNotEmpty && _searchQuery.isEmpty) {
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
      await _performSearch();
      return;
    }

    if (widget.allCards) {
      _totalCount = await DatabaseHelper.instance.getTotalCardCount();
      final cards = await DatabaseHelper.instance.getAllCards(sortBy: _sortOrder);
      if (!mounted) return;
      setState(() {
        _cards
          ..clear()
          ..addAll(cards);
        _loading = false;
      });
    } else {
      _totalCount = await DatabaseHelper.instance
          .countCardsByFolderId(widget.folder.id!);
      final cards =
          await DatabaseHelper.instance.getCardsByFolderIdSorted(
        widget.folder.id!,
        _sortOrder,
      );
      if (!mounted) return;
      setState(() {
        _cards
          ..clear()
          ..addAll(cards);
        _loading = false;
      });
    }
    _precacheCardImages();
    // 스크롤 위치 복원
    if (savedIndex != null && savedIndex > 0 && _cards.isNotEmpty) {
      final idx = savedIndex.clamp(0, _cards.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _itemScrollController.isAttached) {
          _itemScrollController.jumpTo(index: idx);
        }
      });
    }
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
  }

  Future<void> _performSearch() async {
    final generation = ++_searchGeneration;
    List<CardModel> results;
    if (widget.allCards) {
      results =
          await DatabaseHelper.instance.searchAllCards(_searchQuery);
    } else {
      results = await DatabaseHelper.instance
          .searchCards(widget.folder.id!, _searchQuery);
    }
    // stale 결과 무시 (더 새로운 검색이 시작된 경우)
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _cards.clear();
      _cards.addAll(results);
      _totalCount = results.length;
      _loading = false;
    });
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
  List<String> _collectCardFilePaths(CardModel card) {
    final paths = <String>[
      ...card.questionImagePaths,
      ...card.answerImagePaths,
    ];
    for (final p in [
      card.questionHandImagePath, card.questionHandImagePath2,
      card.questionHandImagePath3, card.questionHandImagePath4,
      card.questionHandImagePath5,
      card.answerHandImagePath, card.answerHandImagePath2,
      card.answerHandImagePath3, card.answerHandImagePath4,
      card.answerHandImagePath5,
      card.questionVoiceRecordPath, card.questionVoiceRecordPath2,
      card.questionVoiceRecordPath3, card.questionVoiceRecordPath4,
      card.questionVoiceRecordPath5, card.questionVoiceRecordPath6,
      card.questionVoiceRecordPath7, card.questionVoiceRecordPath8,
      card.questionVoiceRecordPath9, card.questionVoiceRecordPath10,
      card.answerVoiceRecordPath, card.answerVoiceRecordPath2,
      card.answerVoiceRecordPath3, card.answerVoiceRecordPath4,
      card.answerVoiceRecordPath5, card.answerVoiceRecordPath6,
      card.answerVoiceRecordPath7, card.answerVoiceRecordPath8,
      card.answerVoiceRecordPath9, card.answerVoiceRecordPath10,
    ]) {
      if (p != null && p.isNotEmpty) paths.add(p);
    }
    return paths;
  }

  /// 파일 경로 리스트의 파일들을 디스크에서 삭제
  Future<void> _deleteFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _deleteCard(CardModel card) async {
    final t = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cardDeleteTitle),
        content: Text(t.cardDeleteSingleConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.commonDelete,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

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

  Future<void> _moveCard(CardModel card) async {
    final t = AppLocalizations.of(context);
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    final sourceFolderId = card.folderId;
    final target = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.cardPickFolderTitle),
        children: folders
            .where((f) => f.id != sourceFolderId)
            .map((f) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, f),
                  child: Text('${f.name} (${f.cardCount})'),
                ))
            .toList(),
      ),
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
    await Navigator.push<int?>(
      context,
      MaterialPageRoute(
        builder: (_) => CardEditScreen(
          folderId: card.folderId,
          existingCard: card,
        ),
      ),
    );
    if (!mounted) return;
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

  Future<void> _deleteSelected() async {
    final t = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cardDeleteTitle),
        content: Text(t.cardDeleteMultiConfirm(_selectedCardIds.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.commonDelete,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // 삭제 전 파일 경로 수집
    final selectedCards = _cards
        .where((c) => _selectedCardIds.contains(c.id))
        .toList();
    final allFilePaths = <String>[];
    for (final card in selectedCards) {
      allFilePaths.addAll(_collectCardFilePaths(card));
    }

    // deleteCardsBatch 내부에서 트랜잭션으로 folder card_count 자동 갱신
    final deletedIds = _selectedCardIds.toList();
    await DatabaseHelper.instance.deleteCardsBatch(deletedIds);
    await _deleteFiles(allFilePaths);
    if (!mounted) return;
    _exitSelectionMode();
    if (_searchQuery.isNotEmpty) {
      await _loadCards();
    } else {
      _removeCardsLocally(deletedIds);
    }
  }

  Future<void> _moveSelected() async {
    final t = AppLocalizations.of(context);
    var folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    if (!widget.allCards) {
      folders = folders.where((f) => f.id != widget.folder.id).toList();
    }
    final target = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.cardMoveTargetTitle),
        children: folders.map((f) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f),
              child: Text('${f.name} (${f.cardCount})'),
            )).toList(),
      ),
    );
    if (target == null || !mounted) return;

    final allIds = _selectedCardIds.toList();
    final duplicates = await DatabaseHelper.instance
        .findDuplicateCardIdsInFolder(allIds, target.id!);
    if (!mounted) return;

    var idsToMove = allIds;
    var skipped = 0;
    if (duplicates.isNotEmpty) {
      final action = await _showDuplicateMoveDialog(
          duplicateCount: duplicates.length, totalCount: allIds.length);
      if (action == null || action == 'cancel' || !mounted) return;
      if (action == 'skip') {
        idsToMove = allIds.where((id) => !duplicates.contains(id)).toList();
        skipped = allIds.length - idsToMove.length;
        if (idsToMove.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.cardMoveNoneToMove)),
          );
          _exitSelectionMode();
          return;
        }
      }
    }

    await DatabaseHelper.instance.moveCardsBatch(idsToMove, target.id!);
    if (!mounted) return;
    _exitSelectionMode();
    if (_searchQuery.isNotEmpty) {
      await _loadCards();
    } else if (widget.allCards) {
      // allCards 모드: 카드는 그대로 표시 — folder 변경은 화면 표시에 영향 없음
    } else {
      // 일반 폴더 모드: 다른 폴더로 이동된 카드들을 현재 리스트에서 제거
      _removeCardsLocally(idsToMove);
    }

    if (skipped > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.cardMoveResult(idsToMove.length, skipped))),
      );
    }
  }

  // ─── Answer fold/hide ───

  void _toggleQuestionFold(CardModel card) {
    final cardId = card.id;
    if (cardId == null) return;
    setState(() {
      if (_foldedCards.contains(cardId)) {
        _foldedCards.remove(cardId);
      } else {
        _foldedCards.add(cardId);
      }
    });
  }

  void _toggleAnswerReveal(CardModel card) {
    final cardId = card.id;
    if (cardId == null) return;
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
    return CardTile(
      card: card,
      isFolded: _isCardFolded(card),
      isHidden: _allAnswersHidden,
      isRevealed: _isCardRevealed(card),
      isSelectionMode: _isSelectionMode,
      isSelected: _selectedCardIds.contains(card.id),
      isHighlighted: isHighlighted,
      cardNumber: _showCardNumber ? index + 1 : null,
      searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
      onQuestionTap: () => _toggleQuestionFold(card),
      onAnswerTap: () => _toggleAnswerReveal(card),
      onTap: _isSelectionMode
          ? () => _toggleCardSelection(card)
          : () => _editCard(card),
      onLongPress: _isSelectionMode
          ? null
          : () => _enterSelectionMode(card),
      onMenuAction: (action) => _handleCardMenu(card, action),
    );
  }

  /// 카드 리스트
  /// 소량 카드(≤30)는 ListView.builder (ScrollablePositionedList 소량 스크롤 버그 회피)
  /// 대량 카드는 ScrollablePositionedList (index 기반 점프, 드래그 인디케이터)
  Widget _buildCardList() {
    if (_useSimpleList) {
      final list = ListView.builder(
        controller: _simpleScrollController,
        itemCount: _cards.length,
        itemBuilder: _buildCardItem,
        physics: const ClampingScrollPhysics(),
      );
      if (_showScrollbar) {
        return Scrollbar(
          controller: _simpleScrollController,
          thumbVisibility: true,
          child: list,
        );
      }
      return list;
    }
    return ScrollablePositionedList.builder(
      itemCount: _cards.length,
      itemBuilder: _buildCardItem,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      physics: const ClampingScrollPhysics(),
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
                    _searchController.clear();
                    _searchQuery = '';
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
        _itemScrollController.jumpTo(index: _pendingJumpIndex);
      });
    }
  }

  PreferredSizeWidget _buildNormalAppBar() {
    final t = AppLocalizations.of(context);
    return AppBar(
      title: Text(
        widget.allCards
            ? t.cardListAllCardsTitle(_totalCount)
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
                  _searchController.clear();
                  _searchQuery = '';
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
