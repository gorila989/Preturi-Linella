import 'dart:io';
import 'dart:convert';
import 'package:cauta_pret/ui/product_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:cauta_pret/app_state.dart';
import 'package:cauta_pret/data/catalog_repository.dart';
import 'package:cauta_pret/domain/models.dart';
import 'package:cauta_pret/main.dart';
import 'package:cauta_pret/services/category_parser.dart';
import 'package:cauta_pret/ui/widgets.dart';

void main() {
  tz.initializeTimeZones();
  sqfliteFfiInit();
  testWidgets(
    'Home starts in Romanian and category tree expands to third level',
    (tester) async {
      late AppState state;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ui_cauta');
        final db = await CatalogRepository.open(
          '${dir.path}/db',
          factory: databaseFactoryFfi,
        );
        state = AppState(db, dir);
        state.categories = CategoryParser().parse(
          'Papetărie și cărți\n• Cărți\no Detectiv',
        );
      });
      await tester.pumpWidget(CautaPret(state));
      await tester.pump();
      expect(find.text('CAUTĂ PREȚ'), findsOneWidget);
      await tester.tap(find.text('Categorii').last);
      await tester.pumpAndSettle();
      expect(find.text('Papetărie și cărți'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      expect(find.text('Cărți'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      expect(find.text('Detectiv'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.remove).first);
      await tester.pumpAndSettle();
      expect(find.text('Detectiv'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await state.database.db.close();
        await dir.delete(recursive: true);
      });
    },
  );
  testWidgets('Expired countdown clamps to zero and offers verification', (
    tester,
  ) async {
    final p = Promotion(
      'a',
      'Mega',
      DateTime.utc(2020),
      DateTime.utc(2020, 2),
      '',
      DateTime.utc(2020),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Countdown(p, verify: () {})),
      ),
    );
    expect(find.text('00'), findsNWidgets(4));
    expect(find.text('VERIFICĂ NOUA OFERTĂ'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Offline scan opens exact SKU product details', (tester) async {
    late AppState state;
    late Directory dir;
    late Product scanned;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('strict_sku_ui_');
      final db = await CatalogRepository.open(
        '${dir.path}/db',
        factory: databaseFactoryFfi,
      );
      final entry =
          (jsonDecode(
                    await File(
                      'test/fixtures/sku-verified-products.json',
                    ).readAsString(),
                  )
                  as List)
              .first;
      final p = entry['verified'][0];
      await db.db.transaction(
        (t) => db.upsert(t, {
          'id': 'linella:${p['sourceProductId']}',
          'sourceProductId': p['sourceProductId'],
          'sku': entry['sku'],
          'name': p['name'],
          'price': double.parse(p['price']),
        }, online: true),
      );
      await db.importIdentifiers([
        ImportLine(2, {'sku': entry['sku'], 'barcode': entry['barcode']}),
      ], 'pair.xlsx');
      scanned = (await db.barcode(entry['barcode']))!;
      state = AppState(db, dir);
    });
    await tester.pumpWidget(MaterialApp(home: ProductPage(state, scanned.id)));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Apa minerala 1.25l BORJOMI'), findsOneWidget);
    expect(
      find.text('SKU: 279905\nCod de bare: 4860019002077'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.runAsync(() async {
      await state.database.db.close();
      await dir.delete(recursive: true);
    });
  });
}
