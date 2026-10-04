import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:excel/excel.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cauta_pret/data/local_database.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/services/linella_parser.dart';
import 'package:cauta_pret/services/transfer_service.dart';
import 'package:cauta_pret/services/sync_service.dart';
import 'package:cauta_pret/services/storage_service.dart';
import 'package:cauta_pret/services/backup_service.dart';

void main() {
  test(
    'Invalid XLSX has actionable messages and no misleading ZIP exception',
    () {
      final service = TransferService();
      for (final entry in <(List<int>, String)>[
        ([], 'gol'),
        (utf8.encode('<html>Download link</html>'), 'nu este XLSX'),
        ([0xd0, 0xcf, 0x11, 0xe0, 0, 0, 0, 0], 'vechi sau criptat'),
        ([0x50, 0x4b, 3, 4, 0, 0], 'incomplet sau deteriorat'),
        (
          ZipEncoder().encode(
            Archive()..addFile(ArchiveFile('source.txt', 1, [1])),
          )!,
          'nu este un registru XLSX',
        ),
      ]) {
        expect(
          () => service.decode(Uint8List.fromList(entry.$1), 'selected.xlsx'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(entry.$2),
            ),
          ),
        );
      }
    },
  );
  test('CSV mixed line endings and textual SKU suffixes', () {
    final lines = TransferService().decode(
      Uint8List.fromList(
        utf8.encode('SKU,Barcode\nABC.0,00123\n279905.0,00456\r\n'),
      ),
      'mixed.csv',
    );
    expect(lines.length, 2);
    expect(lines.first.data['sku'], 'ABC.0');
    expect(lines.last.data['sku'], '279905');
    expect(lines.last.data['barcode'], '00456');
  });
  sqfliteFfiInit();
  final fixture = File('test/fixtures/energizante.html').readAsStringSync();
  final xlsx = File('test/fixtures/unaretail.xlsx').readAsBytesSync();
  late Directory dir;
  late CatalogRepository db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cauta_upgrade_');
    db = await CatalogRepository.open(
      '${dir.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    if (db.db.isOpen) await db.db.close();
    await dir.delete(recursive: true);
  });

  test(
    'Picker cache measurement and cleanup preserve original backups and active images',
    () async {
      final cache = Directory('${dir.path}/picker/123');
      await cache.create(recursive: true);
      await File('${cache.path}/copy.xlsx').writeAsBytes([1, 2, 3]);
      final backups = Directory('${dir.path}/backups');
      await backups.create();
      await File('${backups.path}/user.zip').writeAsBytes([4, 5]);
      final images = Directory('${dir.path}/images');
      await images.create();
      final name = '${sha256.convert([6])}.img';
      await File('${images.path}/$name').writeAsBytes([6]);
      await db.upsert(db.db, {'id': 'keep', 'localImagePath': name});
      final storage = StorageService(db, dir, pickerCache: cache.parent);
      expect((await storage.measure())['cache'], 3);
      await storage.cleanCache();
      await storage.cleanUnusedImages();
      expect((await storage.measure())['cache'], 0);
      expect(await File('${backups.path}/user.zip').readAsBytes(), [4, 5]);
      expect(await File('${images.path}/$name').readAsBytes(), [6]);
    },
  );

  test('Pagination fallbacks and loop guard retain products', () async {
    final parser = LinellaParser();
    const url = 'https://linella.md/bauturi/energizante/';
    expect(
      parser.nextPage(
        '<button data-ut2-load-more-url="page-2/"></button>',
        url,
      ),
      '${url}page-2/',
    );
    expect(
      parser.nextPage('<a data-ca-page="2" href="page-2/">2</a>', url),
      '${url}page-2/',
    );
    expect(
      parser.nextPage(
        '<a class="ty-pagination__next disabled" href="page-2/">Next</a>',
        url,
      ),
      isNull,
    );
    final cards = html
        .parse(fixture)
        .querySelectorAll('.ut2-gl__item')
        .take(2)
        .toList();
    final service = SyncService(
      db,
      Directory('${dir.path}/images'),
      client: MockClient((r) async {
        final second = r.url.path.contains('page-2');
        return http.Response(
          '<link rel="next" href="${second ? url : '${url}page-2/'}">${cards[second ? 1 : 0].outerHtml}',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );
    await expectLater(service.scope(url, () {}), throwsFormatException);
    expect(service.report.pagesDownloaded, 2);
    expect(await db.count(const ProductFilter()), 2);
    service.client.close();
  });

  test(
    'Invalid input rows retained individually and repeated invalid import is idempotent',
    () async {
      final lines = [
        const ImportLine(2, {}, 'Invalid first'),
        const ImportLine(3, {}, 'Invalid second'),
        const ImportLine(4, {'sku': 'S', 'barcode': '001'}, 'Invalid price'),
      ];
      await db.importProducts(lines, 'bad.csv');
      await db.importProducts(lines, 'bad.csv');
      expect((await db.pending()).length, 3);
      await db.importProducts([
        const ImportLine(2, {'sku': 'S', 'barcode': '001'}),
      ], 'good.csv');
      expect((await db.pending()).length, 4);
    },
  );

  test(
    'User HTML exact ID, price, stock, images, promotion and head pagination',
    () {
      final parser = LinellaParser();
      final products = parser.products(fixture);
      final p = products.singleWhere((p) => p.id == 'linella:30374');
      expect(p.text('sourceProductId'), '30374');
      expect(p.text('sku'), isNull);
      expect(p.name, 'Bautura energizanta Pepene Rosu 0.25l RED BULL');
      expect(p.price, 28.19);
      expect(p.data['inStock'], 1);
      expect(
        p.text('productUrl'),
        startsWith('https://linella.md/bauturi/energizante/'),
      );
      expect(p.text('imageUrl'), contains('/450/450/'));
      expect(p.number('discountPercent'), isNull);
      final reduced = products
          .where((p) => p.number('oldPrice') != null)
          .toList();
      expect(reduced, isNotEmpty);
      expect(
        reduced.any(
          (p) =>
              p.number('oldPrice') == 12.99 &&
              p.number('discountPercent') == 46,
        ),
        isTrue,
      );
      expect(
        parser.nextPage(fixture, 'https://linella.md/bauturi/energizante/'),
        'https://linella.md/bauturi/energizante/page-2/',
      );
      File('validation/1.1/fixture.json').writeAsStringSync(
        jsonEncode({
          'products': products.length,
          'discounted': reduced.length,
          'redBull': p.data,
        }),
      );
    },
  );

  test(
    'All real UNARETAIL rows preserved, repeat idempotent, no source-ID guess',
    () async {
      final reader = TransferService();
      final lines = reader.decode(xlsx, 'unaretail.xlsx');
      expect(reader.sheetName, 'Date');
      expect(reader.barcodeColumn, 'Cod de bare');
      expect(reader.skuColumn, 'Cod produs');
      expect(lines.length, 1559);
      expect(lines.where((l) => l.error != null), isEmpty);
      final pairs = [
        ('4860019002077', '279905'),
        ('5942219111182', '153029'),
        ('4840811002031', '442891'),
        ('4840267009547', '2003985'),
      ];
      for (var i = 0; i < pairs.length; i++) {
        expect(lines[i].data['barcode'], pairs[i].$1);
        expect(lines[i].data['sku'], pairs[i].$2);
      }
      await db.upsert(db.db, {
        'id': 'linella:279905',
        'sourceProductId': '279905',
        'name': 'Nu este un SKU',
      });
      final first = await db.importProducts(lines, 'unaretail.xlsx');
      final before = await db.db.query('PendingProductIdentifier');
      expect(before.length, 1559);
      expect((await db.byId('linella:279905'))!.text('sku'), isNull);
      expect(await db.count(const ProductFilter()), 1);
      for (final line in lines) {
        expect(
          before.any(
            (r) =>
                r['barcode'] == line.data['barcode'] &&
                r['sku'] == line.data['sku'],
          ),
          isTrue,
        );
      }
      final second = await db.importProducts(lines, 'unaretail.xlsx');
      expect(
        (await db.db.query('PendingProductIdentifier')).length,
        before.length,
      );
      expect(second.rowsAdded, 0);
      final pending = (await db.pending(query: '4860019002077')).single;
      expect(pending['sku'], '279905');
      await db.matchPending(pending['id'] as int, 'linella:279905');
      expect((await db.barcode('4860019002077'))!.text('sku'), '279905');
      await db.upsert(db.db, {
        'id': 'linella:279905',
        'sourceProductId': '279905',
        'name': 'Nume actualizat',
        'sku': null,
        'barcode': null,
      }, online: true);
      expect((await db.barcode('4860019002077'))!.text('sku'), '279905');
      File('validation/1.1/import.json').writeAsStringSync(
        jsonEncode({
          'rows': lines.length,
          'first': {
            'new': first.rowsAdded,
            'pending': first.rowsPending,
            'conflicts': first.rowsConflict,
            'errors': first.rowsFailed,
          },
          'second': {
            'new': second.rowsAdded,
            'duplicates': second.rowsDuplicate,
            'conflicts': second.rowsConflict,
          },
          'storedPairs': before.length,
        }),
      );
    },
  );

  test(
    'Numeric Excel values and zero masks preserve exact identifier text',
    () {
      final book = Excel.createExcel();
      final sheet = book['Sheet1'];
      sheet.appendRow([
        TextCellValue('  COD   DE BARE '),
        TextCellValue('Product Code'),
      ]);
      sheet.appendRow([IntCellValue(4860019002077), DoubleCellValue(279905.0)]);
      sheet.appendRow([
        TextCellValue('0012345678901'),
        TextCellValue('000012'),
      ]);
      sheet.appendRow([IntCellValue(123), IntCellValue(4)]);
      sheet.cell(CellIndex.indexByString('A4')).cellStyle = CellStyle(
        numberFormat: CustomNumericNumFormat(formatCode: '0000000000000'),
      );
      sheet.appendRow([DoubleCellValue(12.5), IntCellValue(1)]);
      sheet.appendRow([IntCellValue(1234567890123456), IntCellValue(2)]);
      final lines = TransferService().decode(
        Uint8List.fromList(book.encode()!),
        'numbers.xlsx',
      );
      expect(lines[0].data['barcode'], '4860019002077');
      expect(lines[0].data['sku'], '279905');
      expect(lines[1].data['barcode'], '0012345678901');
      expect(lines[1].data['sku'], '000012');
      expect(lines[2].data['barcode'], '0000000000123');
      expect(lines[3].error, isNotNull);
      expect(lines[4].error, isNotNull);
    },
  );

  test(
    'Conflicts preserved for review, safe exact matching and duplicates',
    () async {
      await db.upsert(db.db, {
        'id': 'a',
        'name': 'A',
        'sku': 'S',
        'barcode': '001',
      });
      final duplicate = await db.importProducts([
        const ImportLine(2, {'sku': 'S', 'barcode': '001'}),
      ], 'duplicate.csv');
      expect(duplicate.rowsDuplicate, 1);
      final report = await db.importProducts([
        const ImportLine(3, {'sku': 'S', 'barcode': '002'}),
        const ImportLine(4, {'sku': 'T', 'barcode': '001'}),
      ], 'conflicts.csv');
      expect(report.rowsConflict, 2);
      expect((await db.byId('a'))!.text('barcode'), '001');
      expect(await db.barcode('002'), isNull);
      expect((await db.pending()).length, 2);
    },
  );

  test(
    'Version 1 migration preserves every original column and all relationships; old backup restores',
    () async {
      final oldPath = '${dir.path}/version1.db';
      final old = await databaseFactoryFfi.openDatabase(
        oldPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, v) async {
            for (final sql in LocalDatabase.schema) {
              await d.execute(sql);
            }
          },
        ),
      );
      await old.insert(
        'CategoryNode',
        const CategoryNode('root', null, 'Băuturi', 0, 0).toRow(),
      );
      await old.insert(
        'CategoryNode',
        const CategoryNode('leaf', 'root', 'Energizante', 1, 1).toRow(),
      );
      final imageName = '${sha256.convert([1, 2, 3])}.img';
      await Directory('${dir.path}/images').create();
      await File('${dir.path}/images/$imageName').writeAsBytes([1, 2, 3]);
      await old.insert('Product', {
        'id': 'linella:30374',
        'sku': '001',
        'barcode': '0012345678901',
        'name': 'Vechi',
        'price': 28.19,
        'categoryNodeId': 'leaf',
        'localImagePath': imageName,
        'imageUrl': 'https://linella.md/img.png',
      });
      await old.insert('ProductBarcode', {
        'productId': 'linella:30374',
        'barcode': '0012345678901',
      });
      await old.insert('Promotion', {
        'id': 'promo',
        'name': 'Promo',
        'type': 'mega',
      });
      await old.insert('ProductPromotion', {
        'productId': 'linella:30374',
        'promotionId': 'promo',
        'promotionalPrice': 20,
      });
      await old.insert('ImportHistory', {
        'fileName': 'old.xlsx',
        'rowsRead': 1,
      });
      await old.insert('SyncHistory', {
        'syncType': 'full',
        'status': 'complete',
      });
      final before = <String, List<DbRow>>{
        for (final table in BackupService.tables.where(
          (t) => !['PendingProductIdentifier', 'ApiIdentifier'].contains(t),
        ))
          table: await old.query(table),
      };
      await old.close();
      final oldBytes = await File(oldPath).readAsBytes();
      final migrated = await CatalogRepository.open(
        oldPath,
        factory: databaseFactoryFfi,
      );
      for (final entry in before.entries) {
        final after = await migrated.db.query(entry.key);
        expect(after.length, entry.value.length);
        for (var i = 0; i < after.length; i++) {
          for (final field in entry.value[i].entries) {
            expect(
              after[i][field.key],
              field.value,
              reason: '${entry.key}.${field.key}',
            );
          }
        }
      }
      expect(
        (await migrated.db.query('Product')).single['sourceProductId'],
        '30374',
      );
      expect(await File('${dir.path}/images/$imageName').readAsBytes(), [
        1,
        2,
        3,
      ]);
      final counts = {
        'categories': 2,
        'products': 1,
        'sku': 1,
        'barcode': 1,
        'images': 1,
        'promotions': 1,
      };
      File('validation/1.1/migration.json').writeAsStringSync(
        jsonEncode({
          'schemaBefore': 1,
          'schemaAfter': await migrated.db.getVersion(),
          'before': counts,
          'after': counts,
          'allOriginalColumnsEqual': true,
        }),
      );
      await migrated.db.close();
      final manifest = utf8.encode(
        jsonEncode({
          'format': 'cauta-pret',
          'version': 1,
          'schema': 1,
          'sha256': {'catalog.db': sha256.convert(oldBytes).toString()},
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('catalog.db', oldBytes.length, oldBytes))
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
      await BackupService(
        db,
        Directory('${dir.path}/images'),
        Directory('${dir.path}/temporary'),
        factory: databaseFactoryFfi,
      ).restore(Uint8List.fromList(ZipEncoder().encode(archive)!));
      expect((await db.db.query('Product')).single['sku'], '001');
      expect(await db.db.getVersion(), LocalDatabase.schemaVersion);
    },
  );

  test(
    'Real cards paginate, repeat sync preserves storage and IDs; offline reopen',
    () async {
      final cards = html
          .parse(fixture)
          .querySelectorAll('.ut2-gl__item')
          .take(3)
          .toList();
      expect(cards.length, 3);
      final images = Directory('${dir.path}/images');
      const root = 'https://linella.md/bauturi/energizante/';
      await db.seed([
        const CategoryNode('root', null, 'Băuturi', 0, 0, root),
        const CategoryNode('child', 'root', 'Energizante', 1, 1, root),
      ]);
      Future<SyncReport> sync() async {
        final s = SyncService(
          db,
          images,
          client: MockClient((request) async {
            if (request.url.path.contains('/images/')) {
              return http.Response.bytes(
                [1, 2, 3],
                200,
                headers: {'content-type': 'image/png'},
              );
            }
            final page = int.tryParse(
              RegExp(r'page-(\d+)').firstMatch(request.url.path)?[1] ?? '1',
            )!;
            expect(
              request.url.toString(),
              page == 1 ? root : '${root}page-$page/',
            );
            final next = page < 3
                ? '<link rel="next" href="${root}page-${page + 1}/">'
                : '';
            return http.Response(
              '$next${cards[page - 1].outerHtml}',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }),
        );
        await s.scope(root, () {}, categoryId: 'child');
        await s.images(() {});
        s.client.close();
        return s.report;
      }

      final first = await sync();
      expect(first.checked, 3);
      expect(first.pagesDownloaded, 3);
      expect(first.detailRequests, 0);
      final all = await db.products(const ProductFilter());
      await db.upsert(db.db, {
        'id': all.first.id,
        'sku': '0007',
        'barcode': '0012345678901',
      });
      final storage = StorageService(db, dir);
      await storage.cleanCache();
      final before = await storage.measure();
      final second = await sync();
      await storage.cleanCache();
      final after = await storage.measure();
      expect(second.added, 0);
      expect(second.updated, 0);
      expect(second.unchanged, 3);
      expect(second.images, 0);
      expect(after['imageCount'], before['imageCount']);
      expect(after['images'], before['images']);
      expect(after['database']! - before['database']!, lessThanOrEqualTo(4096));
      expect(await db.count(const ProductFilter(categoryId: 'root')), 3);
      final orphan = '${sha256.convert([4])}.img';
      await File('${images.path}/$orphan').writeAsBytes([4]);
      await File('${images.path}/keep-user-file.txt').writeAsString('keep');
      expect(await storage.cleanUnusedImages(), 1);
      expect(await File('${images.path}/keep-user-file.txt').exists(), isTrue);
      final id = all.first.id;
      await db.db.close();
      db = await CatalogRepository.open(
        '${dir.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      expect((await db.barcode('0012345678901'))!.id, id);
      expect(await db.count(const ProductFilter(query: '0007')), 1);
      for (final p in await db.products(const ProductFilter())) {
        expect(
          await File('${images.path}/${p.text('localImagePath')}').exists(),
          isTrue,
        );
        expect(p.price, isNotNull);
      }
      File('validation/1.1/repeated-sync.json').writeAsStringSync(
        jsonEncode({
          'productsBefore': 3,
          'productsAfter': 3,
          'before': before,
          'after': after,
          'pagesPerRun': 3,
          'detailRequests': 0,
          'secondUnchanged': second.unchanged,
          'secondImages': second.images,
          'offlineLookup': true,
        }),
      );
    },
  );

  test(
    'Changed image failure keeps old image, successful replacement allows safe cleanup',
    () async {
      final images = Directory('${dir.path}/images');
      await images.create();
      final old = '${sha256.convert([1])}.img';
      await File('${images.path}/$old').writeAsBytes([1]);
      await db.upsert(db.db, {
        'id': 'p',
        'imageUrl': 'https://linella.md/old.png',
        'localImagePath': old,
      });
      await db.upsert(db.db, {
        'id': 'p',
        'imageUrl': 'https://linella.md/new.png',
      }, online: true);
      final failed = SyncService(
        db,
        images,
        client: MockClient((_) async => http.Response('', 404)),
      )..imageIds.add('p');
      await failed.images(() {});
      expect(failed.report.errors, 1);
      expect((await db.byId('p'))!.text('localImagePath'), old);
      expect(await StorageService(db, dir).cleanUnusedImages(), 0);
      final ok = SyncService(
        db,
        images,
        client: MockClient(
          (_) async => http.Response.bytes(
            [2],
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      )..imageIds.add('p');
      await ok.images(() {});
      expect(ok.report.images, 1);
      expect(await StorageService(db, dir).cleanUnusedImages(), 1);
    },
  );
}
