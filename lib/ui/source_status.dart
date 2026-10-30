import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/catalog_repository.dart';
import 'widgets.dart';

String freshnessWarning(Map<String, dynamic> source, DateTime now) {
  final checked = DateTime.tryParse(
    source['lastSuccessfulCheckAt']?.toString() ?? '',
  );
  if (source['errorCode'] == 'access_denied') {
    return 'Linella refuză accesul serverului. Prețuri posibil neactualizate.';
  }
  if (source['status'] == 'error') {
    return 'Actualizarea Linella pe server a eșuat. Prețuri posibil neactualizate.';
  }
  if (checked == null) {
    return 'Prețuri posibil neactualizate: serverul nu confirmă data verificării Linella.';
  }
  if (checked.isAfter(now) ||
      now.difference(checked) > const Duration(hours: 26)) {
    return 'Prețuri posibil neactualizate: verificarea Linella este veche.';
  }
  if (source['status'] == 'running') {
    return 'Verificarea Linella este în curs pe server.';
  }
  return '';
}

class SourceStatus extends StatefulWidget {
  final CatalogRepository database;
  const SourceStatus(this.database, {super.key});
  @override
  State<SourceStatus> createState() => _SourceStatusState();
}

class _SourceStatusState extends State<SourceStatus> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, Object?>>>(
    future: widget.database.db.query(
      'Settings',
      where: "key IN ('sourceFreshness','apiLastSuccess','apiLastError')",
    ),
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const SizedBox.shrink();
      final settings = {
        for (final row in snapshot.data!) row['key']: row['value'],
      };
      Map<String, dynamic> source = {};
      try {
        source = Map<String, dynamic>.from(
          jsonDecode(settings['sourceFreshness'] as String? ?? '{}') as Map,
        );
      } catch (_) {
        /* Treat malformed metadata as unknown. */
      }
      final error = settings['apiLastError'] as String? ?? '';
      final warning = error.isNotEmpty
          ? 'Ultima descărcare nu s-a finalizat. Se folosesc datele salvate.'
          : freshnessWarning(source, DateTime.now());
      return Card(
        color: warning.isNotEmpty
            ? Theme.of(context).colorScheme.errorContainer
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (warning.isNotEmpty)
                Text(
                  warning,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              Text(
                'Catalog verificat pe Linella: ${stamp(source['lastSuccessfulCheckAt'])}',
              ),
              Text(
                'Descărcat pe telefon: ${stamp(settings['apiLastSuccess'])}',
              ),
            ],
          ),
        ),
      );
    },
  );
}
