import 'dart:io';
import 'package:cauta_pret/ui/product_pages.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:cauta_pret/main.dart';
import 'package:cauta_pret/app_state.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/services/category_parser.dart';
import 'package:cauta_pret/services/transfer_service.dart';
import 'package:cauta_pret/services/backup_service.dart';
import 'package:cauta_pret/services/api_sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cauta_pret/services/sync_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  testWidgets(
    'Android SQLite startup, offline import search backup and hierarchy',
    (tester) async {
      final root = await getApplicationSupportDirectory();
      final dir = Directory(
        '${root.path}/integration-${DateTime.now().millisecondsSinceEpoch}',
      );
      await dir.create(recursive: true);
      final db = await CatalogRepository.open('${dir.path}/catalog.db');
      await db.seed(
        CategoryParser().parse(
          await rootBundle.loadString('assets/Categorii Linela(2).txt'),
        ),
      );
      final state = AppState(db, dir);
      await state.refresh();
      await tester.pumpWidget(CautaPret(state));
      await tester.pumpAndSettle();
      expect(find.text('CAUTĂ PREȚ'), findsOneWidget);
      final rows = TransferService().decode(
        Uint8List.fromList(
          utf8.encode(
            'SKU;Barcode;Denumire\n00001;0012345678905;Produs test automat',
          ),
        ),
        'test.csv',
      );
      final report = await db.importProducts(rows, 'test.csv');
      expect(report.rowsAdded, 1);
      expect((await db.barcode('0012345678905'))?.text('sku'), '00001');
      final backup = BackupService(
        db,
        state.images,
        Directory('${dir.path}/temporary'),
      );
      final data = await backup.create();
      await backup.restore(data);
      expect(await db.count(const ProductFilter(query: 'test automat')), 1);
      await tester.tap(find.text('Categorii').last);
      await tester.pumpAndSettle();
      expect(find.text('Culinărie'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      expect(find.text('Deserturi'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Leave the home screen visible for a native screenshot; sample rows exist only
      // in this isolated integration-test database, never in the shipping assets.
      await tester.tap(find.text('Acasă').last);
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'Android native SQLite applies API delta, promotions and offline lookup',
    (tester) async {
      final root = await getApplicationSupportDirectory();
      final dir = Directory(
        '${root.path}/hybrid-test-${DateTime.now().microsecondsSinceEpoch}',
      );
      await dir.create(recursive: true);
      final db = await CatalogRepository.open('${dir.path}/catalog.db');
      await ApiSyncService.save(db.db, 'apiUrl', 'https://catalog.example');
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'generation': 'android-test',
            'serverVersion': 1,
            'nextCursor': null,
            'changes': [
              {
                'kind': 'category',
                'id': '/drinks/',
                'data': {
                  'name': 'Băuturi',
                  'parentId': null,
                  'level': 0,
                  'sortOrder': 0,
                },
              },
              {
                'kind': 'category',
                'id': '/drinks/cola/',
                'data': {
                  'name': 'Cola',
                  'parentId': '/drinks/',
                  'level': 1,
                  'sortOrder': 1,
                },
              },
              {
                'kind': 'product',
                'id': 'linella:1',
                'data': {
                  'sourceProductId': '1',
                  'name': 'Coca Cola 1,25 l',
                  'sku': '00001',
                  'barcode': '0012345678905',
                  'price': 18,
                  'oldPrice': 25,
                  'promoPrice': 18,
                  'discountPercent': 28,
                  'promotionState': 'observed',
                  'productUrl': 'https://linella.md/drinks/cola/test/',
                  'categoryId': '/drinks/cola/',
                  'version': 1,
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      final result = await ApiSyncService(
        db,
        Directory('${dir.path}/images'),
        client: client,
      ).run(SyncMode.full, () {});
      expect(result.errors, 0, reason: result.log.join('\n'));
      expect(
        await db.count(
          const ProductFilter(promotions: true, categoryId: '/drinks/'),
        ),
        1,
      );
      await db.db.close();
      final offline = await CatalogRepository.open('${dir.path}/catalog.db');
      expect((await offline.barcode('0012345678905'))!.price, 18);
      expect(await offline.count(const ProductFilter(query: 'ola')), 1);
      final state = AppState(offline, dir);
      await state.refresh();
      await tester.pumpWidget(CautaPret(state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Promoții').last);
      await tester.pumpAndSettle();
      expect(find.text('Coca Cola 1,25 l'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await offline.db.close();
    },
  );

  testWidgets('Android exact SKU Excel join and offline scanner details', (
    tester,
  ) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(
      '${root.path}/strict_sku_${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    final db = await CatalogRepository.open('${dir.path}/catalog.db');
    const products = [
      ['29770', '279905', '4860019002077', 'Apa minerala 1.25l BORJOMI'],
      [
        '29712',
        '153029',
        '5942219111182',
        'Apa minerala carbo 0.75l st. BORSEC',
      ],
      [
        '47296',
        '442891',
        '4840811002031',
        'Seminte de de floarea soarelui pestrite 90g BANZAI',
      ],
      [
        '51042',
        '2003985',
        '4840267009547',
        'RADACINI VERO DI MOSCATO Vin roze dulce 0.75l',
      ],
    ];
    for (final p in products) {
      await db.db.transaction(
        (t) => db.upsert(t, {
          'id': 'linella:${p[0]}',
          'sourceProductId': p[0],
          'sku': p[1],
          'name': p[3],
          'price': 10.0,
        }, online: true),
      );
    }
    final csv =
        'Cod produs,Cod de bare\n${products.map((p) => '${p[1]},${p[2]}').join('\n')}';
    final lines = TransferService().decode(
      Uint8List.fromList(utf8.encode(csv)),
      'real-pairs.csv',
    );
    final report = await db.import(lines, 'real-pairs.csv');
    expect(report.rowsMatched, 4);
    expect(report.rowsConflict, 0);
    final repeated = await db.import(lines, 'real-pairs.csv');
    expect(repeated.rowsAlreadyMatched, 4);
    expect(repeated.rowsMatched, 0);
    await db.db.close();
    final offline = await CatalogRepository.open('${dir.path}/catalog.db');
    for (final p in products) {
      final found = await offline.barcode(p[2]);
      expect(found!.id, 'linella:${p[0]}');
      expect(found.text('sku'), p[1]);
      expect(found.name, p[3]);
    }
    expect(await offline.count(const ProductFilter()), 4);
    final state = AppState(offline, dir);
    final scanned = (await offline.barcode('4860019002077'))!;
    await tester.pumpWidget(MaterialApp(home: ProductPage(state, scanned.id)));
    await tester.pumpAndSettle();
    expect(find.text('Apa minerala 1.25l BORJOMI'), findsOneWidget);
    expect(
      find.text('SKU: 279905\nCod de bare: 4860019002077'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await offline.db.close();
  });
}
