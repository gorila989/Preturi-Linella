import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauta_pret/ui/promotions_page.dart';

void main() {
  testWidgets('Promotion lists open their own official URLs only when tapped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: OnlinePromotionsPanel(
              open: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      ),
    );
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('MEGA OFERTĂ — PRODUSE ONLINE'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('PREȚURI MICI ZI DE ZI — ONLINE'));
    await tester.tap(find.text('PREȚURI MICI ZI DE ZI — ONLINE'));
    await tester.pumpAndSettle();
    expect(opened.map((u) => u.toString()), [
      'https://linella.md/mega-oferta/',
      'https://linella.md/preturi-mici-zi-de-zi/',
    ]);
    expect(find.textContaining('nu actualizează automat'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
