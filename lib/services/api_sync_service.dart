import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import '../data/catalog_repository.dart';
import 'sync_service.dart' show SyncMode, SyncReport, SyncCancelled;

/// The production phone only requests JSON from the configured API and small
/// thumbnails. The legacy HTML parser is retained solely for regression tests.
class ApiSyncService {
  static const defaultEndpoint = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://cauta-pret-linella.onrender.com',
  );
  final CatalogRepository database;
  final Directory imageDirectory;
  final http.Client client;
  final int concurrency;
  final report = SyncReport();
  final _cancelled = Completer<void>();
  String? _bootstrapMark;
  ApiSyncService(
    this.database,
    this.imageDirectory, {
    http.Client? client,
    this.concurrency = 4,
  }) : client = client ?? http.Client();
  void cancel() {
    report.cancelled = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    client.close();
  }

  void check() {
    if (report.cancelled) throw SyncCancelled();
  }

  Future<T> cancellable<T>(Future<T> future) => Future.any([
    future.timeout(const Duration(seconds: 35)),
    _cancelled.future.then<T>((_) => throw SyncCancelled()),
  ]);
  Future<String?> setting(String key) async =>
      (await database.db.query(
            'Settings',
            where: 'key=?',
            whereArgs: [key],
          )).firstOrNull?['value']
          as String?;
  static Future<void> save(
    DatabaseExecutor db,
    String key,
    String value,
  ) async {
    await db.insert('Settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Uri validateEndpoint(String value) {
    final u = Uri.parse(value.trim());
    if (u.scheme != 'https' ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment) {
      throw const FormatException(
        'Introdu adresa HTTPS publică a backendului.',
      );
    }
    return u.replace(path: u.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  Future<List<int>> bytes(Uri uri, int maxBytes) async {
    check();
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await cancellable(client.send(request));
    if (response.statusCode != 200) {
      throw HttpException('Server HTTP ${response.statusCode}', uri: uri);
    }
    if ((response.contentLength ?? 0) > maxBytes) {
      throw const FormatException('Răspuns prea mare.');
    }
    final data = <int>[];
    await cancellable(() async {
      await for (final chunk in response.stream) {
        check();
        if (data.length + chunk.length > maxBytes) {
          throw const FormatException('Răspuns prea mare.');
        }
        data.addAll(chunk);
      }
    }());
    return data;
  }

  Future<SyncReport> run(
    SyncMode mode,
    void Function() notify, {
    Set<String> selected = const {},
    bool forceImages = false,
  }) async {
    final history = await database.db.insert('SyncHistory', {
      'syncType': mode.name,
      'startedAt': CatalogRepository.now(),
      'status': 'running',
    });
    try {
      final endpoint = validateEndpoint(
        await setting('apiUrl') ?? defaultEndpoint,
      );
      final previous = int.tryParse(await setting('apiVersion') ?? '') ?? 0;
      final generation = await setting('apiGeneration');
      final bootstrap = mode == SyncMode.full || generation == null;
      _bootstrapMark = bootstrap
          ? '${DateTime.now().microsecondsSinceEpoch}'
          : null;
      String? cursor;
      final seen = <String>{};
      int? watermark;
      String? snapshotGeneration;
      do {
        check();
        report.operation =
            'Se descarcă ${bootstrap ? 'catalogul' : 'modificările'} de pe server…';
        notify();
        final uri =
            Uri.parse(
              '$endpoint/api/v1/${bootstrap ? 'catalog/bootstrap' : 'sync'}',
            ).replace(
              queryParameters: {
                'limit': '250',
                if (!bootstrap) 'since': '$previous',
                if (!bootstrap) 'generation': generation,
                'cursor': ?cursor,
              },
            );
        final response =
            jsonDecode(utf8.decode(await bytes(uri, 4 * 1024 * 1024)))
                as Map<String, dynamic>;
        report.pagesDownloaded++;
        final version = response['serverVersion'] as int;
        final gen = response['generation'] as String;
        watermark ??= version;
        snapshotGeneration ??= gen;
        if (version != watermark || gen != snapshotGeneration) {
          throw const FormatException('Snapshot inconsistent.');
        }
        final changes = (response['changes'] as List)
            .cast<Map<String, dynamic>>();
        final next = response['nextCursor'] as String?;
        if (next != null && !seen.add(next)) {
          throw const FormatException('Cursor repetat.');
        }
        await database.db.transaction((t) async {
          for (final change in changes) {
            check();
            await apply(t, change);
          }
          check();
          // This is the only publication point. Interrupted pages are idempotently
          // replayed from the previous completed watermark on the next attempt.
          if (next == null) {
            if (_bootstrapMark != null) {
              await t.rawUpdate(
                'UPDATE Product SET isInactive=1,possibleInactive=1 WHERE serverVersion>0 AND (bootstrapMark IS NULL OR bootstrapMark<>?)',
                [_bootstrapMark],
              );
            }
            await save(t, 'apiVersion', '$version');
            await save(t, 'apiGeneration', gen);
            await save(t, 'apiLastSuccess', CatalogRepository.now());
          }
        });
        cursor = next;
        notify();
      } while (cursor != null);
      await database.reconcilePendingIdentifiers(check: check);
      await thumbnails(notify, forceImages);
      report.operation = 'Catalog actualizat. Datele sunt disponibile offline.';
    } catch (e) {
      if (report.cancelled || e is SyncCancelled) {
        report.cancelled = true;
        report.operation =
            'Actualizare anulată. Paginile salvate rămân disponibile.';
      } else {
        report.errors++;
        report.operation =
            'Nu s-a putut verifica actualizarea. Se folosesc datele salvate pe telefon.';
        report.log.add(e.toString());
        if (e is HttpException && e.message.contains('409')) {
          report.operation += ' Pornește ACTUALIZARE TOTALĂ.';
        }
        if (e is FormatException) report.operation = e.message.toString();
      }
    } finally {
      client.close();
      await database.db.update(
        'SyncHistory',
        {
          ...report.row(),
          'finishedAt': CatalogRepository.now(),
          'status': report.cancelled
              ? 'cancelled'
              : report.errors > 0
              ? 'partial'
              : 'complete',
        },
        where: 'id=?',
        whereArgs: [history],
      );
      notify();
    }
    return report;
  }

  Future<String> localProduct(DatabaseExecutor db, String serverId) async {
    final rows = await db.query(
      'Product',
      columns: ['id'],
      where: 'id=? OR sourceProductId=?',
      whereArgs: [
        serverId,
        serverId.startsWith('linella:') ? serverId.substring(8) : serverId,
      ],
    );
    if (rows.isEmpty) {
      throw FormatException('Produs lipsă în snapshot: $serverId');
    }
    return rows.first['id'] as String;
  }

  Future<void> apply(DatabaseExecutor t, Map<String, dynamic> change) async {
    final d = Map<String, Object?>.from(change['data'] as Map);
    final id = change['id'] as String;
    switch (change['kind']) {
      case 'category':
        final row = <String, Object?>{
          'id': id,
          'parentId': d['parentId'],
          'name': d['name'],
          'level': d['level'],
          'sortOrder': d['sortOrder'],
          'sourceUrl': d['sourceUrl'],
          'lastUpdated': CatalogRepository.now(),
        };
        if (await t.update(
              'CategoryNode',
              row,
              where: 'id=?',
              whereArgs: [id],
            ) ==
            0) {
          await t.insert('CategoryNode', row);
        }
      case 'product':
        final row = <String, Object?>{
          'id': id,
          'sourceProductId': d['sourceProductId'],
          'sku': d['sku'],
          'barcode': d['barcode'],
          'name': d['name'],
          'brand': d['brand'],
          'quantity': d['quantity'],
          'price': d['price'],
          'oldPrice': d['oldPrice'],
          'promotionalPrice': d['promoPrice'],
          'discountPercent': d['discountPercent'],
          'categoryNodeId': d['categoryId'],
          'productUrl': d['productUrl'],
          'imageUrl': d['thumbnailUrl'],
          'fullImageUrl': d['fullImageUrl'],
          'promotionState': d['promotionState'],
          'promotionStart': d['promotionStart'],
          'promotionEnd': d['promotionEnd'],
          'inStock': d['inStock'] == null
              ? null
              : d['inStock'] == true
              ? 1
              : 0,
          'isInactive': d['inactive'] == true ? 1 : 0,
          'possibleInactive': d['possiblyInactive'] == true ? 1 : 0,
          'serverVersion': d['version'],
          if (_bootstrapMark != null) 'bootstrapMark': _bootstrapMark,
        };
        final result = await database.upsert(t, row, online: true);
        if (result == 'conflict') {
          throw FormatException(
            'Identificatori contradictorii pentru $id. Verifică importurile locale.',
          );
        }
        report.checked++;
        if (result == 'added') {
          report.added++;
        } else if (result == 'updated') {
          report.updated++;
        } else {
          report.unchanged++;
        }
      case 'promotion':
        final row = <String, Object?>{
          'id': id,
          'name': d['name'],
          'type': d['type'],
          'startDateTime': d['startDateTime'],
          'endDateTime': d['endDateTime'],
          'sourceUrl': d['sourceUrl'],
          'lastUpdated': CatalogRepository.now(),
        };
        if (await t.update('Promotion', row, where: 'id=?', whereArgs: [id]) ==
            0) {
          await t.insert('Promotion', row);
        }
        await t.delete(
          'ProductPromotion',
          where: 'promotionId=?',
          whereArgs: [id],
        );
        for (final p in (d['productIds'] as List? ?? [])) {
          await t.insert('ProductPromotion', {
            'productId': await localProduct(t, p as String),
            'promotionId': id,
          });
        }
      case 'collection':
        final row = <String, Object?>{
          'id': id,
          'name': d['name'],
          'type': d['type'],
          'startDateTime': d['startDateTime'],
          'endDateTime': d['endDateTime'],
          'lastUpdated': CatalogRepository.now(),
        };
        if (await t.update(
              'SpecialCollection',
              row,
              where: 'id=?',
              whereArgs: [id],
            ) ==
            0) {
          await t.insert('SpecialCollection', row);
        }
        await t.delete(
          'SpecialCollectionProduct',
          where: 'collectionId=?',
          whereArgs: [id],
        );
        for (final p in (d['productIds'] as List? ?? [])) {
          await t.insert('SpecialCollectionProduct', {
            'productId': await localProduct(t, p as String),
            'collectionId': id,
          });
        }
      case 'identifier':
        // Keep the central import's full audit, and merge unmatched pairs into the
        // existing local review screen without ever using a name-based match.
        await t.insert('ApiIdentifier', {
          'id': id,
          'data': jsonEncode(d),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        final found = await t.query(
          'PendingProductIdentifier',
          where: 'sku IS ? AND barcode IS ?',
          whereArgs: [d['sku'], d['barcode']],
        );
        final row = <String, Object?>{
          'sku': d['sku'],
          'barcode': d['barcode'],
          'sourceFile': d['sourceFile'],
          'sheetName': d['sheetName'],
          'rowNumber': d['rowNumber'],
          'importedAt': CatalogRepository.now(),
          'status': d['status'],
          'errorMessage': d['errorMessage'],
          'matchedProductId': d['matchedProductId'] == null
              ? null
              : await localProduct(t, d['matchedProductId'] as String),
        };
        if (found.isEmpty) {
          await t.insert('PendingProductIdentifier', row);
        } else if (d['status'] == 'matched' &&
            found.first['status'] != 'matched') {
          await t.update(
            'PendingProductIdentifier',
            row,
            where: 'id=?',
            whereArgs: [found.first['id']],
          );
        }
      default:
        throw FormatException(
          'Tip de schimbare incompatibil: ${change['kind']}',
        );
    }
  }

  Future<void> thumbnails(void Function() notify, bool force) async {
    await imageDirectory.create(recursive: true);
    const quota = 512 * 1024 * 1024, maxFile = 96 * 1024;
    var used = 0;
    await for (final f in imageDirectory.list()) {
      if (f is File) used += await f.length();
    }
    String after = '';
    while (true) {
      check();
      final rows = await database.db.query(
        'Product',
        where: 'id>? AND imageUrl IS NOT NULL AND serverVersion>0',
        whereArgs: [after],
        orderBy: 'id',
        limit: 100,
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        check();
        final url = row['imageUrl'] as String;
        final uri = Uri.parse(url);
        final dimensions = RegExp(
          r'/thumbnails/(\d+)/(\d+)/',
        ).firstMatch(uri.path);
        if (uri.scheme != 'https' ||
            uri.host != 'linella.md' ||
            dimensions == null ||
            int.parse(dimensions[1]!) > 225 ||
            int.parse(dimensions[2]!) > 225) {
          continue;
        }
        final name = '${sha256.convert(utf8.encode(url))}.img';
        final file = File('${imageDirectory.path}/$name');
        if (!force && row['localImageUrl'] == url && await file.exists()) {
          continue;
        }
        if (used + maxFile > quota) {
          if (!report.log.contains('Limita miniaturilor: 512 MiB.')) {
            report.log.add('Limita miniaturilor: 512 MiB.');
          }
          return;
        }
        try {
          if (!await file.exists() || force) {
            report.operation =
                'Se salvează miniaturi pentru utilizare offline…';
            notify();
            final data = await bytes(uri, maxFile);
            final buffer = await ui.ImmutableBuffer.fromUint8List(
              /* bounded to 96 KiB */
              Uint8List.fromList(data),
            );
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            final valid = descriptor.width <= 225 && descriptor.height <= 225;
            descriptor.dispose();
            buffer.dispose();
            if (!valid) {
              throw const FormatException('Imaginea depășește 225px.');
            }
            final oldSize = await file.exists() ? await file.length() : 0;
            final staged = File('${file.path}.part');
            await staged.writeAsBytes(data, flush: true);
            await staged.rename(file.path);
            used += data.length - oldSize;
            report.images++;
          }
          await database.db.update(
            'Product',
            {'localImagePath': name, 'localImageUrl': url},
            where: 'id=?',
            whereArgs: [row['id']],
          );
        } catch (e) {
          check();
          report.errors++;
          if (report.log.length < 200) report.log.add('Miniatură: $e');
        }
      }
      after = rows.last['id'] as String;
    }
    // Remove only managed files no longer referenced, never an active thumbnail.
    final paths = (await database.db.query(
      'Product',
      columns: ['localImagePath'],
      where: 'localImagePath IS NOT NULL',
    )).map((r) => r['localImagePath']).toSet();
    await for (final f in imageDirectory.list()) {
      final name = f.uri.pathSegments.last;
      if (f is File &&
          RegExp(r'^[a-f0-9]{64}\.img$').hasMatch(name) &&
          !paths.contains(name)) {
        await f.delete();
      }
    }
  }
}
