import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/services/transfer_service.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late CatalogRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sku_additive_');
    repo = await CatalogRepository.open(
      '${dir.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await repo.db.close();
    await dir.delete(recursive: true);
  });
  Future<String> product(Map<String, Object?> values) =>
      repo.db.transaction((t) => repo.upsert(t, values, online: true));
  final original = <String, Object?>{
    'id': 'existing:burn',
    'sourceProductId': '30334',
    'name': 'Burn',
    'price': 21.99,
    'oldPrice': 23.99,
    'promotionState': 'observed',
    'productUrl': 'https://linella.md/burn/',
    'imageUrl': 'https://linella.md/image.jpg',
  };
  test(
    'Real Excel pending row joins SKU received later without new product',
    () async {
      final lines = TransferService().decode(
        await File('test/fixtures/unaretail.xlsx').readAsBytes(),
        'unaretail.xlsx',
      );
      await repo.importProducts(lines, 'unaretail.xlsx');
      final pending = (await repo.db.query(
        'PendingProductIdentifier',
        where: "status='pending'",
        limit: 1,
      )).single;
      await product({...original, 'sku': pending['sku']});
      expect(
        (await repo.barcode(pending['barcode'] as String))?.id,
        'existing:burn',
      );
      expect((await repo.db.query('Product')).length, 1);
      final again = await repo.importProducts(lines, 'unaretail.xlsx');
      expect(again.rowsAdded, 0);
      expect((await repo.db.query('Product')).length, 1);
    },
  );
  for (final excelFirst in [true, false]) {
    test(
      'Excel and SKU match existing scanner product, excelFirst=$excelFirst',
      () async {
        await product(original);
        const rows = [
          ImportLine(2, {'sku': '003579', 'barcode': '0001234567890'}),
        ];
        if (excelFirst) await repo.importProducts(rows, 'sample.xlsx');
        await product({...original, 'sku': '003579'});
        if (!excelFirst) await repo.importProducts(rows, 'sample.xlsx');
        final found = await repo.barcode('0001234567890');
        expect(found?.id, 'existing:burn');
        final saved = (await repo.db.query('Product')).single;
        for (final entry in original.entries) {
          expect(saved[entry.key], entry.value);
        }
        expect(saved['sku'], '003579');
        expect(
          (await repo.db.query('PendingProductIdentifier')).single['status'],
          'matched',
        );
        await product({...original, 'sku': '003579', 'barcode': null});
        expect((await repo.barcode('0001234567890'))?.id, 'existing:burn');
      },
    );
  }
  test('Conflicting pending rows never attach a barcode', () async {
    await repo.importProducts(const [
      ImportLine(2, {'sku': '3579', 'barcode': '0001'}),
      ImportLine(3, {'sku': '3579', 'barcode': '0002'}),
    ], 'ambiguous.xlsx');
    await product({...original, 'sku': '3579'});
    expect((await repo.db.query('Product')).single['barcode'], isNull);
    expect(await repo.barcode('0001'), isNull);
  });
  test(
    'Online identifiers cannot overwrite existing identity or valid codes',
    () async {
      await product({...original, 'sku': '3579', 'barcode': '0001'});
      for (final change in [
        {'sku': 'different'},
        {'barcode': '0002'},
        {'sourceProductId': '999'},
      ]) {
        expect(await product({...original, ...change}), 'conflict');
      }
      final saved = (await repo.db.query('Product')).single;
      expect(saved['sku'], '3579');
      expect(saved['barcode'], '0001');
      expect(saved['sourceProductId'], '30334');
      expect(await repo.barcode('0002'), isNull);
      await product({
        ...original,
        'sourceProductId': null,
        'sku': null,
        'barcode': null,
        'price': 22.0,
      });
      final preserved = (await repo.db.query('Product')).single;
      expect(preserved['sourceProductId'], '30334');
      expect(preserved['sku'], '3579');
      expect(preserved['barcode'], '0001');
    },
  );
}
