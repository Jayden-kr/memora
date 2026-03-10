import 'package:flutter/material.dart';

import '../services/memk_import_service.dart';

class ImportScreen extends StatefulWidget {
  final String filePath;

  const ImportScreen({required this.filePath, super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

enum _ImportStage { loading, folderSelect, importing, done, error }

class _ImportScreenState extends State<ImportScreen> {
  final _importService = MemkImportService();

  _ImportStage _stage = _ImportStage.loading;
  List<Map<String, dynamic>> _folders = [];
  final Set<String> _selectedFolderNames = {};

  // 진행률
  ImportProgress _progress = const ImportProgress();
  ImportResult? _result;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadFolderList();
  }

  Future<void> _loadFolderList() async {
    try {
      final folders = await _importService.readFolderList(widget.filePath);
      setState(() {
        _folders = folders;
        // 기본: 전체 선택
        _selectedFolderNames.addAll(
          folders.map((f) => f['name'] as String),
        );
        _stage = _ImportStage.folderSelect;
      });
    } catch (e) {
      setState(() {
        _stage = _ImportStage.error;
        _errorMessage = '파일을 읽을 수 없습니다: $e';
      });
    }
  }

  Future<void> _startImport() async {
    if (_selectedFolderNames.isEmpty) return;

    setState(() => _stage = _ImportStage.importing);

    try {
      final result = await _importService.importSelectedFolders(
        filePath: widget.filePath,
        selectedFolderNames: _selectedFolderNames.toList(),
        onProgress: (progress) {
          if (mounted) {
            setState(() => _progress = progress);
          }
        },
      );
      if (mounted) {
        setState(() {
          _result = result;
          _stage = _ImportStage.done;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _ImportStage.error;
          _errorMessage = 'Import 실패: $e';
        });
      }
    }
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedFolderNames.length == _folders.length) {
        _selectedFolderNames.clear();
      } else {
        _selectedFolderNames.clear();
        _selectedFolderNames.addAll(
          _folders.map((f) => f['name'] as String),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage != _ImportStage.importing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import'),
          leading: _stage == _ImportStage.importing
              ? const SizedBox.shrink()
              : null,
        ),
        body: switch (_stage) {
          _ImportStage.loading => _buildLoading(),
          _ImportStage.folderSelect => _buildFolderSelect(),
          _ImportStage.importing => _buildImporting(),
          _ImportStage.done => _buildDone(),
          _ImportStage.error => _buildError(),
        },
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('파일 분석 중...'),
        ],
      ),
    );
  }

  Widget _buildFolderSelect() {
    final allSelected = _selectedFolderNames.length == _folders.length;
    return Column(
      children: [
        // 전체 선택/해제
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '폴더 ${_folders.length}개',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              TextButton(
                onPressed: _toggleSelectAll,
                child: Text(allSelected ? '전체 해제' : '전체 선택'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 폴더 리스트
        Expanded(
          child: ListView.builder(
            itemCount: _folders.length,
            itemBuilder: (context, index) {
              final folder = _folders[index];
              final name = folder['name'] as String;
              final cardCount = folder['cardCount'] as int? ?? 0;
              final isSelected = _selectedFolderNames.contains(name);
              return CheckboxListTile(
                title: Text(name),
                subtitle: Text('$cardCount장'),
                value: isSelected,
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedFolderNames.add(name);
                    } else {
                      _selectedFolderNames.remove(name);
                    }
                  });
                },
              );
            },
          ),
        ),
        // Import 버튼
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    _selectedFolderNames.isEmpty ? null : _startImport,
                child: Text(
                  'Import (${_selectedFolderNames.length}개 폴더)',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImporting() {
    final cardProgress = _progress.totalCards > 0
        ? _progress.currentCards / _progress.totalCards
        : 0.0;
    final imageProgress = _progress.totalImages > 0
        ? _progress.currentImages / _progress.totalImages
        : 0.0;

    final progress = _progress.phase == 'images'
        ? (cardProgress + imageProgress) / 2
        : cardProgress * 0.5;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
            const SizedBox(height: 24),
            Text(
              _progress.message ?? '처리 중...',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDone() {
    final r = _result!;
    final minutes = r.duration.inMinutes;
    final seconds = r.duration.inSeconds % 60;
    final timeStr = minutes > 0 ? '$minutes분 $seconds초' : '$seconds초';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            Text(
              'Import 완료',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            _resultRow('신규 카드', '${r.newCards}장'),
            _resultRow('스킵 (중복)', '${r.skippedCards}장'),
            _resultRow('신규 폴더', '${r.newFolders}개'),
            _resultRow('병합 폴더', '${r.mergedFolders}개'),
            _resultRow('이미지', '${r.images}장'),
            if (r.errors > 0) _resultRow('에러', '${r.errors}건'),
            _resultRow('소요 시간', timeStr),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('확인'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '알 수 없는 에러',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('돌아가기'),
            ),
          ],
        ),
      ),
    );
  }
}
