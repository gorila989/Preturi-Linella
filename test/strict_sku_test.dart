import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late CatalogRepository db;
  final real =
      (jsonDecode(
                File(
                  'test/fixtures/sku-verified-products.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('exact_sku_');
    db = await CatalogRepository.open(
      '${dir.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await db.db.close();
    await dir.delete(recursive: true);
  });
  Future<void> put(Map<String, Object?> row) async {
    await db.db.transaction((t) => db.upsert(t, row, online: true));
  }

  Map<String, Object?> row(Map<String, dynamic> entry) {
    final p = (entry['verified'] as List).single as Map<String, dynamic>;
    return {
      'id': 'linella:${p['sourceProductId']}',
      'sourceProductId': p['sourceProductId'],
      'sku': entry['sku'],
      'name': p['name'],
      'price': double.parse(p['price'] as String),
      'fullImageUrl': p['image'],
      'productUrl': p['url'],
    };
  }

  test(
    'Full real Excel: three unique pairs match, ambiguous fourth stays conflict; repeat is unchanged',
    () async {
      for (final entry in real) {
        await put(row(entry));
      }
      final lines = TransferService().decode(
        await File('test/fixtures/unaretail.xlsx').readAsBytes(),
        'unaretail.xlsx',
      );
      final first = await db.importIdentifiers(lines, 'unaretail.xlsx');
      expect(first.rowsRead, 1559);
      expect(first.rowsMatched, 3);
      expect(first.rowsConflict, 175);
      expect(first.rowsInvalid, 0);
      expect(first.rowsErrors, 0);
      expect((await db.db.query('Product')).length, 4);
      for (final entry in real) {
        final p = row(entry);
        final found = await db.barcode(entry['barcode'] as String);
        if (entry['sku'] == '2003985') {
          expect(found, isNull);
        } else {
          expect(found?.id, p['id']);
        }
        final saved = (await db.db.query(
          'Product',
          where: 'id=?',
          whereArgs: [p['id']],
        )).single;
        for (final e in p.entries) {
          expect(saved[e.key], e.value);
        }
      }
      final repeated = await db.importIdentifiers(lines, 'unaretail.xlsx');
      expect(repeated.rowsMatched, 0);
      expect(repeated.rowsAlreadyMatched, 3);
      expect(repeated.rowsPending, 1381);
      expect(repeated.rowsConflict, 175);
      expect((await db.db.query('PendingProductIdentifier')).length, 1559);
    },
  );
  for (final entry in real) {
    test(
      'Requested pair ${entry['sku']} in isolation is scannable after offline reopen',
      () async {
        final p = row(entry);
        await put(p);
        final result = await db.importIdentifiers([
          ImportLine(2, {'sku': entry['sku'], 'barcode': entry['barcode']}),
        ], 'pair.xlsx');
        expect(result.rowsMatched, 1);
        await db.db.close();
        db = await CatalogRepository.open(
          '${dir.path}/catalog.db',
          factory: databaseFactoryFfi,
        );
        final scanned = await db.barcode(entry['barcode'] as String);
        expect(scanned?.id, p['id']);
        expect(scanned?.text('sku'), entry['sku']);
        expect(scanned?.price, p['price']);
      },
    );
  }
  test(
    'Unknown SKU with name cannot create product or match sourceProductId',
    () async {
      await put({
        'id': 'existing',
        'sourceProductId': '279905',
        'name': 'Original',
        'price': 10.0,
      });
      final r = await db.import(const [
        ImportLine(2, {
          'sku': '279905',
          'barcode': '4860019002077',
          'name': 'False product',
          'price': 1.0,
        }),
      ], 'input.xlsx');
      expect(r.rowsPending, 1);
      expect(r.rowsMatched, 0);
      expect((await db.db.query('Product')).single['sku'], isNull);
      expect((await db.db.query('Product')).single['name'], 'Original');
    },
  );
  test(
    'Barcode alone cannot infer SKU; valid barcode cannot be replaced',
    () async {
      await put({
        'id': 'one',
        'sourceProductId': '1',
        'name': 'One',
        'sku': 'A',
        'barcode': '001',
      });
      final r = await db.import(const [
        ImportLine(2, {'sku': 'B', 'barcode': '001'}),
        ImportLine(3, {'sku': 'A', 'barcode': '002'}),
      ], 'conflicts.xlsx');
      expect(r.rowsConflict, 2);
      expect(r.rowsMatched, 0);
      expect((await db.db.query('Product')).single['sku'], 'A');
      expect((await db.barcode('001'))?.id, 'one');
      expect(await db.barcode('002'), isNull);
    },
  );
  test('Duplicate SKU legacy rows refuse auto-match', () async {
    // Only this disposable test database emulates a legacy duplicate catalog.
    await db.db.execute('DROP INDEX idx_sku');
    await db.db.insert('Product', {'id': 'one', 'sku': 'A'});
    await db.db.insert('Product', {'id': 'two', 'sku': 'A'});
    final r = await db.import(const [
      ImportLine(2, {'sku': 'A', 'barcode': '001'}),
    ], 'duplicate.xlsx');
    expect(r.rowsConflict, 1);
    expect(await db.barcode('001'), isNull);
  });
  test(
    'Reconcile all pending rows even when latest API has no changed products',
    () async {
      await db.importIdentifiers(const [
        ImportLine(2, {'sku': 'A', 'barcode': '0001'}),
      ], 'early.xlsx');
      await db.db.insert('Product', {
        'id': 'existing',
        'sourceProductId': '1',
        'sku': 'A',
        'name': 'A',
      });
      await db.reconcilePendingIdentifiers();
      expect((await db.barcode('0001'))?.id, 'existing');
    },
  );
  test(
    'Invalid rows and repeated pending rows have truthful counters',
    () async {
      final rows = const [
        ImportLine(2, {'sku': 'A', 'barcode': '0001'}),
        ImportLine(3, {'barcode': '0002'}),
        ImportLine(4, {}, 'bad'),
      ];
      for (var i = 0; i < 2; i++) {
        final r = await db.import(rows, 'mixed.xlsx');
        expect(r.rowsRead, 3);
        expect(r.rowsValid, 1);
        expect(r.rowsInvalid, 2);
        expect(r.rowsPending, 1);
        expect(r.rowsAlreadyMatched, 0);
        expect(r.rowsErrors, 0);
      }
      expect((await db.db.query('Product')), isEmpty);
    },
  );
  test(
    'Legacy local SKU row is preserved but not claimed as Linella match',
    () async {
      await db.db.insert('Product', {
        'id': 'local:old',
        'sku': '279905',
        'name': 'Old local row',
      });
      final result = await db.import(const [
        ImportLine(2, {'sku': '279905', 'barcode': '4860019002077'}),
      ], 'pair.xlsx');
      expect(result.rowsMatched, 0);
      expect(result.rowsPending, 1);
      expect((await db.db.query('Product')).single['barcode'], isNull);
      await db.reconcilePendingIdentifiers();
      expect(await db.barcode('4860019002077'), isNull);
      await put({
        'id': 'linella:29770',
        'sourceProductId': '29770',
        'sku': '279905',
        'name': 'Apa minerala 1.25l BORJOMI',
      });
      expect((await db.barcode('4860019002077'))?.id, 'local:old');
      expect((await db.db.query('Product')).single['sourceProductId'], '29770');
    },
  );
}
