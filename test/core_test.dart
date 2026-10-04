import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:excel/excel.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/services/category_parser.dart';
import 'package:cauta_pret/services/linella_parser.dart';
import 'package:cauta_pret/services/transfer_service.dart';
import 'package:cauta_pret/services/backup_service.dart';
import 'package:cauta_pret/services/sync_service.dart';

void main() {
  tz.initializeTimeZones();
  sqfliteFfiInit();
  late Directory dir;
  late CatalogRepository db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cauta_test_');
    db = await CatalogRepository.open(
      '${dir.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await db.db.close();
    await dir.delete(recursive: true);
  });
  Future<void> add(DbRow row) => db.db.transaction((t) async {
    await db.upsert(t, row);
  });
  final tree = CategoryParser().parse(
    'Papetărie și cărți\n• Cărți\no Detectiv\nBăuturi\n• Apă',
  );
  test(
    'Original TXT preserves exact hierarchy, duplicates and special sections',
    () async {
      final nodes = CategoryParser().parse(
        await File('assets/Categorii Linela(2).txt').readAsString(),
      );
      expect(nodes.where((n) => n.level == 0).length, 31);
      expect(nodes.where((n) => n.level == 2).length, 9);
      expect(nodes.where((n) => n.name == 'Detergenți pentru rufe').length, 2);
      expect(
        nodes.where(
          (n) =>
              n.name == 'Mai multe' ||
              n.name == 'Mega Ofertă' ||
              n.name == 'Cele mai bune oferte',
        ),
        isEmpty,
      );
      expect(nodes.map((n) => n.id).toSet().length, nodes.length);
      await db.seed(nodes);
      expect(
        (await db.categories()).map((n) => n.name),
        nodes.map((n) => n.name),
      );
      await expectLater(db.seed(nodes), throwsFormatException);
    },
  );
  test('Parser rejects orphan third level', () {
    expect(() => CategoryParser().parse('o Detectiv'), throwsFormatException);
  });
  test('CSV aliases and leading zero barcode', () {
    final lines = TransferService().decode(
      Uint8List.fromList(
        utf8.encode('Cod SKU;EAN;Denumire\n0001;0012345678905;Apă'),
      ),
      'a.csv',
    );
    expect(lines.single.data['barcode'], '0012345678905');
    expect(lines.single.data['sku'], '0001');
  });
  test('XLSX text roundtrip and integral numeric identifiers accepted', () {
    final book = Excel.createExcel();
    book['Sheet1'].appendRow([TextCellValue('SKU'), TextCellValue('Barcode')]);
    book['Sheet1'].appendRow([TextCellValue('0001'), TextCellValue('001234')]);
    book['Sheet1'].appendRow([IntCellValue(2), IntCellValue(123)]);
    final rows = TransferService().decode(
      Uint8List.fromList(book.encode()!),
      'x.xlsx',
    );
    expect(rows.first.data['barcode'], '001234');
    expect(rows.last.error, isNull);
    expect(rows.last.data['barcode'], '123');
  });
  test('Invalid CSV rows reported without losing valid rows', () async {
    final lines = TransferService().decode(
      Uint8List.fromList(
        utf8.encode('SKU,Barcode,Preț\na,0002,10\nb,0003,wrong'),
      ),
      'x.csv',
    );
    final report = await db.importProducts(lines, 'x.csv');
    expect(report.rowsAdded, 1);
    expect(report.rowsFailed, 1);
  });
  test(
    'SKU exact, barcode exact and name accent-insensitive partial search',
    () async {
      await add({
        'id': 'a',
        'sku': '0001',
        'barcode': '001234',
        'name': 'Apă minerală',
        'brand': 'Marca',
      });
      for (final q in ['0001', '001234', 'apa', 'iner', 'marca']) {
        expect(await db.count(ProductFilter(query: q)), 1);
      }
      expect((await db.barcode('001234'))?.id, 'a');
      expect(await db.barcode('1234'), isNull);
    },
  );
  test(
    'Conflicting barcode imports need review; explicit aliases remain searchable',
    () async {
      final lines = [
        const ImportLine(2, {'sku': '01', 'barcode': '001', 'name': 'Apă'}),
        const ImportLine(3, {'sku': '01', 'barcode': '002'}),
      ];
      await add({
        'id': 'existing',
        'sku': '01',
        'barcode': '001',
        'name': 'Apă',
      });
      final r = await db.importProducts(lines, 'a.csv');
      expect(r.rowsAdded, 0);
      expect(r.rowsConflict, 2);
      expect(await db.barcode('002'), isNull);
      await db.associate('existing', '002');
      expect((await db.barcode('001'))?.id, (await db.barcode('002'))?.id);
      expect((await db.importProducts(lines, 'a.csv')).rowsAdded, 0);
    },
  );
  test('Conflicting exact identifiers flagged, names never merged', () async {
    await add({'id': 'a', 'sku': 'A', 'barcode': '1', 'name': 'Identic'});
    await add({'id': 'b', 'sku': 'B', 'barcode': '2', 'name': 'Identic'});
    final r = await db.importProducts([
      const ImportLine(2, {'sku': 'A', 'barcode': '2'}),
    ], 'a.csv');
    expect(r.rowsFailed, 1);
    expect(await db.count(const ProductFilter(review: true)), 2);
    expect(await db.count(const ProductFilter()), 2);
  });
  test('Manual association and merge retain aliases', () async {
    await add({'id': 'a', 'sku': '001', 'barcode': '00123'});
    await add({
      'id': 'b',
      'name': 'Produs',
      'productUrl': 'https://linella.md/p/',
    });
    await db.merge('a', 'b');
    expect((await db.barcode('00123'))?.id, 'b');
    expect((await db.byId('b'))?.text('sku'), '001');
    await db.associate('b', '00099');
    expect((await db.barcode('00099'))?.id, 'b');
  });
  test(
    'Online missing identifiers preserve local values and unchanged hash skips write',
    () async {
      await add({
        'id': 'a',
        'sku': '01',
        'barcode': '02',
        'name': 'Apă',
        'sourceHash': 'same',
      });
      final before = (await db.byId('a'))!.text('lastUpdated');
      final result = await db.db.transaction(
        (t) => db.upsert(t, {
          'id': 'a',
          'name': 'Apă',
          'sourceHash': 'same',
        }, online: true),
      );
      expect(result, 'unchanged');
      expect((await db.byId('a'))!.text('lastUpdated'), before);
      await db.db.transaction(
        (t) => db.upsert(t, {
          'id': 'a',
          'name': 'Apă nouă',
          'sku': null,
          'barcode': null,
          'sourceHash': 'new',
        }, online: true),
      );
      expect((await db.byId('a'))!.text('sku'), '01');
    },
  );
  test(
    'Recursive filters include category, subcategory and third level only',
    () async {
      await db.seed(tree);
      await add({'id': 'a', 'name': 'Carte', 'categoryNodeId': tree[2].id});
      await add({'id': 'b', 'name': 'Apă', 'categoryNodeId': tree[4].id});
      for (final i in [0, 1, 2]) {
        expect(await db.count(ProductFilter(categoryId: tree[i].id)), 1);
      }
      expect(await db.count(ProductFilter(categoryId: tree[3].id)), 1);
    },
  );
  test('Active, future, expired and inclusive promotion boundaries', () async {
    await db.seed(tree);
    await add({'id': 'a', 'name': 'Carte', 'categoryNodeId': tree[2].id});
    final start = DateTime.utc(2026, 1, 1), end = DateTime.utc(2026, 1, 2);
    final p = Promotion(
      'x',
      'Mega',
      start,
      end,
      'https://linella.md/mega-oferta/',
      start,
    );
    await db.db.insert('Promotion', p.toRow());
    await db.db.insert('ProductPromotion', {
      'productId': 'a',
      'promotionId': 'x',
      'promotionalPrice': 5,
    });
    for (final t in [start, end]) {
      expect(p.active(t), isTrue);
      expect(
        await db.count(
          ProductFilter(categoryId: tree[0].id, promotions: true),
          at: t,
        ),
        1,
      );
    }
    for (final t in [
      start.subtract(const Duration(seconds: 1)),
      end.add(const Duration(seconds: 1)),
    ]) {
      expect(p.active(t), isFalse);
      expect(await db.count(const ProductFilter(promotions: true), at: t), 0);
    }
    expect(p.remaining(end.add(const Duration(days: 1))), Duration.zero);
  });
  test('Countdown days hours minutes seconds calculated locally', () {
    final start = DateTime.utc(2026),
        p = Promotion(
          'x',
          'Mega',
          start,
          start.add(
            const Duration(days: 7, hours: 4, minutes: 35, seconds: 56),
          ),
          '',
          start,
        );
    final d = p.remaining(start);
    expect(d.inDays, 7);
    expect(d.inHours % 24, 4);
    expect(d.inMinutes % 60, 35);
    expect(d.inSeconds % 60, 56);
  });
  test(
    'Public Linella HTML parser verifies prices hierarchy dates and next page',
    () async {
      final parser = LinellaParser();
      final html = await File('test/fixtures/mega.html').readAsString();
      final products = parser.products(html, promotion: true);
      expect(products, isNotEmpty);
      expect(products.first.name, contains('ACTIVIA'));
      expect(products.first.number('price'), 8.49);
      expect(products.first.text('imageUrl'), contains('/450/450/'));
      expect(products.first.text('barcode'), isNull);
      final promo = parser.promotion(html);
      expect(promo.endDate.toIso8601String(), '2026-10-07T20:59:59.999Z');
      expect(
        parser.nextPage(html, 'https://linella.md/mega-oferta/'),
        isNotNull,
      );
      expect(
        parser
            .categories(
              await File('test/fixtures/categories.html').readAsString(),
            )
            .subcategories
            .any((s) => s.name == 'Cărți › Detectiv'),
        isTrue,
      );
    },
  );
  test('Changed HTML fails safely, no guessed promotion dates', () {
    final parser = LinellaParser();
    expect(() => parser.products('<html>login</html>'), throwsFormatException);
    expect(
      () => parser.promotion('<p>24/09/2026 07/10/2026</p>'),
      throwsFormatException,
    );
    expect(
      () => parser.publicUrl('https://other.example/x'),
      throwsFormatException,
    );
  });
  test('Backup restores SQLite identifiers settings and images', () async {
    await db.seed(tree);
    final images = Directory('${dir.path}/images');
    await images.create();
    final name = '${'a' * 64}.img';
    await File('${images.path}/$name').writeAsBytes([1, 2, 3]);
    await add({
      'id': 'a',
      'sku': '001',
      'barcode': '002',
      'name': 'Carte',
      'categoryNodeId': tree[2].id,
      'localImagePath': name,
    });
    await db.db.insert('Settings', {'key': 'dark', 'value': '1'});
    final backup = BackupService(
      db,
      images,
      Directory('${dir.path}/temp'),
      factory: databaseFactoryFfi,
    );
    final bytes = await backup.create(includeImages: true);
    await add({'id': 'b', 'name': 'Alt produs'});
    await backup.restore(bytes);
    expect(await db.count(const ProductFilter()), 1);
    expect((await db.barcode('002'))?.text('sku'), '001');
    final restored = (await db.byId('a'))!.text('localImagePath')!;
    expect(await File('${images.path}/$restored').readAsBytes(), [1, 2, 3]);
    expect((await db.db.query('Settings')).single['value'], '1');
  });
  test('Invalid restore never damages existing database', () async {
    await add({'id': 'a', 'name': 'Păstrat'});
    final service = BackupService(
      db,
      Directory('${dir.path}/images'),
      Directory('${dir.path}/temp'),
      factory: databaseFactoryFfi,
    );
    await expectLater(
      service.restore(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
    expect((await db.byId('a'))?.name, 'Păstrat');
  });
  test('Backup without images and incompatible version validation', () async {
    await add({'id': 'a', 'name': 'Păstrat'});
    final service = BackupService(
      db,
      Directory('${dir.path}/images'),
      Directory('${dir.path}/temp'),
      factory: databaseFactoryFfi,
    );
    final bytes = await service.create();
    final zip = ZipDecoder().decodeBytes(bytes);
    final manifest =
        jsonDecode(
              utf8.decode(zip.findFile('manifest.json')!.content as List<int>),
            )
            as Map;
    manifest['version'] = 999;
    final data = utf8.encode(jsonEncode(manifest));
    zip.addFile(ArchiveFile('manifest.json', data.length, data));
    await expectLater(
      service.restore(Uint8List.fromList(ZipEncoder().encode(zip)!)),
      throwsFormatException,
    );
    expect(await db.count(const ProductFilter()), 1);
  });
  test('Offline read works after reopening SQLite with no network', () async {
    await add({'id': 'a', 'name': 'Local', 'barcode': '00001'});
    await db.db.close();
    db = await CatalogRepository.open(
      '${dir.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    expect((await db.barcode('00001'))?.name, 'Local');
  });
  test('CSV and XLSX exports round trip text codes', () {
    final products = [
      Product({
        'id': 'x',
        'name': 'Nume, cu virgulă',
        'sku': '0001',
        'barcode': '0002',
        'price': 1.25,
      }),
    ];
    for (final xlsx in [false, true]) {
      final bytes = TransferService().encode(products, {}, {}, xlsx: xlsx);
      final line = TransferService()
          .decode(bytes, xlsx ? 'a.xlsx' : 'a.csv')
          .single;
      expect(line.data['sku'], '0001');
      expect(line.data['barcode'], '0002');
      expect(line.data['price'], 1.25);
    }
  });
  test(
    'Exact source SKU links imported identifiers to online record',
    () async {
      await add({'id': 'import', 'sku': '0007', 'barcode': '001111'});
      await add({
        'id': 'online',
        'name': 'Nume public',
        'productUrl': 'https://linella.md/test/',
      });
      await db.applySourceDetails('online', {'sku': '0007', 'brand': 'Marcă'});
      expect(await db.count(const ProductFilter()), 1);
      expect((await db.barcode('001111'))?.id, 'online');
      expect((await db.byId('online'))?.name, 'Nume public');
    },
  );
  test(
    'Promotional price comes from committed period, not partial product update',
    () async {
      await add({'id': 'a', 'price': 20, 'promotionalPrice': 1});
      final p = Promotion(
        'x',
        'Mega',
        DateTime.utc(2020),
        DateTime.utc(2090),
        '',
        DateTime.now(),
      );
      await db.db.insert('Promotion', p.toRow());
      await db.db.insert('ProductPromotion', {
        'productId': 'a',
        'promotionId': 'x',
        'promotionalPrice': 10,
      });
      expect((await db.byId('a'))?.price, 10);
    },
  );
  test('Restore rolls back on incompatible row schema', () async {
    await add({'id': 'a', 'name': 'Important'});
    final backup = BackupService(
      db,
      Directory('${dir.path}/images'),
      Directory('${dir.path}/tmp'),
      factory: databaseFactoryFfi,
    );
    final bytes = await backup.create();
    final zip = ZipDecoder().decodeBytes(bytes);
    // A valid SQLite file with an incompatible column reaches the write transaction and must roll back.
    final manifest =
        jsonDecode(
              utf8.decode(zip.findFile('manifest.json')!.content as List<int>),
            )
            as Map;
    final altered = File('${dir.path}/altered.db');
    await altered.writeAsBytes(
      zip.findFile('catalog.db')!.content as List<int>,
    );
    final other = await databaseFactoryFfi.openDatabase(altered.path);
    await other.execute('ALTER TABLE Product ADD COLUMN unsupported TEXT');
    await other.close();
    final sqlite = await altered.readAsBytes();
    zip.addFile(ArchiveFile('catalog.db', sqlite.length, sqlite));
    (manifest['sha256'] as Map)['catalog.db'] = sha256
        .convert(sqlite)
        .toString();
    await add({'id': 'b', 'name': 'Added after backup'});
    final data = utf8.encode(jsonEncode(manifest));
    zip.addFile(ArchiveFile('manifest.json', data.length, data));
    await expectLater(
      backup.restore(Uint8List.fromList(ZipEncoder().encode(zip)!)),
      throwsA(anything),
    );
    expect((await db.byId('a'))?.name, 'Important');
    expect((await db.byId('b'))?.name, 'Added after backup');
  });
  test(
    'Lazy images use data-srcset, never a base64 placeholder as a URL',
    () async {
      final products = LinellaParser().products(
        await File('test/fixtures/pizza.html').readAsString(),
      );
      final pizza = products.firstWhere((p) => p.id == 'linella:50732');
      expect(
        pizza.text('imageUrl'),
        'https://linella.md/images/thumbnails/450/450/detailed/60/2728b2f6d4cfcaaba3ed0a76d383235b.jpg',
      );
      expect(pizza.text('imageFallbackUrl'), contains('/225/225/'));
      expect(
        products.every((p) => !(p.text('imageUrl') ?? '').contains('base64')),
        true,
      );
    },
  );
  for (final mode in SyncMode.values) {
    test(
      '${mode.name} sync uses bounded targets, stores data before images, incremental skip',
      () async {
        final nodes = [
          const CategoryNode('a', null, 'A', 0, 0, 'https://linella.md/a/'),
          const CategoryNode('b', null, 'B', 0, 1, 'https://linella.md/b/'),
          const CategoryNode('c', null, 'C', 0, 2, 'https://linella.md/c/'),
        ];
        await db.seed(nodes);
        final requested = <String>[];
        final parser = _FixtureParser();
        final service = SyncService(
          db,
          Directory('${dir.path}/images'),
          parser: parser,
          client: MockClient((r) async {
            requested.add(r.url.toString());
            return http.Response(
              r.url.path,
              200,
              headers: {'content-type': 'text/html'},
            );
          }),
        );
        final result = await service.run(mode, () {}, selected: {'b'});
        expect(result.errors, 0, reason: result.log.join('\n'));
        expect(
          requested.contains('https://linella.md/a/'),
          mode != SyncMode.selected,
        );
        expect(requested.contains('https://linella.md/b/'), isTrue);
        expect(
          requested.contains('https://linella.md/c/'),
          mode == SyncMode.full,
        );
        expect(
          requested.contains('https://linella.md/mega-oferta/'),
          mode != SyncMode.selected,
        );
        expect((await db.products(const ProductFilter())).isNotEmpty, isTrue);
        final again = SyncService(
          db,
          Directory('${dir.path}/images'),
          parser: parser,
          client: MockClient(
            (r) async => http.Response(
              r.url.path,
              200,
              headers: {'content-type': 'text/html'},
            ),
          ),
        );
        final second = await again.run(
          SyncMode.selected,
          () {},
          selected: {'b'},
        );
        expect(second.unchanged, 1);
      },
    );
  }
  test('Cancellation and failed source retain prior rows', () async {
    await add({'id': 'a', 'name': 'Local'});
    final s = SyncService(
      db,
      Directory('${dir.path}/images'),
      client: MockClient((r) async => http.Response('error', 403)),
    );
    s.cancel();
    final report = await s.run(SyncMode.full, () {});
    expect(report.cancelled, isTrue);
    expect(await db.count(const ProductFilter()), 1);
  });
  test('Conditional HTTP request honors ETag and 304 body', () async {
    await db.db.insert('HttpCache', {
      'url': 'https://linella.md/a/',
      'etag': 'v1',
      'body': 'cached',
    });
    final s = SyncService(
      db,
      Directory('${dir.path}/images'),
      client: MockClient((r) async {
        expect(r.headers['If-None-Match'], 'v1');
        return http.Response('', 304);
      }),
    );
    expect(await s.get('https://linella.md/a/'), 'cached');
    s.client.close();
  });
  test('Existing image never fetched again', () async {
    final images = Directory('${dir.path}/images');
    await images.create();
    final name = '${'a' * 64}.img';
    await File('${images.path}/$name').writeAsBytes([1]);
    await add({
      'id': 'a',
      'imageUrl': 'https://linella.md/image.png',
      'localImagePath': name,
    });
    final s = SyncService(
      db,
      images,
      client: MockClient((r) async {
        fail('Network should not be used for cached image');
      }),
    );
    s.imageIds.add('a');
    await s.images(() {});
    expect(s.report.images, 0);
    s.client.close();
  });
}

class _FixtureParser extends LinellaParser {
  @override
  CategoryResult categories(String source) => const CategoryResult([
    Category('/a/', 'A', 'https://linella.md/a/'),
    Category('/b/', 'B', 'https://linella.md/b/'),
    Category('/c/', 'C', 'https://linella.md/c/'),
  ], []);
  @override
  List<Product> products(
    String source, {
    String? categoryId,
    String? subcategoryId,
    bool promotion = false,
  }) => [
    Product({
      'id': source,
      'name': source,
      'price': 2.0,
      'productUrl': 'https://linella.md${source}product/',
      'categoryId': null,
      'subcategoryId': null,
      if (promotion) 'promotionalPrice': 1.0,
    }),
  ];
  @override
  Promotion promotion(String source, {DateTime? now}) => Promotion(
    'mega',
    'Mega',
    DateTime.utc(2026),
    DateTime.utc(2030),
    'https://linella.md/mega-oferta/',
    DateTime.utc(2026),
  );
  @override
  DbRow productDetails(String source) => {};
  @override
  String? nextPage(String source, String current) => null;
}
