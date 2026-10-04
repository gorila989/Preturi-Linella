typedef DbRow = Map<String, Object?>;

String folded(String value) {
  const a = 'ăâîșşțţ', b = 'aaisstt';
  var s = value.toLowerCase().trim();
  for (var i = 0; i < a.length; i++) {
    s = s.replaceAll(a[i], b[i]);
  }
  return s.replaceAll(RegExp(r'\s+'), ' ');
}

String? codeText(Object? value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  final s = value.toString().trim();
  if (RegExp(r'^\d+(?:\.\d+)?[eE][+\-]?\d+$|[\x00-\x1f]').hasMatch(s)) {
    throw const FormatException(
      'Cod invalid sau în notație științifică. Folosește text.',
    );
  }
  return s;
}

class CategoryNode {
  final String id, name;
  final String? parentId, sourceUrl;
  final int level, sortOrder;
  const CategoryNode(
    this.id,
    this.parentId,
    this.name,
    this.level,
    this.sortOrder, [
    this.sourceUrl,
  ]);
  DbRow toRow() => {
    'id': id,
    'parentId': parentId,
    'name': name,
    'level': level,
    'sortOrder': sortOrder,
    'sourceUrl': sourceUrl,
    'lastUpdated': DateTime.now().toUtc().toIso8601String(),
  };
  factory CategoryNode.fromRow(DbRow r) => CategoryNode(
    r['id'] as String,
    r['parentId'] as String?,
    r['name'] as String,
    r['level'] as int,
    r['sortOrder'] as int,
    r['sourceUrl'] as String?,
  );
}

class Category {
  final String id, name, sourceUrl;
  const Category(this.id, this.name, this.sourceUrl);
}

class Subcategory extends Category {
  final String categoryId;
  const Subcategory(super.id, this.categoryId, super.name, super.sourceUrl);
}

class Product {
  final DbRow data;
  Product(DbRow value) : data = Map.of(value);
  String get id => data['id'] as String;
  String get name => text('name') ?? 'Denumire indisponibilă';
  String? text(String key) => data[key] as String?;
  double? number(String key) => (data[key] as num?)?.toDouble();
  bool get active => data['activePromotion'] == 1;
  double? get price =>
      active ? number('promotionalPrice') ?? number('price') : number('price');
}

class Promotion {
  final String id, name, sourceUrl;
  final DateTime startDate, endDate, lastUpdated;
  const Promotion(
    this.id,
    this.name,
    this.startDate,
    this.endDate,
    this.sourceUrl,
    this.lastUpdated,
  );
  bool active(DateTime now) =>
      !now.isBefore(startDate) && !now.isAfter(endDate);
  bool expired(DateTime now) => now.isAfter(endDate);
  Duration remaining(DateTime now) =>
      endDate.isAfter(now) ? endDate.difference(now) : Duration.zero;
  DbRow toRow() => {
    'id': id,
    'name': name,
    'type': 'mega',
    'startDateTime': startDate.toUtc().toIso8601String(),
    'endDateTime': endDate.toUtc().toIso8601String(),
    'sourceUrl': sourceUrl,
    'lastUpdated': lastUpdated.toUtc().toIso8601String(),
  };
  factory Promotion.fromRow(DbRow r) => Promotion(
    r['id'] as String,
    r['name'] as String,
    DateTime.parse(r['startDateTime'] as String),
    DateTime.parse(r['endDateTime'] as String),
    r['sourceUrl'] as String,
    DateTime.parse(r['lastUpdated'] as String),
  );
}

class ProductFilter {
  final String query;
  final String? categoryId, collection;
  final bool promotions, review;
  const ProductFilter({
    this.query = '',
    this.categoryId,
    this.collection,
    this.promotions = false,
    this.review = false,
  });
}

class ImportLine {
  final int row;
  final DbRow data;
  final String? error;
  final String? sheetName;
  const ImportLine(this.row, this.data, [this.error, this.sheetName]);
}

class ImportReport {
  int rowsAlreadyMatched = 0, rowsInvalid = 0;
  int get rowsErrors => rowsFailed - rowsConflict - rowsInvalid;
  int rowsRead = 0, rowsAdded = 0, rowsUpdated = 0, rowsFailed = 0;
  int rowsValid = 0,
      rowsMatched = 0,
      rowsPending = 0,
      rowsDuplicate = 0,
      rowsConflict = 0;
  final List<String> errors = [];
}
