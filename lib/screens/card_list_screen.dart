import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../database/database_helper.dart';
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
    // 저장된 정렬 순서 및 설정값 불러오기
    final settings = await DatabaseHelper.instance.getAllSettings();
    final saved = settings[_sortSettingKey];
    if (saved != null) _sortOrder = saved;

    // 설정 화면에서 지정한 기본값 적용
    final foldSetting = settings[AppConstants.settingAnswerFold];
    if (foldSetting == 'collapsed') _allAnswersFolded = true;

    final visSetting = settings[AppConstants.settingAnswerVisibility];
    if (visSetting == 'hidden') _allAnswersHidden = true;

    _showCardNumber = settings[AppConstants.settingCardNumber] == 'true';
    _showScrollbar = settings[AppConstants.settingCardScroll] == 'true';

    if (_isNotificationMode) {
      await _loadAllAndScrollToTarget();
    } else {
      await _loadCards();
    }
  }

  /// scrollToCardId가 설정된 경우: 전체 카드 로드 후 index 기반 스크롤
  Future<void> _loadAllAndScrollToTarget() async {
    final targetId = widget.scrollToCardId!;

    List<CardModel> cards;
    if (widget.allCards) {
      _totalCount = await DatabaseHelper.instance.getTotalCardCount();
      cards = await DatabaseHelper.instance.getAllCards();
    } else {
      _totalCount = await DatabaseHelper.instance
          .countCardsByFolderId(widget.folder.id!);
      cards = await DatabaseHelper.instance.getCardsByFolderIdSorted(
        widget.folder.id!,
        _sortOrder,
      );
    }

    final targetIndex = cards.indexWhere((c) => c.id == targetId);

    if (!mounted) return;
    setState(() {
      _cards
        ..clear()
        ..addAll(cards);
      _loading = false;
    });

    // ScrollablePositionedList가 빌드된 후 대상 인덱스로 점프
    if (targetIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_itemScrollController.isAttached) return;
        _itemScrollController.jumpTo(index: targetIndex);
      });
    }

    // 5초 후 하이라이트 해제
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _highlightCardId = null);
    });
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(_onItemPositionsChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
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
    if (_isDraggingThumb.value) return;
    _scrollLabelNotifier.value = _currentVisibleIndex;
    _scrollLabelTimer?.cancel();
    _scrollLabelTimer = Timer(const Duration(seconds: 1), () {
      _scrollLabelNotifier.value = 0;
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

  /// 카드 이미지를 백그라운드에서 미리 디코딩 (Glide 방식 프리캐시)
  Future<void> _precacheCardImages() async {
    for (final card in _cards) {
      if (!mounted) return;
      for (final path in card.questionImagePaths) {
        if (!mounted) return;
        try {
          await precacheImage(
            ResizeImage(FileImage(File(path)), width: 600),
            context,
          );
        } catch (_) {}
      }
      for (final path in card.answerImagePaths) {
        if (!mounted) return;
        try {
          await precacheImage(
            ResizeImage(FileImage(File(path)), width: 600),
            context,
          );
        } catch (_) {}
      }
    }
  }

  /// 전체 카드 로드 (페이지네이션 없음 — 암기짱 방식)
  Future<void> _loadCards() async {
    // 알림 모드에서 검색 아닌 리로드는 전체 리로드
    if (_isNotificationMode && _searchQuery.isEmpty) {
      List<CardModel> cards;
      if (widget.allCards) {
        _totalCount = await DatabaseHelper.instance.getTotalCardCount();
        cards = await DatabaseHelper.instance.getAllCards();
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
      final cards = await DatabaseHelper.instance.getAllCards();
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('카드 삭제'),
        content: const Text('이 카드를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final filePaths = _collectCardFilePaths(card);
    await DatabaseHelper.instance.deleteCard(card.id!);
    await DatabaseHelper.instance.updateFolderCardCount(card.folderId);
    await _deleteFiles(filePaths);
    if (!mounted) return;
    await _loadCards();
  }

  Future<void> _duplicateCard(CardModel card) async {
    await DatabaseHelper.instance.duplicateCard(card.id!);
    await _loadCards();
  }

  Future<void> _moveCard(CardModel card) async {
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    final sourceFolderId = card.folderId;
    final target = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('폴더 선택'),
        children: folders
            .where((f) => f.id != sourceFolderId)
            .map((f) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, f),
                  child: Text('${f.name} (${f.cardCount})'),
                ))
            .toList(),
      ),
    );
    if (target == null) return;

    await DatabaseHelper.instance.moveCard(card.id!, target.id!);
    // moveCard이 내부 트랜잭션에서 양쪽 폴더 카운트를 갱신하므로 별도 호출 불필요
    await _loadCards();
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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CardEditScreen(
          folderId: card.folderId,
          existingCard: card,
        ),
      ),
    );
    if (!mounted) return;
    _loadCards();
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
        _selectedCardIds.addAll(_cards.map((c) => c.id!));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('카드 삭제'),
        content: Text('${_selectedCardIds.length}개 카드를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
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

    if (widget.allCards) {
      final affectedFolderIds = selectedCards
          .map((c) => c.folderId)
          .toSet();
      await DatabaseHelper.instance
          .deleteCardsBatch(_selectedCardIds.toList());
      for (final fid in affectedFolderIds) {
        await DatabaseHelper.instance.updateFolderCardCount(fid);
      }
    } else {
      await DatabaseHelper.instance
          .deleteCardsBatch(_selectedCardIds.toList());
      await DatabaseHelper.instance
          .updateFolderCardCount(widget.folder.id!);
    }
    await _deleteFiles(allFilePaths);
    _exitSelectionMode();
    await _loadCards();
  }

  Future<void> _moveSelected() async {
    var folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    if (!widget.allCards) {
      folders = folders.where((f) => f.id != widget.folder.id).toList();
    }
    final target = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('이동할 폴더 선택'),
        children: folders.map((f) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f),
              child: Text('${f.name} (${f.cardCount})'),
            )).toList(),
      ),
    );
    if (target == null || !mounted) return;

    final sourceFolderIds = _cards
        .where((c) => _selectedCardIds.contains(c.id))
        .map((c) => c.folderId)
        .toSet();
    await DatabaseHelper.instance
        .moveCardsBatch(_selectedCardIds.toList(), target.id!);
    for (final fid in sourceFolderIds) {
      await DatabaseHelper.instance.updateFolderCardCount(fid);
    }
    await DatabaseHelper.instance.updateFolderCardCount(target.id!);
    _exitSelectionMode();
    await _loadCards();
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
                    hintText: '검색...',
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
                              ? '검색 결과가 없습니다.'
                              : '카드가 없습니다.'),
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
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          CardEditScreen(folderId: widget.folder.id!),
                    ),
                  );
                  if (!mounted) return;
                  _loadCards();
                },
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  /// 스크롤 위치 인디케이터 (드래그로 빠른 이동 지원)
  Widget _buildScrollIndicator() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        const indicatorHeight = 28.0;
        final maxOffset = trackHeight - indicatorHeight;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
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
              _scrollLabelNotifier.value = 0;
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
    return AppBar(
      title: Text(
        widget.allCards
            ? '전체 카드 ($_totalCount)'
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
                _loadCards();
              case 'fold_toggle':
                setState(() {
                  _allAnswersFolded = !_allAnswersFolded;
                  _foldedCards.clear();
                });
              case 'hide_toggle':
                setState(() {
                  _allAnswersHidden = !_allAnswersHidden;
                  _revealedCards.clear();
                });
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'sort_sequence',
              child: _menuItem('기본순', _sortOrder == 'sequence'),
            ),
            PopupMenuItem(
              value: 'sort_newest',
              child: _menuItem('최신순', _sortOrder == 'newest'),
            ),
            PopupMenuItem(
              value: 'sort_oldest',
              child: _menuItem('오래된순', _sortOrder == 'oldest'),
            ),
            PopupMenuItem(
              value: 'sort_name_asc',
              child: _menuItem('가나다순', _sortOrder == 'name_asc'),
            ),
            PopupMenuItem(
              value: 'sort_random',
              child: _menuItem('랜덤', _sortOrder == 'random'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'fold_toggle',
              child: Text(_allAnswersFolded ? '정답 펼치기' : '정답 접기'),
            ),
            PopupMenuItem(
              value: 'hide_toggle',
              child: Text(_allAnswersHidden ? '정답 보이기' : '정답 가리기'),
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
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectionMode,
      ),
      title: Text('${_selectedCardIds.length}개 선택됨'),
      actions: [
        Row(
          children: [
            const Text('전체선택'),
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
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            onPressed:
                _selectedCardIds.isEmpty ? null : _deleteSelected,
            icon: const Icon(Icons.delete),
            label: const Text('삭제'),
          ),
          TextButton.icon(
            onPressed:
                _selectedCardIds.isEmpty ? null : _moveSelected,
            icon: const Icon(Icons.drive_file_move),
            label: const Text('이동'),
          ),
        ],
      ),
    );
  }
}
