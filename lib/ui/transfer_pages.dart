import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../domain/models.dart';
import '../services/transfer_service.dart';
import '../services/backup_service.dart';
import 'widgets.dart';
import 'pending_page.dart';

Future<void> clearPickerCache() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  try {
    await FilePicker.platform.clearTemporaryFiles();
  } catch (e) {
    debugPrint('Cache file picker: $e');
  }
}

Future<void> saveBytes(String name, Uint8List bytes) async {
  await FilePicker.platform.saveFile(
    dialogTitle: 'Salvează fișierul',
    fileName: name,
    bytes: bytes,
  );
}

Future<void> exportProducts(
  BuildContext context,
  AppState state,
  ProductFilter filter,
) async {
  final xlsx = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Exportă produsele'),
      content: const Text('Se exportă toate produsele din selecția curentă.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('CSV'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('XLSX'),
        ),
      ],
    ),
  );
  if (xlsx == null || !context.mounted) return;
  await guarded(
    context,
    () => state.exclusive(() async {
      final products = <Product>[];
      for (var offset = 0; ; offset += 500) {
        final page = await state.database.products(
          filter,
          offset: offset,
          limit: 500,
        );
        products.addAll(page);
        if (page.length < 500) break;
      }
      final all = state.categories;
      final roots = <String, String>{}, subs = <String, String>{};
      for (final n in all) {
        final names = <String>[n.name];
        var parent = n.parentId;
        while (parent != null) {
          final ancestor = all.firstWhere((c) => c.id == parent);
          names.insert(0, ancestor.name);
          parent = ancestor.parentId;
        }
        roots[n.id] = names.first;
        subs[n.id] = names.skip(1).join(' › ');
      }
      for (final p in products) {
        p.data['categoryId'] = p.data['categoryNodeId'];
        p.data['subcategoryId'] = p.data['categoryNodeId'];
      }
      final byId = {for (final p in products) p.id: p};
      for (final alias in await state.database.db.query('ProductBarcode')) {
        final original = byId[alias['productId']];
        if (original != null && original.text('barcode') != alias['barcode']) {
          products.add(
            Product({...original.data, 'barcode': alias['barcode']}),
          );
        }
      }
      final bytes = await compute(_encode, {
        'products': products,
        'roots': roots,
        'subs': subs,
        'xlsx': xlsx,
      });
      await saveBytes('Cauta-Pret.${xlsx ? 'xlsx' : 'csv'}', bytes);
    }),
  );
}

Uint8List _encode(Map<String, dynamic> args) => TransferService().encode(
  args['products'] as List<Product>,
  args['roots'] as Map<String, String>,
  args['subs'] as Map<String, String>,
  xlsx: args['xlsx'] as bool,
);
({List<ImportLine> lines, String sheet, String? sku, String? barcode}) _decode(
  (Uint8List, String) args,
) {
  final service = TransferService();
  final lines = service.decode(args.$1, args.$2);
  return (
    lines: lines,
    sheet: service.sheetName,
    sku: service.skuColumn,
    barcode: service.barcodeColumn,
  );
}

class ImportPage extends StatefulWidget {
  final AppState state;
  const ImportPage(this.state, {super.key});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  List<ImportLine> lines = [];
  String name = '';
  String metadata = '';
  ImportReport? report;
  bool working = false;
  Future<void> choose() async {
    setState(() {
      working = true;
      lines = [];
      name = '';
      metadata = '';
      report = null;
    });
    await guarded(context, () async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'csv'],
        withData: true,
      );
      if (result == null) return;
      final f = result.files.single;
      final bytes = f.bytes ?? await File(f.path!).readAsBytes();
      if (mounted) {
        setState(() {
          name = f.name;
          metadata = '${bytes.length} bytes • Se verifică fișierul';
        });
      }
      final ({
        List<ImportLine> lines,
        String sheet,
        String? sku,
        String? barcode,
      })
      decoded;
      try {
        decoded = await compute(_decode, (bytes, f.name));
      } finally {
        await clearPickerCache();
      }
      if (mounted) {
        setState(() {
          lines = decoded.lines;
          metadata =
              'Foaie: ${decoded.sheet}\nColoană barcode: ${decoded.barcode ?? '—'} • Coloană SKU: ${decoded.sku ?? '—'}';
          name = f.name;
          report = null;
        });
      }
    });
    if (mounted) setState(() => working = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Importă produse / SKU')),
    body: ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Previzualizare import • Primele 50 de rânduri. Identificatorii text își păstrează zerourile; numerele întregi Excel sunt acceptate fără notație științifică.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: working ? null : choose,
                icon: const Icon(Icons.file_open),
                label: const Text('SELECTEAZĂ XLSX / CSV'),
              ),
              if (name.isNotEmpty) Text('$name • ${lines.length} rânduri'),
              if (name.isNotEmpty) Text(metadata),
              if (lines.isNotEmpty && report == null)
                TextButton(
                  onPressed: working
                      ? null
                      : () => setState(() {
                          lines = [];
                          name = '';
                        }),
                  child: const Text('ANULEAZĂ'),
                ),
              if (lines.isNotEmpty && report == null)
                FilledButton.tonal(
                  onPressed: working || widget.state.busy
                      ? null
                      : () async {
                          setState(() => working = true);
                          await guarded(context, () async {
                            final result = await widget.state.exclusive(
                              () => widget.state.database.importIdentifiers(
                                lines,
                                name,
                              ),
                            );
                            if (mounted) setState(() => report = result);
                          });
                          if (mounted) setState(() => working = false);
                        },
                  child: const Text('CONFIRMĂ IMPORTUL'),
                ),
              if (report != null) ...[
                Text(
                  'Import finalizat\nRânduri citite: ${report!.rowsRead}\nValide: ${report!.rowsValid}\nAsociate după SKU: ${report!.rowsMatched}\nDeja asociate: ${report!.rowsAlreadyMatched}\nNeasociate: ${report!.rowsPending}\nConflicte: ${report!.rowsConflict}\nInvalide: ${report!.rowsInvalid}\nErori: ${report!.rowsErrors}',
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PendingPage(widget.state),
                    ),
                  ),
                  child: const Text('VEZI NEASOCIATE'),
                ),
                if (report!.errors.isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => TextReport(
                          'Erori import',
                          report!.errors.join('\n'),
                        ),
                      ),
                    ),
                    child: const Text('VEZI ERORI / CONFLICTE'),
                  ),
              ],
            ],
          ),
        ),
        if (working) const LinearProgressIndicator(),
        for (final l in lines.take(50))
          ListTile(
            title: Text(
              '${l.row}. ${l.data['name'] ?? 'Asociere SKU și cod de bare'}',
            ),
            subtitle: Text(
              l.error ??
                  'SKU: ${l.data['sku'] ?? '—'} • Cod: ${l.data['barcode'] ?? '—'}',
            ),
            leading: Icon(
              l.error == null
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              color: l.error == null ? null : Colors.red,
            ),
          ),
      ],
    ),
  );
}

class TextReport extends StatelessWidget {
  final String title, text;
  const TextReport(this.title, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(text),
    ),
  );
}

class BackupPage extends StatefulWidget {
  final AppState state;
  const BackupPage(this.state, {super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool includeImages = false, working = false;
  Future<void> action(bool restore) async {
    setState(() => working = true);
    await guarded(
      context,
      () => widget.state.exclusive(() async {
        final service = BackupService(
          widget.state.database,
          widget.state.images,
          Directory('${widget.state.directory.path}/temporary'),
        );
        if (restore) {
          final picked = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['zip'],
            withData: false,
          );
          if (picked == null || !mounted) return;
          if (picked.files.single.size > 48 * 1024 * 1024) {
            throw const FormatException(
              'Backupul depășește limita de 48 MB pentru restaurare pe telefon. Folosește o copie fără imagini.',
            );
          }
          final yes = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Restaurează backup-ul?'),
              content: Text(
                '${picked.files.single.name}\nDatele curente vor fi înlocuite după validare. Creează întâi un backup dacă dorești să le păstrezi.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Anulează'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Restaurează'),
                ),
              ],
            ),
          );
          if (yes != true) return;
          final f = picked.files.single;
          await service.restore(f.bytes ?? await File(f.path!).readAsBytes());
          if (mounted) message(context, 'Restaurare finalizată.');
        } else {
          final bytes = await service.create(includeImages: includeImages);
          await saveBytes(
            'Cauta-Pret-backup-${DateTime.now().millisecondsSinceEpoch}.zip',
            bytes,
          );
        }
      }),
    );
    await clearPickerCache();
    if (mounted) setState(() => working = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Backup și restaurare')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Pachet versionat: SQLite, categorii, produse, coduri, promoții, asocieri, setări și istoric. Salvează-l într-o locație accesibilă și după dezinstalare.',
        ),
        CheckboxListTile(
          value: includeImages,
          onChanged: working ? null : (v) => setState(() => includeImages = v!),
          title: const Text('Include imaginile'),
        ),
        FilledButton.icon(
          onPressed: working || widget.state.busy ? null : () => action(false),
          icon: const Icon(Icons.save_outlined),
          label: const Text('CREEAZĂ BACKUP'),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: working || widget.state.busy ? null : () => action(true),
          icon: const Icon(Icons.restore),
          label: const Text('RESTAUREAZĂ BACKUP'),
        ),
        if (working) const LinearProgressIndicator(),
      ],
    ),
  );
}

Future<void> history(
  BuildContext context,
  AppState state, {
  bool imports = false,
}) async {
  await guarded(context, () async {
    final rows = await state.database.db.query(
      imports ? 'ImportHistory' : 'SyncHistory',
      orderBy: 'id DESC',
      limit: 40,
    );
    final text = rows
        .map((r) {
          if (imports) {
            return '${stamp(r['importedAt'])} • ${r['fileName']}\nCitite: ${r['rowsRead']} • Noi: ${r['rowsAdded']} • Actualizate: ${r['rowsUpdated']} • Erori: ${r['rowsFailed']}\n${(jsonDecode(r['errors'] as String? ?? '[]') as List).join('\n')}';
          }
          final status =
              const {
                'running': 'În curs',
                'complete': 'Finalizată',
                'partial': 'Încheiată cu erori',
                'interrupted': 'Întreruptă',
                'cancelled': 'Anulată',
              }[r['status']] ??
              r['status'];
          return '${stamp(r['startedAt'])} • Actualizare ${syncName(r['syncType'])}\n$status • Sfârșit: ${stamp(r['finishedAt'])}\nVerificate: ${r['productsChecked']} • Noi: ${r['productsAdded']} • Modificate: ${r['productsUpdated']}\nNeschimbate: ${r['unchanged']} • Imagini: ${r['images']} • Erori: ${r['errors']}\n${(jsonDecode(r['log'] as String? ?? '[]') as List).join('\n')}';
        })
        .join('\n\n');
    if (context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => TextReport(
            imports ? 'Istoric importuri' : 'Istoric actualizări',
            text.isEmpty ? 'Nicio operație înregistrată.' : text,
          ),
        ),
      );
    }
  });
}
