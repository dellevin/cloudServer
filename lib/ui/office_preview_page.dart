import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../l10n.dart';
import '../main.dart';
import 'file_preview_page.dart';

/// docx/xlsx 都是 zip 包: 解开读里面的 xml 提取内容。
/// 注意仅支持新格式 (.docx/.xlsx); 老格式 (.doc/.xls) 是 OLE2 二进制,
/// 无法这样解析, 路由层不会进这里。
Uint8List _zipEntryBytes(Archive archive, String name) {
  final f = archive.findFile(name);
  if (f == null) throw StateError('missing $name');
  final bytes = f.readBytes();
  if (bytes == null) throw StateError('cannot read $name');
  return bytes;
}

XmlDocument _zipEntryXml(Archive archive, String name) =>
    XmlDocument.parse(utf8.decode(_zipEntryBytes(archive, name)));

// ============================================================
// Word (.docx) 预览: 提取 word/document.xml 的段落纯文本
// ============================================================
class DocxViewPage extends StatefulWidget {
  const DocxViewPage({super.key});

  @override
  State<DocxViewPage> createState() => _DocxViewPageState();
}

class _DocxViewPageState extends State<DocxViewPage> {
  static const _paraCap = 2000; // 段落上限, 防超大文档卡死
  List<String>? _paras;
  bool _truncated = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_paras != null || _error != null) return;
    _load();
  }

  (String, bool) get _args =>
      parseViewerArgs(ModalRoute.of(context)!.settings.arguments);

  Future<void> _load() async {
    try {
      final archive = ZipDecoder().decodeBytes(
        await File(_args.$1).readAsBytes(),
      );
      final doc = _zipEntryXml(archive, 'word/document.xml');
      final paras = <String>[];
      for (final p in doc.findAllElements('w:p')) {
        final buf = StringBuffer();
        for (final node in p.descendants) {
          if (node is! XmlElement) continue;
          switch (node.localName) {
            case 't':
              buf.write(node.innerText);
            case 'tab':
              buf.write('\t');
            case 'br':
            case 'cr':
              buf.write('\n');
          }
        }
        paras.add(buf.toString());
        if (paras.length >= _paraCap) break;
      }
      if (mounted) {
        setState(() {
          _paras = paras;
          _truncated = paras.length >= _paraCap;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = tr('docx_read_fail'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final (path, tempPreview) = _args;
    final name = path.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontSize: 15)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
        actions: [
          if (tempPreview)
            IconButton(
              tooltip: tr('download'),
              icon: const Icon(Icons.save_alt),
              onPressed: () => downloadTempPreview(context, path),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) return _CenterText(_error!);
    final paras = _paras;
    if (paras == null) return const _Loading();
    final nonEmpty = paras.any((p) => p.trim().isNotEmpty);
    if (!nonEmpty) return _CenterText(tr('content_empty'));
    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.cardOf(context),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.lineOf(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in paras)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SelectableText(
                      p.isEmpty ? ' ' : p,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.6,
                        color: AppTheme.inkOf(context),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_truncated) _CapNote(n: _paraCap),
        ],
      ),
    );
  }
}

// ============================================================
// Excel (.xlsx) 预览: sharedStrings + sheet xml → 只读表格网格
// ============================================================

class _SheetData {
  final String name;
  final List<List<String>> rows;
  final bool truncated;
  const _SheetData(this.name, this.rows, this.truncated);
}

class XlsxViewPage extends StatefulWidget {
  const XlsxViewPage({super.key});

  @override
  State<XlsxViewPage> createState() => _XlsxViewPageState();
}

class _XlsxViewPageState extends State<XlsxViewPage> {
  static const _rowCap = 500; // 行数上限
  static const _colCap = 30; // 列数上限
  List<_SheetData>? _sheets;
  String? _error;
  int _cur = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sheets != null || _error != null) return;
    _load();
  }

  (String, bool) get _args =>
      parseViewerArgs(ModalRoute.of(context)!.settings.arguments);

  Future<void> _load() async {
    try {
      final archive = ZipDecoder().decodeBytes(
        await File(_args.$1).readAsBytes(),
      );
      // 共享字符串表 (单元格 t="s" 时内容是这里的下标)
      final shared = <String>[];
      if (archive.findFile('xl/sharedStrings.xml') != null) {
        final ss = _zipEntryXml(archive, 'xl/sharedStrings.xml');
        for (final si in ss.findAllElements('si')) {
          shared.add(
            si.findAllElements('t').map((t) => t.innerText).join(),
          );
        }
      }
      // 工作簿: sheet 名 + r:id → rels 里的目标文件
      final wb = _zipEntryXml(archive, 'xl/workbook.xml');
      final relsDoc = _zipEntryXml(archive, 'xl/_rels/workbook.xml.rels');
      final rels = <String, String>{
        for (final r in relsDoc.findAllElements('Relationship'))
          r.getAttribute('Id') ?? '': r.getAttribute('Target') ?? '',
      };
      final sheets = <_SheetData>[];
      for (final s in wb.findAllElements('sheet')) {
        var target = rels[s.getAttribute('r:id')] ?? '';
        if (target.isEmpty) continue;
        target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
        if (archive.findFile(target) == null) continue;
        final (rows, truncated) = _parseSheet(
          _zipEntryBytes(archive, target),
          shared,
        );
        sheets.add(
          _SheetData(
            s.getAttribute('name') ?? 'Sheet${sheets.length + 1}',
            rows,
            truncated,
          ),
        );
        if (sheets.length >= 10) break; // sheet 个数也兜个上限
      }
      if (mounted) setState(() => _sheets = sheets);
    } catch (_) {
      if (mounted) setState(() => _error = tr('xlsx_read_fail'));
    }
  }

  /// 解析单个 sheet: 返回 (行, 是否截断)
  (List<List<String>>, bool) _parseSheet(Uint8List bytes, List<String> shared) {
    final doc = XmlDocument.parse(utf8.decode(bytes));
    final sds = doc.findAllElements('sheetData');
    final rows = <List<String>>[];
    if (sds.isEmpty) return (rows, false);
    var truncated = false;
    for (final row in sds.first.findAllElements('row')) {
      if (rows.length >= _rowCap) {
        truncated = true;
        break;
      }
      final cells = <String>[];
      for (final c in row.findAllElements('c')) {
        // r="B5" → 列号 2 (字母部分转 26 进制)
        var col = 0;
        for (final ch in (c.getAttribute('r') ?? '').codeUnits) {
          if (ch >= 65 && ch <= 90) {
            col = col * 26 + (ch - 64);
          } else {
            break;
          }
        }
        final idx = col > 0 ? col - 1 : cells.length;
        if (idx >= _colCap) continue; // 超列上限直接丢
        while (cells.length < idx) {
          cells.add('');
        }
        final t = c.getAttribute('t');
        String v;
        if (t == 'inlineStr') {
          v = c.findAllElements('t').map((e) => e.innerText).join();
        } else {
          final vs = c.findElements('v');
          final raw = vs.isEmpty ? '' : vs.first.innerText;
          if (t == 's') {
            final i = int.tryParse(raw);
            v = (i != null && i >= 0 && i < shared.length) ? shared[i] : raw;
          } else {
            v = raw;
          }
        }
        if (cells.length == idx) {
          cells.add(v);
        } else {
          cells[idx] = v;
        }
      }
      rows.add(cells);
    }
    // Table 要求每行列数一致: 稀疏行补齐空串 (行内只垫到已出现的列, 行间长度不一)
    var maxCols = 0;
    for (final r in rows) {
      if (r.length > maxCols) maxCols = r.length;
    }
    for (final r in rows) {
      while (r.length < maxCols) {
        r.add('');
      }
    }
    return (rows, truncated);
  }

  @override
  Widget build(BuildContext context) {
    final (path, tempPreview) = _args;
    final name = path.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontSize: 15)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
        actions: [
          if (tempPreview)
            IconButton(
              tooltip: tr('download'),
              icon: const Icon(Icons.save_alt),
              onPressed: () => downloadTempPreview(context, path),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) return _CenterText(_error!);
    final sheets = _sheets;
    if (sheets == null) return const _Loading();
    if (sheets.isEmpty) return _CenterText(tr('content_empty'));
    final cur = _cur.clamp(0, sheets.length - 1);
    final sheet = sheets[cur];
    return Column(
      children: [
        // 多 sheet 时顶部一行切换 chip
        if (sheets.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (var i = 0; i < sheets.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        sheets[i].name,
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: i == cur,
                      onSelected: (_) => setState(() => _cur = i),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: sheet.rows.isEmpty
              ? _CenterText(tr('content_empty'))
              : Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: AppTheme.cardOf(context),
                              border: Border.all(
                                color: AppTheme.lineOf(context),
                              ),
                            ),
                            child: Table(
                              defaultColumnWidth: const FixedColumnWidth(120),
                              border: TableBorder.all(
                                color: AppTheme.lineOf(context),
                                width: 0.5,
                              ),
                              children: [
                                for (var r = 0; r < sheet.rows.length; r++)
                                  TableRow(
                                    decoration: r == 0
                                        ? BoxDecoration(
                                            color: AppTheme.softOf(context),
                                          )
                                        : null,
                                    children: [
                                      for (final cell in sheet.rows[r])
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 6,
                                          ),
                                          child: Text(
                                            cell,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: r == 0
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              color: AppTheme.inkOf(context),
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 3,
                                          ),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                          if (sheet.truncated) const _CapNote(n: _rowCap),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class _CenterText extends StatelessWidget {
  final String text;
  const _CenterText(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, style: const TextStyle(color: AppTheme.grey)),
  );
}

class _CapNote extends StatelessWidget {
  final int n;
  const _CapNote({required this.n});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      trf('rows_cap', {'n': n}),
      style: const TextStyle(fontSize: 11.5, color: AppTheme.grey),
    ),
  );
}
