import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/models.dart';
import 'local_database.dart';

class CatalogRepository {
  final Database db;
  CatalogRepository(this.db);
  static const schemaVersion = LocalDatabase.schemaVersion;
  static Future<CatalogRepository> open(
    String path, {
    DatabaseFactory? factory,
    bool singleInstance = true,
  }) async => CatalogRepository(
    await LocalDatabase.open(
      path,
      factory: factory,
      singleInstance: singleInstance,
    ),
  );
  static String now() => DateTime.now().toUtc().toIso8601String();
  Future<List<CategoryNode>> categories() async => (await db.query(
    'CategoryNode',
    orderBy: 'sortOrder',
  )).map(CategoryNode.fromRow).toList();
  Future<void> seed(List<CategoryNode> nodes) async {
    await db.transaction((t) async {
      if (Sqflite.firstIntValue(
            await t.rawQuery('SELECT count(*) FROM CategoryNode'),
          )! >
          0) {
        throw const FormatException(
          'Categoriile sunt deja importate. Structura existentă este păstrată.',
        );
      }
      final b = t.batch();
      for (final n in nodes) {
        b.insert('CategoryNode', n.toRow());
      }
      await b.commit(noResult: true);
    });
  }

  Future<Promotion?> mega() async {
    final r = await db.query(
      'Promotion',
      where: "type='mega'",
      orderBy: 'endDateTime DESC',
      limit: 1,
    );
    return r.isEmpty ? null : Promotion.fromRow(r.first);
  }

  static const activeSql =
      '''(CASE WHEN p.promotionState IS NOT NULL THEN (p.isInactive=0 AND (p.promotionState='observed' OR (p.promotionState='dated' AND p.promotionStart<=? AND p.promotionEnd>=?))) ELSE EXISTS(SELECT 1 FROM ProductPromotion pp JOIN Promotion pr ON pr.id=pp.promotionId WHERE pp.productId=p.id AND pr.startDateTime<=? AND pr.endDateTime>=?) END)''';
  (String, List<Object?>) where(ProductFilter f, DateTime time) {
    final w = <String>['1=1'], a = <Object?>[];
    if (f.query.trim().isNotEmpty) {
      final q = folded(f.query),
          escaped = q
              .replaceAll('\\', '\\\\')
              .replaceAll('%', '\\%')
              .replaceAll('_', '\\_');
      final indexed = RegExp(r'^[a-z0-9 ]+$').hasMatch(q);
      w.add(
        indexed
            ? "(p.sku=? OR p.barcode=? OR p.id IN (SELECT productId FROM ProductBarcode WHERE barcode=?) OR p.rowid IN (SELECT rowid FROM ProductSearch WHERE searchText MATCH ?) OR p.searchText LIKE ? ESCAPE '\\')"
            : "(p.sku=? OR p.barcode=? OR p.id IN (SELECT productId FROM ProductBarcode WHERE barcode=?) OR p.searchText LIKE ? ESCAPE '\\')",
      );
      a.addAll([
        f.query.trim(),
        f.query.trim(),
        f.query.trim(),
        if (indexed)
          q.split(' ').where((s) => s.isNotEmpty).map((s) => '$s*').join(' '),
        '%$escaped%',
      ]);
    }
    if (f.categoryId != null) {
      w.add(
        '''p.categoryNodeId IN (WITH RECURSIVE tree(id) AS (SELECT id FROM CategoryNode WHERE id=? OR sourceUrl=(SELECT sourceUrl FROM CategoryNode WHERE id=?) UNION ALL SELECT c.id FROM CategoryNode c JOIN tree t ON c.parentId=t.id) SELECT id FROM tree)''',
      );
      a.add(f.categoryId);
      a.add(f.categoryId);
    }
    if (f.collection != null) {
      w.add(
        'p.id IN (SELECT productId FROM SpecialCollectionProduct WHERE collectionId=?)',
      );
      a.add(f.collection);
    }
    if (f.promotions) {
      w.add(activeSql);
      a.addAll([
        time.toUtc().toIso8601String(),
        time.toUtc().toIso8601String(),
        time.toUtc().toIso8601String(),
        time.toUtc().toIso8601String(),
      ]);
    }
    if (f.review) w.add('p.needsReview=1');
    return (w.join(' AND '), a);
  }

  Future<List<Product>> products(
    ProductFilter f, {
    int offset = 0,
    int limit = 60,
    DateTime? at,
  }) async {
    final time = at ?? DateTime.now(),
        stamp = (at ?? DateTime.now()).toUtc().toIso8601String();
    final (w, a) = where(f, time);
    final rows = await db.rawQuery(
      'SELECT p.*,CASE WHEN $activeSql THEN 1 ELSE 0 END AS activePromotion FROM Product p WHERE $w ORDER BY p.name COLLATE NOCASE,p.id LIMIT ? OFFSET ?',
      [stamp, stamp, stamp, stamp, ...a, limit, offset],
    );
    return _promotionValues(rows, time);
  }

  Future<List<Product>> _promotionValues(
    List<DbRow> rows,
    DateTime time,
  ) async {
    if (rows.isEmpty) return [];
    final ids = rows.map((r) => r['id']).toList();
    final stamp = time.toUtc().toIso8601String();
    final active = await db.rawQuery(
      'SELECT pp.*,pr.lastUpdated FROM ProductPromotion pp JOIN Promotion pr ON pr.id=pp.promotionId WHERE pp.productId IN (${List.filled(ids.length, '?').join(',')}) AND pr.startDateTime<=? AND pr.endDateTime>=? ORDER BY pr.lastUpdated',
      [...ids, stamp, stamp],
    );
    final values = <Object?, DbRow>{for (final r in active) r['productId']: r};
    return rows.map((r) {
      final promotion = values[r['id']];
      return Product({
        ...r,
        'activePromotion': r['promotionState'] != null
            ? r['activePromotion']
            : promotion == null
            ? 0
            : 1,
        if (promotion != null && r['promotionState'] == null) ...{
          'oldPrice': promotion['oldPrice'],
          'promotionalPrice': promotion['promotionalPrice'],
          'discountPercent': promotion['discountPercent'],
        },
      });
    }).toList();
  }

  Future<int> count(ProductFilter f, {DateTime? at}) async {
    final (w, a) = where(f, at ?? DateTime.now());
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT count(*) FROM Product p WHERE $w', a),
        ) ??
        0;
  }

  Future<Product?> barcode(String code) async {
    final r = await db.rawQuery(
      'SELECT p.* FROM Product p WHERE p.barcode=? OR p.id IN (SELECT productId FROM ProductBarcode WHERE barcode=?) LIMIT 2',
      [code, code],
    );
    if (r.isEmpty) return null;
    if (r.length != 1) {
      throw const FormatException(
        'Codul de bare aparține mai multor produse. Verifică asocierile.',
      );
    }
    return byId(r.first['id'] as String);
  }

  Future<Product?> byId(String id) async {
    final stamp = now();
    final r = await db.rawQuery(
      'SELECT p.*,CASE WHEN $activeSql THEN 1 ELSE 0 END AS activePromotion FROM Product p WHERE p.id=?',
      [stamp, stamp, stamp, stamp, id],
    );
    return r.isEmpty
        ? null
        : (await _promotionValues(r, DateTime.parse(stamp))).single;
  }

  Future<String> upsert(
    DatabaseExecutor t,
    DbRow incoming, {
    bool online = false,
  }) async {
    final data = Map<String, Object?>.of(incoming);
    final matches = <String, DbRow>{};
    for (final key in [
      'sourceProductId',
      'sku',
      'barcode',
      'productUrl',
      'id',
    ]) {
      if (data[key] == null) continue;
      for (final r in await t.query(
        'Product',
        where: '$key=?',
        whereArgs: [data[key]],
      )) {
        matches[r['id'] as String] = r;
      }
      if (key == 'barcode') {
        for (final r in await t.rawQuery(
          'SELECT p.* FROM Product p JOIN ProductBarcode b ON b.productId=p.id WHERE b.barcode=?',
          [data[key]],
        )) {
          matches[r['id'] as String] = r;
        }
      }
    }
    if (matches.length > 1) {
      await t.insert('Review', {
        'incoming': jsonEncode(data),
        'reason': 'Identificatori contradictorii',
        'createdAt': now(),
      });
      for (final id in matches.keys) {
        await t.update(
          'Product',
          {'needsReview': 1},
          where: 'id=?',
          whereArgs: [id],
        );
      }
      return 'conflict';
    }
    final old = matches.values.firstOrNull;
    if (old != null &&
        online &&
        ['sourceProductId', 'sku', 'barcode'].any(
          (key) =>
              data[key] != null && old[key] != null && data[key] != old[key],
        )) {
      await t.insert('Review', {
        'incoming': jsonEncode(data),
        'reason': 'Identificatori existenți diferiți; datele sunt păstrate.',
        'createdAt': now(),
      });
      return 'conflict';
    }
    if (old != null &&
        online &&
        data.entries
            .where((e) => !['id', 'sourceHash', 'lastUpdated'].contains(e.key))
            .every(
              (e) =>
                  e.value == old[e.key] ||
                  (e.value == null &&
                      [
                        'sourceProductId',
                        'sku',
                        'barcode',
                        'name',
                        'brand',
                        'quantity',
                        'categoryNodeId',
                        'productUrl',
                      ].contains(e.key)),
            )) {
      await _matchPendingSku(t, old);
      return 'unchanged';
    }
    if (old != null &&
        online &&
        data['sourceHash'] != null &&
        old['sourceHash'] == data['sourceHash']) {
      await _matchPendingSku(t, old);
      return 'unchanged';
    }
    if (old != null) {
      data['id'] = old['id'];
      if (data.containsKey('imageUrl') && data['imageUrl'] != old['imageUrl']) {
        // Keep the valid old file until its replacement has been saved.
        data['localImageUrl'] = old['localImageUrl'] ?? old['imageUrl'];
      }
      for (final k in [
        'sourceProductId',
        'sku',
        'barcode',
        'name',
        'brand',
        'quantity',
        'categoryNodeId',
        'productUrl',
      ]) {
        if (data[k] == null) data.remove(k);
      }
      if (data['barcode'] != null &&
          old['barcode'] != null &&
          old['barcode'] != data['barcode']) {
        await t.insert('ProductBarcode', {
          'barcode': data['barcode'],
          'productId': old['id'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        data['barcode'] = old['barcode'];
      }
    }
    data['id'] ??= 'local:${DateTime.now().microsecondsSinceEpoch}';
    if (old == null && data['name'] == null) data['needsReview'] = 1;
    final merged = {...?old, ...data};
    data['searchText'] = folded(
      '${merged['name'] ?? ''} ${merged['sku'] ?? ''} ${merged['barcode'] ?? ''} ${merged['brand'] ?? ''}',
    );
    data['lastUpdated'] = now();
    if (old == null) {
      await t.insert('Product', data);
    } else {
      await t.update('Product', data, where: 'id=?', whereArgs: [old['id']]);
    }
    if (data['barcode'] != null) {
      await t.insert('ProductBarcode', {
        'barcode': data['barcode'],
        'productId': data['id'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (online) await _matchPendingSku(t, {...merged, 'id': data['id']});
    return old == null ? 'added' : 'updated';
  }

  Future<void> _matchPendingSku(DatabaseExecutor t, DbRow product) async {
    final sku = product['sku'];
    if (sku == null ||
        sku == '' ||
        product['sourceProductId'] == null ||
        product['sourceProductId'] == '') {
      return;
    }
    final rows = await t.query(
      'PendingProductIdentifier',
      where: "sku=? AND status='pending'",
      whereArgs: [sku],
    );
    for (final row in rows) {
      final barcode = row['barcode'];
      if (barcode == null || barcode == '') continue;
      final related = await t.query(
        'PendingProductIdentifier',
        where: "(sku=? OR barcode=?) AND status<>'invalid'",
        whereArgs: [sku, barcode],
      );
      final owners = await t.rawQuery(
        'SELECT DISTINCT p.* FROM Product p LEFT JOIN ProductBarcode b ON b.productId=p.id WHERE p.sku=? OR p.barcode=? OR b.barcode=?',
        [sku, barcode, barcode],
      );
      final conflict =
          related.any(
            (r) =>
                r['sku'] != sku ||
                r['barcode'] != barcode ||
                r['status'] == 'needsReview' ||
                (r['matchedProductId'] != null &&
                    r['matchedProductId'] != product['id']),
          ) ||
          owners.length != 1 ||
          owners.single['id'] != product['id'] ||
          (owners.single['barcode'] != null &&
              owners.single['barcode'] != barcode);
      if (conflict) {
        await t.update(
          'PendingProductIdentifier',
          {
            'status': 'needsReview',
            'errorMessage':
                'Conflict SKU/cod de bare; produsul existent este păstrat.',
          },
          where: 'id=?',
          whereArgs: [row['id']],
        );
        continue;
      }
      final current = owners.single;
      await t.update(
        'Product',
        {
          'barcode': barcode,
          'searchText': folded(
            '${current['name'] ?? ''} $sku $barcode ${current['brand'] ?? ''}',
          ),
        },
        where: 'id=?',
        whereArgs: [product['id']],
      );
      await t.insert('ProductBarcode', {
        'barcode': barcode,
        'productId': product['id'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await t.update(
        'PendingProductIdentifier',
        {
          'status': 'matched',
          'matchedProductId': product['id'],
          'errorMessage': null,
        },
        where: 'id=?',
        whereArgs: [row['id']],
      );
    }
  }

  /// UNARETAIL attaches identifiers only; legacy full product transfer remains available.
  Future<ImportReport> importIdentifiers(
    List<ImportLine> lines,
    String fileName,
  ) => import(lines, fileName, skuOnly: true);

  /// Explicit compatibility entry for full product transfer/export round trips.
  /// The normal Excel import defaults to exact SKU attachment only.
  Future<ImportReport> importProducts(
    List<ImportLine> lines,
    String fileName,
  ) => import(lines, fileName, skuOnly: false);

  Future<ImportReport> import(
    List<ImportLine> lines,
    String fileName, {
    bool skuOnly = true,
  }) async {
    final report = ImportReport();
    final skuCodes = <Object?, Set<Object?>>{},
        barcodeSkus = <Object?, Set<Object?>>{};
    for (final line in lines.where((l) => l.error == null)) {
      final s = line.data['sku'], b = line.data['barcode'];
      if (s != null && b != null) {
        (skuCodes[s] ??= {}).add(b);
        (barcodeSkus[b] ??= {}).add(s);
      }
    }
    for (var start = 0; start < lines.length; start += 200) {
      await db.transaction((t) async {
        for (final line in lines.skip(start).take(200)) {
          report.rowsRead++;
          if (line.error != null) {
            report.rowsInvalid++;
            report.rowsFailed++;
            report.errors.add('Rând ${line.row}: ${line.error}');
            await _saveIdentifier(
              t,
              line,
              fileName,
              'invalid',
              error: line.error,
            );
            continue;
          }
          report.rowsValid++;
          if (skuOnly) {
            final one = ImportReport();
            await t.execute('SAVEPOINT exact_sku_row');
            try {
              await _importExactSku(
                t,
                line,
                fileName,
                one,
                skuCodes,
                barcodeSkus,
              );
              await t.execute('RELEASE exact_sku_row');
              report.rowsValid += one.rowsValid;
              report.rowsInvalid += one.rowsInvalid;
              report.rowsMatched += one.rowsMatched;
              report.rowsAlreadyMatched += one.rowsAlreadyMatched;
              report.rowsDuplicate += one.rowsDuplicate;
              report.rowsPending += one.rowsPending;
              report.rowsConflict += one.rowsConflict;
              report.rowsFailed += one.rowsFailed;
              report.rowsUpdated += one.rowsUpdated;
              report.errors.addAll(one.errors);
            } catch (e) {
              await t.execute('ROLLBACK TO exact_sku_row');
              await t.execute('RELEASE exact_sku_row');
              report.rowsFailed++;
              report.errors.add('Rând ${line.row}: $e');
            }
            continue;
          }
          final data = Map<String, Object?>.of(line.data);
          final sku = data['sku'], barcode = data['barcode'];
          final candidates = await t.rawQuery(
            'SELECT DISTINCT p.* FROM Product p LEFT JOIN ProductBarcode b ON b.productId=p.id WHERE p.sku=? OR p.barcode=? OR b.barcode=?',
            [sku ?? '', barcode ?? '', barcode ?? ''],
          );
          final prior = await t.query(
            'PendingProductIdentifier',
            where:
                "status<>'invalid' AND ((sku=? AND sku<>?) OR (barcode=? AND barcode<>?))",
            whereArgs: [sku ?? '', '', barcode ?? '', ''],
          );
          final exactPrior = prior
              .where(
                (p) =>
                    p['sku'] == (sku ?? '') && p['barcode'] == (barcode ?? ''),
              )
              .firstOrNull;
          final contradictory =
              (skuCodes[sku]?.length ?? 0) > 1 ||
              (barcodeSkus[barcode]?.length ?? 0) > 1 ||
              candidates.length > 1 ||
              candidates.any(
                (p) =>
                    (sku != null && p['sku'] != null && p['sku'] != sku) ||
                    (barcode != null &&
                        p['barcode'] != null &&
                        p['barcode'] != barcode),
              ) ||
              prior.any(
                (p) =>
                    (sku != null && p['sku'] != '' && p['sku'] != sku) ||
                    (barcode != null &&
                        p['barcode'] != '' &&
                        p['barcode'] != barcode),
              );
          if (contradictory) {
            if (exactPrior != null) report.rowsDuplicate++;
            const reason =
                'SKU/cod de bare în conflict; asocierea existentă este păstrată.';
            await _saveIdentifier(
              t,
              line,
              fileName,
              'needsReview',
              error: reason,
            );
            for (final p in candidates) {
              await t.update(
                'Product',
                {'needsReview': 1},
                where: 'id=?',
                whereArgs: [p['id']],
              );
            }
            report.rowsConflict++;
            report.rowsFailed++;
            report.errors.add('Rând ${line.row}: $reason');
            continue;
          }
          final exactPending = prior
              .where(
                (p) =>
                    p['sku'] == (sku ?? '') && p['barcode'] == (barcode ?? ''),
              )
              .firstOrNull;
          if (candidates.isEmpty && data['name'] == null) {
            if (exactPending != null) {
              report.rowsDuplicate++;
            } else {
              await _saveIdentifier(t, line, fileName, 'pending');
              report.rowsAdded++;
            }
            report.rowsPending++;
            continue;
          }
          if (candidates.length == 1) {
            report.rowsMatched++;
            final p = candidates.single;
            final identical = data.entries
                .where((e) => e.key != 'lastUpdated')
                .every((e) => p[e.key] == e.value);
            if (identical) {
              report.rowsDuplicate++;
              await _saveIdentifier(
                t,
                line,
                fileName,
                'matched',
                matched: p['id'] as String,
              );
              continue;
            }
          }
          final sub = data.remove('subcategoryName'),
              cat = data.remove('categoryName');
          if (cat != null) {
            final roots = await t.query(
              'CategoryNode',
              where: 'name=? AND parentId IS NULL',
              whereArgs: [cat],
            );
            if (roots.length == 1) {
              data['categoryNodeId'] = roots.first['id'];
              if (sub != null) {
                for (final name in sub.toString().split(' › ')) {
                  final children = await t.query(
                    'CategoryNode',
                    where: 'name=? AND parentId=?',
                    whereArgs: [name, data['categoryNodeId']],
                  );
                  if (children.length == 1) {
                    data['categoryNodeId'] = children.first['id'];
                  } else {
                    data['needsReview'] = 1;
                    break;
                  }
                }
              }
            } else {
              data['needsReview'] = 1;
            }
          }
          await t.execute('SAVEPOINT import_row');
          try {
            final result = await upsert(t, data);
            final saved = await t.query(
              'Product',
              where: 'sku=? OR barcode=?',
              whereArgs: [sku ?? '', barcode ?? ''],
            );
            if (result != 'conflict' && saved.length == 1) {
              await _saveIdentifier(
                t,
                line,
                fileName,
                'matched',
                matched: saved.single['id'] as String,
              );
            }
            if (result == 'added') {
              report.rowsAdded++;
            } else if (result == 'conflict') {
              report.rowsFailed++;
              report.errors.add(
                'Rând ${line.row}: identificatori contradictorii. Necesită verificare.',
              );
            } else {
              report.rowsUpdated++;
            }
            await t.execute('RELEASE import_row');
          } catch (e) {
            await t.execute('ROLLBACK TO import_row');
            await t.execute('RELEASE import_row');
            report.rowsFailed++;
            report.errors.add('Rând ${line.row}: $e');
          }
        }
      });
      await Future<void>.delayed(Duration.zero);
    }
    await db.insert('ImportHistory', {
      'fileName': fileName,
      'importedAt': now(),
      'rowsRead': report.rowsRead,
      'rowsAdded': report.rowsAdded,
      'rowsUpdated': report.rowsUpdated,
      'rowsFailed': report.rowsFailed,
      'rowsValid': report.rowsValid,
      'rowsMatched': report.rowsMatched,
      'rowsPending': report.rowsPending,
      'rowsDuplicate': report.rowsDuplicate,
      'rowsConflict': report.rowsConflict,
      'errors': jsonEncode(report.errors),
    });
    return report;
  }

  Future<void> _importExactSku(
    DatabaseExecutor t,
    ImportLine line,
    String file,
    ImportReport report,
    Map<Object?, Set<Object?>> skuCodes,
    Map<Object?, Set<Object?>> barcodeSkus,
  ) async {
    final sku = line.data['sku'], barcode = line.data['barcode'];
    if (sku is! String ||
        sku.isEmpty ||
        barcode is! String ||
        barcode.isEmpty) {
      report.rowsValid--;
      report.rowsInvalid++;
      report.rowsFailed++;
      const reason = 'Sunt necesare SKU și cod de bare, ambele ca text.';
      await _saveIdentifier(t, line, file, 'invalid', error: reason);
      report.errors.add('Rând ${line.row}: $reason');
      return;
    }
    final products = await t.query('Product', where: 'sku=?', whereArgs: [sku]);
    final owners = await t.rawQuery(
      'SELECT DISTINCT p.id FROM Product p LEFT JOIN ProductBarcode b ON b.productId=p.id WHERE p.barcode=? OR b.barcode=?',
      [barcode, barcode],
    );
    final related = await t.query(
      'PendingProductIdentifier',
      where: "(sku=? OR barcode=?) AND status<>'invalid'",
      whereArgs: [sku, barcode],
    );
    final product =
        products.length == 1 &&
            products.single['sourceProductId'] != null &&
            products.single['sourceProductId'] != ''
        ? products.single
        : null;
    final conflict =
        products.length > 1 ||
        (skuCodes[sku]?.length ?? 0) > 1 ||
        (barcodeSkus[barcode]?.length ?? 0) > 1 ||
        owners.any((p) => product == null || p['id'] != product['id']) ||
        (product != null &&
            product['barcode'] != null &&
            product['barcode'] != barcode) ||
        related.any(
          (r) =>
              r['sku'] != sku ||
              r['barcode'] != barcode ||
              r['status'] == 'needsReview' ||
              (r['matchedProductId'] != null &&
                  r['matchedProductId'] != product?['id']),
        );
    if (conflict) {
      report.rowsConflict++;
      report.rowsFailed++;
      const reason =
          'Conflict SKU/cod de bare; asocierea existentă este păstrată.';
      await _saveIdentifier(t, line, file, 'needsReview', error: reason);
      report.errors.add('Rând ${line.row}: $reason');
      return;
    }
    if (product == null) {
      await _saveIdentifier(t, line, file, 'pending');
      report.rowsPending++;
      return;
    }
    if (product['barcode'] == barcode) {
      report.rowsAlreadyMatched++;
      report.rowsDuplicate++;
    } else {
      // ID and SKU already came from Linella. Only attach the Excel barcode.
      final result = await upsert(t, {'id': product['id'], 'barcode': barcode});
      if (result == 'conflict') {
        report.rowsConflict++;
        report.rowsFailed++;
        await _saveIdentifier(
          t,
          line,
          file,
          'needsReview',
          error: 'Conflict de identificatori.',
        );
        return;
      }
      report.rowsMatched++;
      report.rowsUpdated++;
    }
    await _saveIdentifier(
      t,
      line,
      file,
      'matched',
      matched: product['id'] as String,
    );
  }

  Future<void> reconcilePendingIdentifiers({void Function()? check}) async {
    var after = 0;
    while (true) {
      check?.call();
      final rows = await db.query(
        'PendingProductIdentifier',
        where: "status='pending' AND id>?",
        whereArgs: [after],
        orderBy: 'id',
        limit: 200,
      );
      if (rows.isEmpty) return;
      await db.transaction((t) async {
        for (final row in rows) {
          check?.call();
          final products = await t.query(
            'Product',
            where: 'sku=?',
            whereArgs: [row['sku']],
          );
          if (products.length == 1) {
            await _matchPendingSku(t, products.single);
          } else if (products.length > 1) {
            await t.update(
              'PendingProductIdentifier',
              {
                'status': 'needsReview',
                'errorMessage': 'SKU duplicat în catalog.',
              },
              where: 'id=?',
              whereArgs: [row['id']],
            );
          }
        }
      });
      after = rows.last['id'] as int;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _saveIdentifier(
    DatabaseExecutor t,
    ImportLine line,
    String file,
    String status, {
    String? matched,
    String? error,
  }) async {
    final invalid = status == 'invalid';
    final sku = line.data['sku'] ?? (invalid ? null : ''),
        barcode = line.data['barcode'] ?? (invalid ? null : '');
    final invalidKey = invalid
        ? jsonEncode([file, line.sheetName, line.row, line.data, line.error])
        : null;
    final existing = await t.query(
      'PendingProductIdentifier',
      where: invalid
          ? 'invalidKey=?'
          : "sku=? AND barcode=? AND status<>'invalid'",
      whereArgs: invalid ? [invalidKey!] : [sku, barcode],
    );
    final values = <String, Object?>{
      'sku': sku,
      'barcode': barcode,
      'sourceFile': file,
      'sheetName': line.sheetName,
      'rowNumber': line.row,
      'importedAt': now(),
      'status': status,
      'matchedProductId': matched,
      'errorMessage': error,
      'invalidKey': invalidKey,
    };
    if (existing.isEmpty) {
      await t.insert('PendingProductIdentifier', values);
    } else if (existing.single['status'] != status ||
        existing.single['matchedProductId'] != matched) {
      await t.update(
        'PendingProductIdentifier',
        values,
        where: 'id=?',
        whereArgs: [existing.single['id']],
      );
    }
  }

  Future<List<DbRow>> pending({
    String? query,
    int offset = 0,
    int limit = 60,
  }) => db.query(
    'PendingProductIdentifier',
    where:
        "status<>'matched'${query == null || query.isEmpty ? '' : ' AND (sku=? OR barcode=?)'}",
    whereArgs: query == null || query.isEmpty ? null : [query, query],
    orderBy: 'id',
    limit: limit,
    offset: offset,
  );

  Future<void> matchPending(int pendingId, String productId) async {
    await db.transaction((t) async {
      final row = (await t.query(
        'PendingProductIdentifier',
        where: 'id=?',
        whereArgs: [pendingId],
      )).single;
      final product = (await t.query(
        'Product',
        where: 'id=?',
        whereArgs: [productId],
      )).single;
      for (final key in ['sku', 'barcode']) {
        if (row[key] != '' &&
            product[key] != null &&
            product[key] != row[key]) {
          throw const FormatException(
            'Identificator diferit pe produs. Datele sunt păstrate pentru verificare.',
          );
        }
      }
      final result = await upsert(t, {
        'id': productId,
        if (row['sku'] != '') 'sku': row['sku'],
        if (row['barcode'] != '') 'barcode': row['barcode'],
      });
      if (result == 'conflict') {
        throw const FormatException('Identificator folosit de alt produs.');
      }
      await t.update(
        'PendingProductIdentifier',
        {
          'status': 'matched',
          'matchedProductId': productId,
          'errorMessage': null,
        },
        where: 'id=?',
        whereArgs: [pendingId],
      );
    });
  }

  Future<void> associate(String id, String barcode) async {
    await db.transaction((t) async {
      final found = await t.query(
        'ProductBarcode',
        where: 'barcode=?',
        whereArgs: [barcode],
      );
      if (found.isNotEmpty && found.first['productId'] != id) {
        throw const FormatException('Codul aparține deja altui produs.');
      }
      await t.insert('ProductBarcode', {
        'barcode': barcode,
        'productId': id,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final p = (await t.query(
        'Product',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      if (p['barcode'] == null) await upsert(t, {'id': id, 'barcode': barcode});
    });
  }

  Future<void> applySourceDetails(String id, DbRow details) async {
    final sku = details['sku'];
    if (sku != null) {
      final matches = await db.query(
        'Product',
        where: 'sku=? AND id<>? AND productUrl IS NULL',
        whereArgs: [sku, id],
      );
      final online = await byId(id);
      if (matches.length == 1 &&
          online?.text('productUrl') != null &&
          (online!.text('sku') == null || online.text('sku') == sku)) {
        await merge(matches.single['id'] as String, id);
      }
    }
    await db.transaction((t) async {
      await upsert(t, {'id': id, ...details, 'detailsChecked': now()});
    });
  }

  /// Explicitly reviewed association: keep target's public data and source's
  /// imported identifiers. All relation moves occur in the same transaction.
  Future<void> merge(String sourceId, String targetId) async {
    if (sourceId == targetId) throw const FormatException('Alege alt produs.');
    await db.transaction((t) async {
      final source = (await t.query(
        'Product',
        where: 'id=?',
        whereArgs: [sourceId],
      )).single;
      final target = (await t.query(
        'Product',
        where: 'id=?',
        whereArgs: [targetId],
      )).single;
      if (source['sku'] != null &&
          target['sku'] != null &&
          source['sku'] != target['sku']) {
        throw const FormatException(
          'SKU-uri diferite. Asocierea nu poate fi făcută în siguranță.',
        );
      }
      final aliases = await t.query(
        'ProductBarcode',
        where: 'productId=?',
        whereArgs: [sourceId],
      );
      final memberships = await t.query(
        'SpecialCollectionProduct',
        where: 'productId=?',
        whereArgs: [sourceId],
      );
      final promos = await t.query(
        'ProductPromotion',
        where: 'productId=?',
        whereArgs: [sourceId],
      );
      await t.update(
        'PendingProductIdentifier',
        {'matchedProductId': targetId},
        where: 'matchedProductId=?',
        whereArgs: [sourceId],
      );
      await t.delete('Product', where: 'id=?', whereArgs: [sourceId]);
      final combined = {
        ...source,
        ...target,
        'id': targetId,
        'sku': target['sku'] ?? source['sku'],
        'barcode': target['barcode'] ?? source['barcode'],
        'needsReview': 0,
      };
      for (final k in [
        'name',
        'brand',
        'quantity',
        'categoryNodeId',
        'productUrl',
        'imageUrl',
        'localImagePath',
        'imageHash',
      ]) {
        combined[k] = target[k] ?? source[k];
      }
      combined.remove('searchText');
      combined.remove('lastUpdated');
      await upsert(t, combined);
      for (final row in aliases) {
        await t.insert('ProductBarcode', {
          ...row,
          'productId': targetId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in memberships) {
        await t.insert('SpecialCollectionProduct', {
          ...row,
          'productId': targetId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in promos) {
        await t.insert('ProductPromotion', {
          ...row,
          'productId': targetId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }
}
