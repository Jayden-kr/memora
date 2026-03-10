import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/card.dart';
import '../models/folder.dart';
import '../utils/constants.dart';
import '../widgets/card_tile.dart';
import 'card_edit_screen.dart';
import 'card_view_screen.dart';
import 'study_screen.dart';

class CardListScreen extends StatefulWidget {
  final Folder folder;

  const CardListScreen({super.key, required this.folder});

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

  // 필터: null = 전체, 0 = 암기 중, 1 = 암기 완료
  int? _finishedFilter;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadCards();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _hasMore) {
      _loadMoreCards();
    }
  }

  Future<void> _loadCards() async {
    setState(() {
      _loading = true;
      _cards.clear();
      _hasMore = true;
    });
    _totalCount = await DatabaseHelper.instance.countCardsByFolderId(
      widget.folder.id!,
      finished: _finishedFilter,
    );
    final cards = await DatabaseHelper.instance.getCardsByFolderId(
      widget.folder.id!,
      limit: AppConstants.pageSize,
      offset: 0,
      finished: _finishedFilter,
    );
    setState(() {
      _cards.addAll(cards);
      _hasMore = cards.length >= AppConstants.pageSize;
      _loading = false;
    });
  }

  Future<void> _loadMoreCards() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final cards = await DatabaseHelper.instance.getCardsByFolderId(
      widget.folder.id!,
      limit: AppConstants.pageSize,
      offset: _cards.length,
      finished: _finishedFilter,
    );
    setState(() {
      _cards.addAll(cards);
      _hasMore = cards.length >= AppConstants.pageSize;
      _loadingMore = false;
    });
  }

  Future<void> _deleteCard(CardModel card) async {
    await DatabaseHelper.instance.deleteCard(card.id!);
    await DatabaseHelper.instance.updateFolderCardCount(widget.folder.id!);
    await _loadCards();
  }

  void _setFilter(int? finished) {
    if (_finishedFilter == finished) return;
    _finishedFilter = finished;
    _loadCards();
  }

  Future<void> _showStudySettings() async {
    bool randomOrder = false;
    bool reversed = false;
    int? statusFilter = _finishedFilter;

    await showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('학습 설정', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('카드 순서', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(children: [
                  ChoiceChip(
                    label: const Text('순차'),
                    selected: !randomOrder,
                    onSelected: (_) =>
                        setSheetState(() => randomOrder = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('랜덤'),
                    selected: randomOrder,
                    onSelected: (_) =>
                        setSheetState(() => randomOrder = true),
                  ),
                ]),
                const SizedBox(height: 12),
                Text('상태 필터', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(children: [
                  ChoiceChip(
                    label: const Text('전체'),
                    selected: statusFilter == null,
                    onSelected: (_) =>
                        setSheetState(() => statusFilter = null),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('암기 중'),
                    selected: statusFilter == 0,
                    onSelected: (_) =>
                        setSheetState(() => statusFilter = 0),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('암기 완료'),
                    selected: statusFilter == 1,
                    onSelected: (_) =>
                        setSheetState(() => statusFilter = 1),
                  ),
                ]),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('문제/정답 바꾸기'),
                  subtitle: const Text('정답을 먼저 보고 문제를 맞춤'),
                  value: reversed,
                  onChanged: (v) => setSheetState(() => reversed = v),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _startStudy(
                        randomOrder: randomOrder,
                        statusFilter: statusFilter,
                        reversed: reversed,
                      );
                    },
                    child: const Text('학습 시작'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _startStudy({
    required bool randomOrder,
    int? statusFilter,
    required bool reversed,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudyScreen(
          folderId: widget.folder.id!,
          folderName: widget.folder.name,
          finishedFilter: statusFilter,
          randomOrder: randomOrder,
          reversed: reversed,
        ),
      ),
    ).then((_) => _loadCards());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.folder.name} ($_totalCount)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: '학습 시작',
            onPressed: _showStudySettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // 필터 칩
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _filterChip('전체', null),
                const SizedBox(width: 8),
                _filterChip('암기 중', 0),
                const SizedBox(width: 8),
                _filterChip('암기 완료', 1),
              ],
            ),
          ),
          // 카드 리스트
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _cards.isEmpty
                    ? const Center(child: Text('카드가 없습니다.'))
                    : ListView.builder(
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
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CardViewScreen(card: card),
                                ),
                              );
                              _loadCards();
                            },
                            onDismissed: () => _deleteCard(card),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CardEditScreen(folderId: widget.folder.id!),
            ),
          );
          _loadCards();
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _filterChip(String label, int? value) {
    final selected = _finishedFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _setFilter(value),
    );
  }
}
