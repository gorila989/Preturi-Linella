import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauta_pret/ui/online_price.dart';

void main() {
  const link =
      'https://linella.md/ro/catalog/fructe/avocado_500g_peru?from=CATALOGUE';
  test('Only official HTTPS product links can be opened', () {
    expect(linellaProductUri(link).toString(), link);
    for (final bad in [
      null,
      '',
      '285759',
      'http://linella.md/product',
      'https://linella.md.evil.test/product',
      'https://evil.test/product',
      'https://user@linella.md/product',
      'https://linella.md:8080/product',
      'javascript:alert(1)',
      'https://linella.md/',
    ]) {
      expect(linellaProductUri(bad), isNull, reason: '$bad');
    }
  });
  testWidgets('Online page opens only on tap and uses the exact product URL', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnlinePriceButton(
            productUrl: link,
            open: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    expect(opened, isEmpty);
    await tester.tap(find.text('VEZI PREȚUL PE LINELLA'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), link);
    expect(find.textContaining('nu se salvează automat'), findsOneWidget);
  });
  testWidgets('Imported product without URL never launches a guessed page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnlinePriceButton(
            productUrl: null,
            open: (_) async => throw StateError('must not launch'),
          ),
        ),
      ),
    );
    expect(find.byType(FilledButton), findsNothing);
    expect(find.textContaining('nu are o pagină'), findsOneWidget);
  });
  testWidgets('Missing browser gives a visible retryable error', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnlinePriceButton(productUrl: link, open: (_) async => false),
        ),
      ),
    );
    await tester.tap(find.text('VEZI PREȚUL PE LINELLA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('actualizează Chrome'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
}
