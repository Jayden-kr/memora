import 'dart:io';

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
  pw.Font? _koreanFont;

  Future<pw.Font> _getKoreanFont() async {
    if (_koreanFont != null) return _koreanFont!;
    try {
      final fontData =
          await rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf');
      _koreanFont = pw.Font.ttf(fontData);
    } catch (_) {
      _koreanFont = pw.Font.helvetica();
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

    for (final folderId in folderIds) {
      final folder = await db.getFolderById(folderId);
      if (folder == null) continue;

      final cards = await db.getCardsByFolderId(folderId);

      processedFolders++;
      onProgress(PdfExportProgress(
        currentFolders: processedFolders,
        totalFolders: folderIds.length,
        message: '${folder.name} 처리 중...',
      ));

      // MultiPage로 자동 페이지네이션
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          header: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (context.pageNumber == 1) ...[
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
          build: (context) => cards
              .map((card) => _buildCardWidget(
                    card.question,
                    card.answer,
                    card.answerImagePaths,
                    font,
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
    }

    final bytes = await doc.save();
    await File(outputPath).writeAsBytes(bytes);

    onProgress(PdfExportProgress(
      currentFolders: folderIds.length,
      totalFolders: folderIds.length,
      message: 'PDF 생성 완료',
    ));
  }

  pw.Widget _buildCardWidget(
    String question,
    String answer,
    List<String> imagePaths,
    pw.Font font,
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
          pw.SizedBox(height: 4),
          pw.Divider(color: PdfColors.grey200),
          pw.SizedBox(height: 4),
          if (answer.isNotEmpty)
            pw.Text(
              answer,
              style: pw.TextStyle(font: font, fontSize: 11),
            ),
          if (imagePaths.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Row(
                children: imagePaths.take(3).map((path) {
                  try {
                    final file = File(path);
                    if (file.existsSync()) {
                      final bytes = file.readAsBytesSync();
                      final image = pw.MemoryImage(bytes);
                      return pw.Container(
                        width: 80,
                        height: 80,
                        margin: const pw.EdgeInsets.only(right: 6),
                        child: pw.Image(image, fit: pw.BoxFit.contain),
                      );
                    }
                  } catch (_) {}
                  return pw.SizedBox.shrink();
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
