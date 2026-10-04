import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/services/api_sync_service.dart';
import 'package:cauta_pret/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late CatalogRepository db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cauta_api_');
    db = await CatalogRepository.open(
      '${dir.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    await ApiSyncService.save(db.db, 'apiUrl', 'https://catalog.example');
  });
  tearDown(() async {
    await db.db.close();
    await dir.delete(recursive: true);
  });
  Map<String, dynamic> product(
    String id,
    num price, {
    String? state,
    String? end,
    String? category,
  }) => {
    'kind': 'product',
    'id': 'linella:$id',
    'data': {
      'sourceProductId': id,
      'name': 'Coca Cola $id',
      'price': price,
      'oldPrice': 25,
      'discountPercent': 20,
      'promoPrice': price,
      'barcode': '00$id',
      'productUrl': 'https://linella.md/p/$id/',
      'promotionState': state ?? 'observed',
      'promotionStart': '2020-01-01T00:00:00Z',
      'promotionEnd': end,
      'categoryId': category,
      'version': 1,
    },
  };
  String page(
    List<Map<String, dynamic>> changes, {
    String? next,
    int version = 1,
  }) => jsonEncode({
    'generation': 'test',
    'serverVersion': version,
    'nextCursor': next,
    'changes': changes,
  });
  ApiSyncService service(
    Future<http.Response> Function(http.Request) handler,
  ) => ApiSyncService(
    db,
    Directory('${dir.path}/images'),
    client: MockClient(handler),
  );
  test(
    'API SKU update joins earlier Excel barcode and scanner preserves product',
    () async {
      await db.db.transaction(
        (t) => db.upsert(t, {
          'id': 'linella:30334',
          'sourceProductId': '30334',
          'name': 'Burn',
          'price': 10.0,
        }, online: true),
      );
      await db.importProducts(const [
        ImportLine(2, {'sku': '003579', 'barcode': '0009876543210'}),
      ], 'sample.xlsx');
      final change = product('30334', 12);
      (change['data'] as Map<String, dynamic>).addAll({
        'sku': '003579',
        'barcode': null,
      });
      final report = await service(
        (r) async => http.Response(
          page([change]),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ).run(SyncMode.full, () {});
      expect(report.errors, 0, reason: report.log.join('\n'));
      expect((await db.barcode('0009876543210'))?.id, 'linella:30334');
      expect((await db.db.query('Product')).length, 1);
      expect((await db.db.query('Product')).single['price'], 12);
    },
  );

  test(
    'Real HTML -> PostgreSQL -> FastAPI -> SQLite keeps all observed discounts offline',
    () async {
      final source =
          jsonDecode(
                await File('test/fixtures/api_bootstrap.json').readAsString(),
              )
              as Map<String, dynamic>;
      final thumbnail = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jp1sAAAAASUVORK5CYII=',
      );
      var apiRequests = 0, imageRequests = 0;
      final report = await service((r) async {
        if (r.url.host == 'catalog.example') {
          apiRequests++;
          return http.Response(
            jsonEncode(source),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        imageRequests++;
        expect(r.url.path, contains('/225/225/'));
        return http.Response.bytes(thumbnail, 200);
      }).run(SyncMode.full, () {});
      expect(report.errors, 0, reason: report.log.join('\n'));
      expect(apiRequests, 1);
      expect(
        await db.count(
          const ProductFilter(categoryId: '/bauturi/', promotions: true),
        ),
        2,
      );
      expect(imageRequests, 24);
      expect(await db.count(const ProductFilter()), 24);
      expect(await db.count(const ProductFilter(promotions: true)), 2);
      final imageFiles = await Directory('${dir.path}/images').list().toList();
      expect(imageFiles.length, 24);
      await db.db.close();
      db = await CatalogRepository.open(
        '${dir.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      expect(
        (await db.products(const ProductFilter(query: 'RED BULL'))).isNotEmpty,
        true,
      );
      expect((await db.byId('linella:30374'))!.price, 28.19);
      var secondImages = 0;
      await service((r) async {
        if (r.url.host != 'catalog.example') {
          secondImages++;
          throw StateError('No repeated thumbnail downloads');
        }
        expect(r.url.path, '/api/v1/sync');
        return http.Response(
          page([], version: source['serverVersion'] as int),
          200,
        );
      }).run(SyncMode.quick, () {});
      expect(secondImages, 0);
      expect(
        (await Directory('${dir.path}/images').list().toList()).length,
        24,
      );
    },
  );

  test(
    'Failed second page retains data but not final version; replay is safe',
    () async {
      var n = 0;
      final first = await service((r) async {
        n++;
        return n == 1
            ? http.Response(page([product('1', 20)], next: 'next'), 200)
            : http.Response('unavailable', 503);
      }).run(SyncMode.quick, () {});
      expect(first.errors, 1);
      expect(await db.count(const ProductFilter()), 1);
      expect(await db.db.query('Settings', where: "key='apiVersion'"), isEmpty);
      n = 0;
      await service((r) async {
        n++;
        return http.Response(
          n == 1
              ? page([product('1', 20)], next: 'next')
              : page([product('2', 30)]),
          200,
        );
      }).run(SyncMode.quick, () {});
      expect(await db.count(const ProductFilter()), 2);
      expect(
        (await db.db.query(
          'Settings',
          where: "key='apiVersion'",
        )).single['value'],
        '1',
      );
    },
  );

  test(
    'Cancel interrupts a hung request without waiting for network timeout',
    () async {
      final started = Completer<void>();
      final hung = Completer<http.Response>();
      final s = service((r) {
        started.complete();
        return hung.future;
      });
      final pending = s.run(SyncMode.quick, () {});
      await started.future;
      s.cancel();
      final report = await pending.timeout(const Duration(seconds: 2));
      expect(report.cancelled, true);
      hung.complete(http.Response('{}', 200));
      expect(await db.db.query('Settings', where: "key='apiVersion'"), isEmpty);
    },
  );

  test(
    'Known expired promotion excluded, unknown date included in descendants',
    () async {
      final changes = <Map<String, dynamic>>[
        {
          'kind': 'category',
          'id': '/a/',
          'data': {'name': 'A', 'parentId': null, 'level': 0, 'sortOrder': 0},
        },
        {
          'kind': 'category',
          'id': '/a/b/',
          'data': {'name': 'B', 'parentId': '/a/', 'level': 1, 'sortOrder': 1},
        },
        product('1', 20, category: '/a/b/'),
        product(
          '2',
          20,
          state: 'dated',
          end: '2021-01-01T00:00:00Z',
          category: '/a/b/',
        ),
      ];
      await service(
        (r) async => http.Response(page(changes), 200),
      ).run(SyncMode.full, () {});
      expect(await db.count(const ProductFilter(categoryId: '/a/')), 2);
      expect(
        await db.count(
          const ProductFilter(categoryId: '/a/', promotions: true),
        ),
        1,
      );
      expect((await db.byId('linella:1'))!.active, true);
      expect((await db.byId('linella:2'))!.active, false);
      expect((await db.barcode('001'))!.id, 'linella:1');
    },
  );

  test('A20 B30 -> A18 Cnew delta preserves B and imported codes', () async {
    await service(
      (r) async =>
          http.Response(page([product('1', 20), product('2', 30)]), 200),
    ).run(SyncMode.full, () {});
    await db.db.update('Product', {'sku': '00099'}, where: "id='linella:1'");
    await service((r) async {
      expect(r.url.queryParameters['since'], '1');
      return http.Response(
        page([product('1', 18), product('3', 5)], version: 2),
        200,
      );
    }).run(SyncMode.quick, () {});
    expect((await db.byId('linella:1'))!.price, 18);
    expect((await db.byId('linella:1'))!.text('sku'), '00099');
    expect((await db.byId('linella:2'))!.price, 30);
    expect(await db.count(const ProductFilter()), 3);
  });

  test(
    'Full snapshot marks absent server rows inactive but preserves local imports',
    () async {
      await service(
        (r) async =>
            http.Response(page([product('1', 20), product('2', 30)]), 200),
      ).run(SyncMode.full, () {});
      await db.db.transaction((t) async {
        await db.upsert(t, {'id': 'local-only', 'name': 'Import local'});
      });
      await service(
        (r) async => http.Response(page([product('1', 18)], version: 2), 200),
      ).run(SyncMode.full, () {});
      expect((await db.byId('linella:2'))!.data['isInactive'], 1);
      expect((await db.byId('linella:1'))!.data['isInactive'], 0);
      expect((await db.byId('local-only'))!.data['isInactive'], 0);
    },
  );

  test(
    'Oversized thumbnail is refused before saving; catalog stays offline',
    () async {
      final p = product('1', 20);
      (p['data'] as Map)['thumbnailUrl'] =
          'https://linella.md/images/thumbnails/225/225/test.jpg';
      final result = await service(
        (r) async => r.url.host == 'catalog.example'
            ? http.Response(page([p]), 200)
            : http.Response.bytes(List.filled(100 * 1024, 1), 200),
      ).run(SyncMode.full, () {});
      expect(result.errors, 1);
      expect((await db.byId('linella:1'))!.price, 20);
      expect(await Directory('${dir.path}/images').list().isEmpty, true);
    },
  );
}
