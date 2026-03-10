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
      final fontData = await rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf');
      _koreanFont = pw.Font.ttf(fontData);
    } catch (_) {
      // 폰트가 없으면 기본 폰트 사용 (한글 깨질 수 있음)
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
    pw.Font? boldFont;
    try {
      final boldData = await rootBundle.load('assets/fonts/NotoSansKR-Bold.ttf');
      boldFont = pw.Font.ttf(boldData);
    } catch (_) {
      boldFont = font;
    }

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

      // 폴더 헤더 페이지
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                folder.name,
                style: pw.TextStyle(font: boldFont, fontSize: 24),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                '카드 ${cards.length}장',
                style: pw.TextStyle(font: font, fontSize: 14),
              ),
              pw.Divider(),
              pw.SizedBox(height: 16),
              ...cards.map((card) => _buildCardWidget(
                    card.question,
                    card.answer,
                    card.answerImagePaths,
                    font,
                    boldFont!,
                  )),
            ],
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
    pw.Font boldFont,
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
            style: pw.TextStyle(font: boldFont, fontSize: 12),
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
            pw.Row(
              children: imagePaths.take(3).map((path) {
                try {
                  final file = File(path);
                  if (file.existsSync()) {
                    final bytes = file.readAsBytesSync();
                    final image = pw.MemoryImage(bytes);
                    return pw.Container(
                      width: 60,
                      height: 60,
                      margin: const pw.EdgeInsets.only(right: 4, top: 4),
                      child: pw.Image(image, fit: pw.BoxFit.cover),
                    );
                  }
                } catch (_) {}
                return pw.SizedBox.shrink();
              }).toList(),
            ),
        ],
      ),
    );
  }
}
