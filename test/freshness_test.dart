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
import 'package:cauta_pret/ui/source_status.dart';

void main() {
  sqfliteFfiInit();
  test(
    'Unknown, failed and locally aging source metadata never look fresh',
    () {
      final now = DateTime.utc(2026, 10, 30);
      expect(freshnessWarning({}, now), contains('nu confirmă'));
      final data = {
        'status': 'fresh',
        'lastSuccessfulCheckAt': '2026-10-29T12:00:00Z',
      };
      expect(freshnessWarning(data, now), isEmpty);
      expect(
        freshnessWarning(data, now.add(const Duration(days: 2))),
        contains('veche'),
      );
      expect(
        freshnessWarning({...data, 'status': 'error'}, now),
        contains('eșuat'),
      );
    },
  );
  test(
    'Expired discount duplicated in base price falls back to saved normal price',
    () {
      final data = {
        'id': 'avocado',
        'price': 47.99,
        'promotionalPrice': 47.99,
        'oldPrice': 54.99,
        'promotionState': 'dated',
      };
      expect(Product({...data, 'activePromotion': 0}).price, 54.99);
      expect(Product({...data, 'activePromotion': 1}).price, 47.99);
      expect(
        Product({...data, 'activePromotion': 0, 'oldPrice': null}).price,
        isNull,
      );
      expect(
        Product({...data, 'activePromotion': 0, 'price': 59.99}).price,
        59.99,
      );
    },
  );
  test(
    'Successful phone download stores source age; failure preserves it and records warning',
    () async {
      final db = await CatalogRepository.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final directory = Directory.systemTemp.createTempSync('freshness');
      final source = {
        'status': 'stale',
        'lastSuccessfulCheckAt': '2026-10-22T10:00:00Z',
      };
      try {
        final first = ApiSyncService(
          db,
          directory,
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'generation': 'g',
                'serverVersion': 0,
                'nextCursor': null,
                'changes': [],
                'freshness': source,
              }),
              200,
            ),
          ),
        );
        final r = await first.run(SyncMode.full, () {});
        expect(r.errors, 0);
        expect(r.operation, contains('posibil neactualizate'));
        expect(jsonDecode((await first.setting('sourceFreshness'))!), source);
        final saved = await first.setting('apiLastSuccess');
        final second = ApiSyncService(
          db,
          directory,
          client: MockClient((_) async => http.Response('unavailable', 503)),
        );
        final failed = await second.run(SyncMode.quick, () {});
        expect(failed.errors, 1);
        expect(await second.setting('apiLastSuccess'), saved);
        expect(await second.setting('apiLastError'), isNotEmpty);
        expect(jsonDecode((await second.setting('sourceFreshness'))!), source);
      } finally {
        await db.db.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
