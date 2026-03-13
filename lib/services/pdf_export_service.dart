import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/services.dart' show rootBundle;

import '../database/database_helper.dart';

/// PDF 내보내기 진행 상태
class PdfExportProgress {
  final int currentFolders;
  final int totalFolders;
  final String? message;

  const PdfExportProgress({
    this.currentFolders = 0,
    this.totalFolders = 0,
    this.message,
  });
}

class PdfExportService {
  static pw.Font? _koreanFont;

  Future<pw.Font> _getKoreanFont() async {
    if (_koreanFont != null) return _koreanFont!;
    try {
      final fontData =
          await rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf');
      _koreanFont = pw.Font.ttf(fontData);
    } catch (e) {
      throw Exception('한글 폰트 로딩 실패: $e\n'
          'assets/fonts/NotoSansKR-Regular.ttf 파일이 존재하는지 확인하세요.');
    }
    return _koreanFont!;
  }

  /// 이미지 파일을 비동기로 미리 읽어 캐싱
  Future<Map<String, Uint8List>> _preloadImages(List<String> paths) async {
    final cache = <String, Uint8List>{};
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          cache[path] = await file.readAsBytes();
        }
      } catch (_) {}
    }
    return cache;
  }

  /// 선택된 폴더의 카드를 PDF로 내보내기
  Future<void> exportPdf({
    required String outputPath,
    required List<int> folderIds,
    required void Function(PdfExportProgress) onProgress,
  }) async {
    final db = DatabaseHelper.instance;
    final font = await _getKoreanFont();

    final doc = pw.Document();
    int processedFolders = 0;

    const pdfBatchSize = 100;

    for (final folderId in folderIds) {
      final folder = await db.getFolderById(folderId);
      if (folder == null) continue;

      final totalCards = await db.countCardsByFolderId(folderId);

      processedFolders++;
      onProgress(PdfExportProgress(
        currentFolders: processedFolders,
        totalFolders: folderIds.length,
        message: '${folder.name} 처리 중... ($totalCards장)',
      ));

      // 배치 단위로 카드 로드 + 이미지 캐싱 + PDF 페이지 생성 (메모리 절약)
      for (int batchStart = 0;
          batchStart < totalCards;
          batchStart += pdfBatchSize) {
        final batch = await db.getCardsByFolderId(
          folderId,
          limit: pdfBatchSize,
          offset: batchStart,
        );
        if (batch.isEmpty) break;
        final isFirstBatch = batchStart == 0;

        // 이 배치의 이미지만 캐싱
        final batchImagePaths = <String>[];
        for (final card in batch) {
          batchImagePaths.addAll(card.questionImagePaths);
          batchImagePaths.addAll(card.answerImagePaths);
        }
        final imageCache = await _preloadImages(batchImagePaths);

        doc.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            header: (context) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (isFirstBatch && context.pageNumber == 1) ...[
                  pw.Text(
                    folder.name,
                    style: pw.TextStyle(font: font, fontSize: 24,
                        fontWeight: pw.FontWeight.bold),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    '카드 ${cards.length}장',
                    style: pw.TextStyle(font: font, fontSize: 12,
                        color: PdfColors.grey600),
                  ),
                  pw.Divider(),
                  pw.SizedBox(height: 8),
                ],
              ],
            ),
            build: (context) => batch
                .map((card) => _buildCardWidget(
                      card.question,
                      card.answer,
                      card.questionImagePaths,
                      card.answerImagePaths,
                      font,
                      imageCache,
                    ))
                .toList(),
            footer: (context) => pw.Container(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                '${context.pageNumber} / ${context.pagesCount}',
                style: pw.TextStyle(font: font, fontSize: 9,
                    color: PdfColors.grey500),
              ),
            ),
          ),
        );
        // imageCache는 스코프를 벗어나며 GC 대상
      }
    }

    final bytes = await doc.save();
    await File(outputPath).writeAsBytes(bytes);

    onProgress(PdfExportProgress(
      currentFolders: folderIds.length,
      totalFolders: folderIds.length,
      message: 'PDF 생성 완료',
    ));
  }

  pw.Widget _buildImageRow(
    List<String> paths,
    pw.Font font,
    Map<String, Uint8List> imageCache,
  ) {
    return pw.Wrap(
      spacing: 6,
      runSpacing: 6,
      children: paths.map((path) {
        final bytes = imageCache[path];
        if (bytes != null) {
          final image = pw.MemoryImage(bytes);
          return pw.Container(
            width: 80,
            height: 80,
            child: pw.Image(image, fit: pw.BoxFit.contain),
          );
        }
        return pw.SizedBox.shrink();
      }).toList(),
    );
  }

  pw.Widget _buildCardWidget(
    String question,
    String answer,
    List<String> questionImagePaths,
    List<String> answerImagePaths,
    pw.Font font,
    Map<String, Uint8List> imageCache,
  ) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 12),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            question.isEmpty ? '(내용 없음)' : question,
            style: pw.TextStyle(font: font, fontSize: 12,
                fontWeight: pw.FontWeight.bold),
          ),
          if (questionImagePaths.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: _buildImageRow(questionImagePaths, font, imageCache),
            ),
          pw.SizedBox(height: 4),
          pw.Divider(color: PdfColors.grey200),
          pw.SizedBox(height: 4),
          if (answer.isNotEmpty)
            pw.Text(
              answer,
              style: pw.TextStyle(font: font, fontSize: 11),
            ),
          if (answerImagePaths.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: _buildImageRow(answerImagePaths, font, imageCache),
            ),
        ],
      ),
    );
  }
}
