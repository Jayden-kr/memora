import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/services.dart' show rootBundle;

import '../database/database_helper.dart';

/// PDF 내보내기 진행 상태
class PdfExportProgress {
  final int currentCards;
  final int totalCards;
  final int currentFolders;
  final int totalFolders;
  final String? message;

  const PdfExportProgress({
    this.currentCards = 0,
    this.totalCards = 0,
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
    int processedCards = 0;
    int grandTotalCards = 0;

    // 전체 카드 수 미리 계산 (진행률용)
    for (final folderId in folderIds) {
      grandTotalCards += await db.countCardsByFolderId(folderId);
    }
    if (grandTotalCards == 0) grandTotalCards = 1; // division by zero 방지

    const batchSize = 20;

    for (final folderId in folderIds) {
      final folder = await db.getFolderById(folderId);
      if (folder == null) continue;

      final totalCards = await db.countCardsByFolderId(folderId);
      processedFolders++;

      if (totalCards == 0) continue;

      int batchStart = 0;
      bool isFirstBatch = true;

      while (batchStart < totalCards) {
        final batch = await db.getCardsByFolderId(
          folderId,
          limit: batchSize,
          offset: batchStart,
        );
        if (batch.isEmpty) break;

        // 이 배치의 이미지만 로드 (대용량 이미지 제한: 500KB)
        final batchImagePaths = <String>[];
        for (final card in batch) {
          batchImagePaths.addAll(card.questionImagePaths);
          batchImagePaths.addAll(card.answerImagePaths);
        }
        final imageCache = await _preloadImages(batchImagePaths);

        final batchWidgets = <pw.Widget>[];
        for (final card in batch) {
          batchWidgets.add(_buildCardWidget(
            card.question,
            card.answer,
            card.questionImagePaths,
            card.answerImagePaths,
            font,
            imageCache,
          ));
          processedCards++;
        }

        // 카드 단위 진행률 보고
        onProgress(PdfExportProgress(
          currentCards: processedCards,
          totalCards: grandTotalCards,
          currentFolders: processedFolders,
          totalFolders: folderIds.length,
          message: '${folder.name} ($processedCards/$grandTotalCards)',
        ));

        final showHeader = isFirstBatch;
        final folderName = folder.name;

        doc.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            header: showHeader
                ? (context) => pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (context.pageNumber == 1) ...[
                          pw.Text(
                            folderName,
                            style: pw.TextStyle(
                              font: font,
                              fontSize: 24,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Text(
                            '카드 $totalCards장',
                            style: pw.TextStyle(
                              font: font,
                              fontSize: 12,
                              color: PdfColors.grey600,
                            ),
                          ),
                          pw.Divider(),
                          pw.SizedBox(height: 8),
                        ],
                      ],
                    )
                : null,
            build: (context) => batchWidgets,
            footer: (context) => pw.Container(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                '${context.pageNumber}',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 9,
                  color: PdfColors.grey500,
                ),
              ),
            ),
          ),
        );

        isFirstBatch = false;
        batchStart += batchSize;
        await Future.delayed(Duration.zero); // yield to event loop
      }
    }

    onProgress(PdfExportProgress(
      currentCards: grandTotalCards,
      totalCards: grandTotalCards,
      currentFolders: folderIds.length,
      totalFolders: folderIds.length,
      message: 'PDF 파일 저장 중...',
    ));

    final bytes = await doc.save();
    await File(outputPath).writeAsBytes(bytes, flush: true);

    onProgress(PdfExportProgress(
      currentCards: grandTotalCards,
      totalCards: grandTotalCards,
      currentFolders: folderIds.length,
      totalFolders: folderIds.length,
      message: 'PDF 생성 완료',
    ));
  }

  /// 이미지를 PDF 표시 크기(70px)로 축소하여 로드 — OOM 방지
  /// dart:ui 하드웨어 디코더로 축소 후 PNG 인코딩 → 원본 대비 ~1/20 크기
  Future<Map<String, Uint8List>> _preloadImages(List<String> paths) async {
    final cache = <String, Uint8List>{};
    for (final path in paths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final rawBytes = await file.readAsBytes();
        final compressed = await _compressForPdf(rawBytes);
        if (compressed != null) {
          cache[path] = compressed;
        }
      } catch (_) {}
    }
    return cache;
  }

  /// dart:ui로 이미지를 70px 썸네일 PNG로 변환
  Future<Uint8List?> _compressForPdf(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 70,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) return null;
      return byteData.buffer.asUint8List();
    } catch (e) {
      debugPrint('[PDF] _compressForPdf 실패: $e');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  pw.Widget _buildImageRow(
    List<String> paths,
    Map<String, Uint8List> imageCache,
  ) {
    final images = paths
        .where((p) => imageCache.containsKey(p))
        .map((path) {
          final image = pw.MemoryImage(imageCache[path]!);
          return pw.Container(
            width: 70,
            height: 70,
            child: pw.Image(image, fit: pw.BoxFit.contain),
          );
        })
        .toList();
    if (images.isEmpty) return pw.SizedBox.shrink();
    return pw.Wrap(spacing: 6, runSpacing: 6, children: images);
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
            style: pw.TextStyle(
              font: font,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (questionImagePaths.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: _buildImageRow(questionImagePaths, imageCache),
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
              child: _buildImageRow(answerImagePaths, imageCache),
            ),
        ],
      ),
    );
  }
}
