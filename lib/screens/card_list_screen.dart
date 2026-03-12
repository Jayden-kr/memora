import 'dart:async';

import 'package:flutter/material.dart';

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
  final ScrollController _scrollController = ScrollController();
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
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

  // 스크롤 위치 표시
  bool _showScrollLabel = false;
  Timer? _scrollLabelTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadCards().then((_) => _scrollToInitialCard());
  }

  void _scrollToInitialCard() {
    final targetId = widget.scrollToCardId;
    if (targetId == null) return;
    final index = _cards.indexWhere((c) => c.id == targetId);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      // 카드 타일 대략 높이 ~100
      final offset = (index * 100.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    _scrollLabelTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _hasMore &&
        _searchQuery.isEmpty) {
      _loadMoreCards();
    }
    // 스크롤 위치 라벨 표시
    if (!_showScrollLabel) {
      setState(() => _showScrollLabel = true);
    }
    _scrollLabelTimer?.cancel();
    _scrollLabelTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showScrollLabel = false);
    });
  }

  int get _currentVisibleIndex {
    if (_cards.isEmpty || !_scrollController.hasClients) return 0;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return 1;
    final ratio = (_scrollController.position.pixels / maxScroll)
        .clamp(0.0, 1.0);
    return (ratio * (_cards.length - 1)).round() + 1;
  }

  Future<void> _loadCards() async {
    setState(() {
      _loading = true;
      _cards.clear();
      _hasMore = true;
    });

    if (_searchQuery.isNotEmpty) {
      await _performSearch();
      return;
    }

    if (widget.allCards) {
      _totalCount = await DatabaseHelper.instance.getTotalCardCount();
      final cards = await DatabaseHelper.instance.getAllCards(
        limit: AppConstants.pageSize,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        _cards.addAll(cards);
        _hasMore = cards.length >= AppConstants.pageSize;
        _loading = false;
      });
    } else {
      _totalCount = await DatabaseHelper.instance
          .countCardsByFolderId(widget.folder.id!);
      final cards =
          await DatabaseHelper.instance.getCardsByFolderIdSorted(
        widget.folder.id!,
        _sortOrder,
        limit: AppConstants.pageSize,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        _cards.addAll(cards);
        _hasMore = cards.length >= AppConstants.pageSize;
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreCards() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);

    List<CardModel> cards;
    if (widget.allCards) {
      cards = await DatabaseHelper.instance.getAllCards(
        limit: AppConstants.pageSize,
        offset: _cards.length,
      );
    } else {
      cards = await DatabaseHelper.instance.getCardsByFolderIdSorted(
        widget.folder.id!,
        _sortOrder,
        limit: AppConstants.pageSize,
        offset: _cards.length,
      );
    }
    if (!mounted) return;
    setState(() {
      _cards.addAll(cards);
      _hasMore = cards.length >= AppConstants.pageSize;
      _loadingMore = false;
    });
  }

  Future<void> _performSearch() async {
    List<CardModel> results;
    if (widget.allCards) {
      results =
          await DatabaseHelper.instance.searchAllCards(_searchQuery);
    } else {
      results = await DatabaseHelper.instance
          .searchCards(widget.folder.id!, _searchQuery);
    }
    if (!mounted) return;
    setState(() {
      _cards.clear();
      _cards.addAll(results);
      _totalCount = results.length;
      _hasMore = false;
      _loading = false;
    });
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      setState(() => _searchQuery = query.trim());
      _loadCards();
    });
  }

  // ─── Card actions ───

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
    if (confirm != true) return;

    await DatabaseHelper.instance.deleteCard(card.id!);
    await DatabaseHelper.instance.updateFolderCardCount(widget.folder.id!);
    await _loadCards();
  }

  Future<void> _duplicateCard(CardModel card) async {
    await DatabaseHelper.instance.duplicateCard(card.id!);
    await _loadCards();
  }

  Future<void> _moveCard(CardModel card) async {
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
    final target = await showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('폴더 선택'),
        children: folders
            .where((f) => f.id != widget.folder.id)
            .map((f) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, f),
                  child: Text('${f.name} (${f.cardCount})'),
                ))
            .toList(),
      ),
    );
    if (target == null) return;

    await DatabaseHelper.instance.moveCard(card.id!, target.id!);
    await DatabaseHelper.instance.updateFolderCardCount(widget.folder.id!);
    await DatabaseHelper.instance.updateFolderCardCount(target.id!);
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
    _loadCards();
  }

  // ─── Selection mode ───

  void _enterSelectionMode(CardModel card) {
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
    if (confirm != true) return;

    await DatabaseHelper.instance
        .deleteCardsBatch(_selectedCardIds.toList());
    if (!widget.allCards) {
      await DatabaseHelper.instance
          .updateFolderCardCount(widget.folder.id!);
    }
    _exitSelectionMode();
    await _loadCards();
  }

  Future<void> _moveSelected() async {
    final folders = await DatabaseHelper.instance.getNonBundleFolders();
    if (!mounted) return;
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
    if (target == null) return;

    await DatabaseHelper.instance
        .moveCardsBatch(_selectedCardIds.toList(), target.id!);
    if (!widget.allCards) {
      await DatabaseHelper.instance
          .updateFolderCardCount(widget.folder.id!);
    }
    await DatabaseHelper.instance.updateFolderCardCount(target.id!);
    _exitSelectionMode();
    await _loadCards();
  }

  // ─── Answer fold/hide ───

  void _toggleQuestionFold(CardModel card) {
    setState(() {
      if (_foldedCards.contains(card.id)) {
        _foldedCards.remove(card.id);
      } else {
        _foldedCards.add(card.id!);
      }
    });
  }

  void _toggleAnswerReveal(CardModel card) {
    setState(() {
      if (_revealedCards.contains(card.id)) {
        _revealedCards.remove(card.id);
      } else {
        _revealedCards.add(card.id!);
      }
    });
  }

  bool _isCardFolded(CardModel card) {
    if (_allAnswersFolded) {
      return !_foldedCards.contains(card.id); // toggle inverts
    }
    return _foldedCards.contains(card.id);
  }

  bool _isCardRevealed(CardModel card) {
    if (_allAnswersHidden) {
      return _revealedCards.contains(card.id);
    }
    return true; // not in hidden mode, always revealed
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
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _cards.isEmpty
                ? Center(
                    child: Text(_searchQuery.isNotEmpty
                        ? '검색 결과가 없습니다.'
                        : '카드가 없습니다.'),
                  )
                : Stack(
                    children: [
                      ScrollbarTheme(
                        data: ScrollbarThemeData(
                          thickness: WidgetStateProperty.all(3.0),
                          radius: const Radius.circular(1.5),
                          thumbColor: WidgetStateProperty.all(
                            Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withAlpha(60),
                          ),
                          minThumbLength: 36,
                        ),
                        child: Scrollbar(
                          controller: _scrollController,
                          thumbVisibility: true,
                          interactive: true,
                          child: ListView.builder(
                            controller: _scrollController,
                            itemCount: _cards.length + (_hasMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= _cards.length) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              final card = _cards[index];
                              return CardTile(
                                card: card,
                                isFolded: _isCardFolded(card),
                                isHidden: _allAnswersHidden,
                                isRevealed: _isCardRevealed(card),
                                isSelectionMode: _isSelectionMode,
                                isSelected:
                                    _selectedCardIds.contains(card.id),
                                onQuestionTap: () =>
                                    _toggleQuestionFold(card),
                                onAnswerTap: () =>
                                    _toggleAnswerReveal(card),
                                onTap: _isSelectionMode
                                    ? () => _toggleCardSelection(card)
                                    : () => _editCard(card),
                                onLongPress: _isSelectionMode
                                    ? null
                                    : () => _enterSelectionMode(card),
                                onMenuAction: (action) =>
                                    _handleCardMenu(card, action),
                              );
                            },
                          ),
                        ),
                      ),
                      // 스크롤 위치 라벨
                      if (_showScrollLabel && _cards.length > 1)
                        Positioned(
                          right: 14,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: _showScrollLabel ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 200),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .inverseSurface,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '$_currentVisibleIndex / $_totalCount',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onInverseSurface,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
        bottomNavigationBar: _isSelectionMode ? _buildSelectionBar() : null,
        floatingActionButton: _isSelectionMode
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
                  _loadCards();
                },
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
      title: _isSearching
          ? TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '검색...',
                border: InputBorder.none,
              ),
              onChanged: _onSearchChanged,
            )
          : Text(widget.allCards
              ? '전체 카드 ($_totalCount)'
              : '${widget.folder.name} ($_totalCount)'),
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
