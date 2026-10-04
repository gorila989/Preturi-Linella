import 'dart:convert';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:excel/excel.dart';
import '../domain/models.dart';

class TransferService {
  String sheetName = 'CSV';
  String? barcodeColumn, skuColumn;
  static const aliases = {
    'sku': 'sku',
    'cod sku': 'sku',
    'cod produs': 'sku',
    'product code': 'sku',
    'productcode': 'sku',
    'cod articol': 'sku',
    'barcode': 'barcode',
    'cod de bare': 'barcode',
    'cod bare': 'barcode',
    'bar code': 'barcode',
    'ean13': 'barcode',
    'ean-13': 'barcode',
    'upc': 'barcode',
    'ean': 'barcode',
    'denumire': 'name',
    'denumire produs': 'name',
    'produs': 'name',
    'name': 'name',
    'product': 'name',
    'product name': 'name',
    'brand': 'brand',
    'marca': 'brand',
    'cantitate': 'quantity',
    'gramaj': 'quantity',
    'pret': 'price',
    'price': 'price',
    'pret vechi': 'oldPrice',
    'promotie': 'promotionalPrice',
    'pret promotional': 'promotionalPrice',
    'reducere': 'discountPercent',
    'reducere %': 'discountPercent',
    'categorie': 'categoryName',
    'subcategorie': 'subcategoryName',
    'data actualizarii': 'lastUpdated',
  };

  // Read identifier cells from their original XML text, without a floating
  // point round-trip. A simple Excel zero-mask also preserves displayed zeros.
  List<List<Object?>> _xlsxRows(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException(
        'Fișierul selectat este gol. Copiază din nou fișierul pe telefon.',
      );
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0xd0 &&
        bytes[1] == 0xcf &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xe0) {
      throw const FormatException(
        'Fișier Excel vechi sau criptat. Salvează o copie XLSX fără parolă ori CSV; simpla redenumire nu schimbă formatul.',
      );
    }
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4b ||
        bytes[2] != 3 ||
        bytes[3] != 4) {
      throw const FormatException(
        'Conținutul fișierului nu este XLSX. Selectează fișierul Excel original sau varianta CSV, nu o pagină ori un link salvat.',
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw const FormatException(
        'Fișierul XLSX este incomplet sau deteriorat. Copiază-l din nou pe telefon ori folosește varianta CSV.',
      );
    }
    if (archive.findFile('xl/workbook.xml') == null) {
      throw const FormatException(
        'Arhiva selectată nu este un registru XLSX. Selectează fișierul Excel, nu arhiva cu sursele aplicației.',
      );
    }
    if (archive.files.fold<int>(0, (n, f) => n + f.size) > 150 * 1024 * 1024) {
      throw const FormatException('Fișier Excel prea mare după decomprimare.');
    }
    XmlDocument? xml(String name) {
      final f = archive.findFile(name);
      return f == null
          ? null
          : XmlDocument.parse(utf8.decode(f.content as List<int>));
    }

    final shared =
        xml('xl/sharedStrings.xml')
            ?.findAllElements('si')
            .map((e) => e.findAllElements('t').map((t) => t.innerText).join())
            .toList() ??
        <String>[];
    final styles = xml('xl/styles.xml');
    final formats = <String?, String?>{
      for (final e in styles?.findAllElements('numFmt') ?? <XmlElement>[])
        e.getAttribute('numFmtId'): e.getAttribute('formatCode'),
    };
    final xfs =
        styles
            ?.findAllElements('cellXfs')
            .firstOrNull
            ?.findElements('xf')
            .toList() ??
        <XmlElement>[];
    final sheets =
        xml('xl/workbook.xml')?.findAllElements('sheet') ?? <XmlElement>[];
    final rels =
        xml(
          'xl/_rels/workbook.xml.rels',
        )?.findAllElements('Relationship').toList() ??
        <XmlElement>[];
    for (final sheet in sheets) {
      final rel = rels
          .where((r) => r.getAttribute('Id') == sheet.getAttribute('r:id'))
          .firstOrNull;
      final target = rel?.getAttribute('Target');
      if (target == null) continue;
      final part = target.startsWith('/')
          ? target.substring(1)
          : Uri.parse('xl/workbook.xml').resolve(target).path;
      final doc = xml(part);
      if (doc == null) continue;
      final result = <List<Object?>>[];
      for (final row in doc.findAllElements('row')) {
        final rowNumber =
            int.tryParse(row.getAttribute('r') ?? '') ?? result.length + 1;
        if (rowNumber > 200000) {
          throw const FormatException('Prea multe rânduri Excel.');
        }
        while (result.length < rowNumber) {
          result.add([]);
        }
        final values = result[rowNumber - 1];
        for (final cell in row.findElements('c')) {
          final letters = RegExp(
            r'^[A-Z]+',
          ).stringMatch(cell.getAttribute('r') ?? '');
          var column = 0;
          for (final c in (letters ?? '').codeUnits) {
            column = column * 26 + c - 64;
          }
          if (column == 0) column = values.length + 1;
          if (column > 1024) {
            throw const FormatException('Prea multe coloane Excel.');
          }
          while (values.length < column) {
            values.add(null);
          }
          final type = cell.getAttribute('t');
          final raw = cell.getElement('v')?.innerText ?? '';
          String? value;
          if (cell.getElement('f') != null) {
            value = '#FORMULA';
          } else if (type == 'inlineStr') {
            value = cell.findAllElements('t').map((t) => t.innerText).join();
          } else if (type == 's') {
            value = shared[int.parse(raw)];
          } else if (type == null || type == 'n') {
            value = raw;
            final match = RegExp(
              r'^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$',
            ).firstMatch(raw);
            if (match != null) {
              final fraction = match[2] ?? '';
              final digits = '${match[1]}$fraction';
              final shift =
                  (int.tryParse(match[3] ?? '0') ?? 0) - fraction.length;
              if (shift.abs() <= 30) {
                final numerator = BigInt.parse(digits);
                final factor = BigInt.from(10).pow(shift.abs());
                final integer = shift >= 0
                    ? numerator * factor
                    : numerator ~/ factor;
                if ((shift >= 0 || numerator % factor == BigInt.zero) &&
                    integer.toString().length <= 15) {
                  value = integer.toString();
                  final style =
                      int.tryParse(cell.getAttribute('s') ?? '') ?? -1;
                  final mask = style >= 0 && style < xfs.length
                      ? formats[xfs[style].getAttribute('numFmtId')]
                      : null;
                  if (mask != null && RegExp(r'^0+$').hasMatch(mask)) {
                    value = value.padLeft(mask.length, '0');
                  }
                } else {
                  value = '#UNSAFE_NUMBER:$raw';
                }
              } else {
                value = '#UNSAFE_NUMBER:$raw';
              }
            } else if (raw.isNotEmpty) {
              value = '#UNSAFE_NUMBER:$raw';
            }
          } else {
            value = raw;
          }
          values[column - 1] = value;
        }
      }
      if (result.isNotEmpty) {
        sheetName = sheet.getAttribute('name') ?? '';
        return result;
      }
    }
    throw const FormatException('Fișierul Excel nu conține rânduri.');
  }

  List<ImportLine> decode(Uint8List bytes, String fileName) {
    if (bytes.length > 30 * 1024 * 1024) {
      throw const FormatException(
        'Fișierul depășește 30 MB. Împarte-l în fișiere mai mici.',
      );
    }
    final List<List<Object?>> rows;
    if (fileName.toLowerCase().endsWith('.xlsx')) {
      rows = _xlsxRows(bytes);
    } else if (fileName.toLowerCase().endsWith('.csv')) {
      final text = utf8
          .decode(bytes)
          .replaceFirst('\uFEFF', '')
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      final first = text.split(RegExp(r'\r?\n')).first;
      final separator = [';', ',', '\t'].reduce(
        (a, b) => first.split(a).length >= first.split(b).length ? a : b,
      );
      rows = CsvToListConverter(
        fieldDelimiter: separator,
        shouldParseNumbers: false,
        eol: '\n',
      ).convert(text);
    } else {
      throw const FormatException('Alege un fișier XLSX sau CSV UTF-8.');
    }
    if (rows.length < 2) {
      throw const FormatException('Fișierul nu conține date după antet.');
    }
    final columns = rows.first
        .map((v) => aliases[folded(v?.toString() ?? '')])
        .toList();
    if (!columns.contains('sku') && !columns.contains('barcode')) {
      throw const FormatException(
        'Antetul trebuie să conțină SKU sau Cod de bare.',
      );
    }
    barcodeColumn = columns.contains('barcode')
        ? rows.first[columns.indexOf('barcode')]?.toString()
        : null;
    skuColumn = columns.contains('sku')
        ? rows.first[columns.indexOf('sku')]?.toString()
        : null;
    final mapped = columns.whereType<String>().toList();
    if (mapped.toSet().length != mapped.length) {
      throw const FormatException(
        'Mai multe coloane au aceeași semnificație. Păstrează o singură coloană pentru fiecare câmp.',
      );
    }
    return [
      for (var i = 1; i < rows.length; i++)
        if (rows[i].any((v) => v != null && v.toString().trim().isNotEmpty))
          _line(i + 1, rows[i], columns),
    ];
  }

  ImportLine _line(int row, List<Object?> values, List<String?> columns) {
    final result = <String, Object?>{};
    try {
      for (var i = 0; i < columns.length && i < values.length; i++) {
        final key = columns[i], value = values[i];
        if (key == null || value == null || value.toString().trim().isEmpty) {
          continue;
        }
        if (value == '#FORMULA') {
          throw const FormatException('Înlocuiește formulele cu valori.');
        }
        if (key == 'sku' || key == 'barcode') {
          if (value.toString().startsWith('#UNSAFE_NUMBER:')) {
            throw const FormatException(
              'Identificator numeric fracționar sau peste precizia sigură Excel. Folosește text.',
            );
          }
          // Numeric integers are valid identifiers; fractional or imprecise
          // Excel numbers are rejected. Text identifiers keep leading zeros.
          if (value is num) {
            if (!value.isFinite ||
                value < 0 ||
                value != value.truncate() ||
                value >= 1000000000000000) {
              throw const FormatException(
                'Identificator numeric fracționar sau peste precizia sigură Excel. Folosește text.',
              );
            }
            result[key] = value.toInt().toString();
          } else {
            result[key] = codeText(
              value.toString().trim().replaceFirstMapped(
                RegExp(r'^(\d+)\.0+$'),
                (m) => m[1]!,
              ),
            );
          }
        } else if ([
          'price',
          'oldPrice',
          'promotionalPrice',
          'discountPercent',
        ].contains(key)) {
          final parsed = double.tryParse(
            value
                .toString()
                .replaceFirst('#UNSAFE_NUMBER:', '')
                .replaceAll(' ', '')
                .replaceAll(',', '.')
                .replaceAll('%', ''),
          );
          if (parsed == null ||
              !parsed.isFinite ||
              parsed < 0 ||
              (key == 'discountPercent' && parsed > 100)) {
            throw FormatException('Valoare invalidă pentru $key.');
          }
          result[key] = parsed;
        } else if (key == 'lastUpdated') {
          result[key] = DateTime.parse(value.toString()).toIso8601String();
        } else {
          result[key] = value.toString().trim();
        }
      }
      if (result['sku'] == null && result['barcode'] == null) {
        throw const FormatException('Lipsește SKU și codul de bare.');
      }
      result['lastUpdated'] ??= DateTime.now().toIso8601String();
      return ImportLine(row, result, null, sheetName);
    } catch (e) {
      return ImportLine(row, result, e.toString(), sheetName);
    }
  }

  Uint8List encode(
    List<Product> products,
    Map<String, String> categories,
    Map<String, String> subcategories, {
    required bool xlsx,
  }) {
    final rows = <List<String>>[
      [
        'SKU',
        'Cod de bare',
        'Denumire',
        'Categorie',
        'Subcategorie',
        'Brand',
        'Cantitate',
        'Preț',
        'Promoție',
        'Preț vechi',
        'Reducere %',
        'Data actualizării',
      ],
      for (final p in products)
        [
          p.text('sku') ?? '',
          p.text('barcode') ?? '',
          p.name,
          categories[p.text('categoryId')] ?? '',
          subcategories[p.text('subcategoryId')] ?? '',
          p.text('brand') ?? '',
          p.text('quantity') ?? '',
          p.number('price')?.toString() ?? '',
          p.number('promotionalPrice')?.toString() ?? '',
          p.number('oldPrice')?.toString() ?? '',
          p.number('discountPercent')?.toString() ?? '',
          p.text('lastUpdated') ?? '',
        ],
    ];
    if (!xlsx) {
      return Uint8List.fromList(
        utf8.encode('\uFEFF${const ListToCsvConverter().convert(rows)}'),
      );
    }
    final book = Excel.createExcel();
    final sheet = book['Produse'];
    for (final row in rows) {
      sheet.appendRow(row.map((v) => TextCellValue(v)).toList());
    }
    book.setDefaultSheet('Produse');
    book.delete('Sheet1');
    return Uint8List.fromList(book.encode()!);
  }
}
