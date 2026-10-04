import 'dart:async';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../domain/models.dart';
import 'widgets.dart';
import 'transfer_pages.dart';
import 'pending_page.dart';

class ProductsPage extends StatefulWidget {
  final AppState state;
  final String title;
  final ProductFilter filter;
  final String? associateBarcode;
  final String? mergeSourceId;
  final int? pendingId;
  const ProductsPage(
    this.state, {
    super.key,
    this.title = 'Produse',
    this.filter = const ProductFilter(),
    this.associateBarcode,
    this.mergeSourceId,
    this.pendingId,
  });
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage>
    with WidgetsBindingObserver {
  late final query = TextEditingController(text: widget.filter.query);
  final scroll = ScrollController();
  Timer? debounce, expiry;
  List<Product> items = [];
  bool loading = false, discounts = false;
  int total = 0, discountCount = 0, epoch = 0;
  bool hasPending = false;
  String? error;
  ProductFilter get filter => ProductFilter(
    query: query.text,
    categoryId: widget.filter.categoryId,
    collection: widget.filter.collection,
    promotions: discounts || widget.filter.promotions,
    review: widget.filter.review,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(changed);
    scroll.addListener(more);
    load();
    scheduleExpiry();
  }

  void changed() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 400), () => load());
  }

  void more() {
    if (scroll.position.extentAfter < 600 && items.length < total && !loading) {
      load(next: true);
    }
  }

  Future<void> scheduleExpiry() async {
    expiry?.cancel();
    final r = await widget.state.database.db.rawQuery(
      'SELECT min(endDateTime) AS expiry FROM Promotion WHERE endDateTime>=?',
      [DateTime.now().toUtc().toIso8601String()],
    );
    final end = r.first['expiry'] as String?;
    if (!mounted || end == null) return;
    final delay =
        DateTime.parse(end).difference(DateTime.now()) +
        const Duration(milliseconds: 50);
    expiry = Timer(delay.isNegative ? Duration.zero : delay, () {
      load();
      scheduleExpiry();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      load();
      scheduleExpiry();
    }
  }

  Future<void> load({bool next = false}) async {
    final generation = ++epoch;
    setState(() => loading = true);
    try {
      final current = filter;
      final rows = await widget.state.database.products(
        current,
        offset: next ? items.length : 0,
      );
      final count = await widget.state.database.count(current);
      final pending = current.query.trim().isEmpty
          ? <DbRow>[]
          : await widget.state.database.pending(
              query: current.query.trim(),
              limit: 1,
            );
      final reduced = await widget.state.database.count(
        ProductFilter(
          query: query.text,
          categoryId: current.categoryId,
          collection: current.collection,
          promotions: true,
        ),
      );
      if (mounted && generation == epoch) {
        setState(() {
          items = next ? [...items, ...rows] : rows;
          total = count;
          hasPending = pending.isNotEmpty;
          discountCount = reduced;
          error = null;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == epoch) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(changed);
    debounce?.cancel();
    expiry?.cancel();
    query.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Exportă lista',
          onPressed: () => exportProducts(context, widget.state, filter),
          icon: const Icon(Icons.file_upload_outlined),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: query,
            onChanged: (_) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 250), () => load());
            },
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Produs, SKU, cod de bare sau brand',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: Text('$total produse • $discountCount reduceri')),
              if (!widget.filter.promotions)
                FilterChip(
                  label: const Text('🔥 REDUCERI'),
                  selected: discounts,
                  onSelected: (v) {
                    setState(() => discounts = v);
                    load();
                  },
                ),
            ],
          ),
        ),
        if (widget.associateBarcode != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Alege produsul pentru codul ${widget.associateBarcode}',
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        if (hasPending && widget.pendingId == null)
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    PendingPage(widget.state, initialQuery: query.text.trim()),
              ),
            ),
            icon: const Icon(Icons.link),
            label: const Text('Cod existent, produs încă neasociat • VEZI'),
          ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
        Expanded(
          child: items.isEmpty && !loading
              ? const Center(
                  child: Text('Nu există produse pentru această selecție.'),
                )
              : TopList(
                  controller: scroll,
                  count: items.length,
                  builder: (context, index) {
                    final p = items[index];
                    return Card(
                      child: InkWell(
                        onTap: () => guarded(context, () async {
                          if (widget.pendingId != null) {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Confirmă asocierea'),
                                content: Text(
                                  'Asociază identificatorii importați cu ${p.name}?',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Anulează'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Asociază'),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true) {
                              await widget.state.exclusive(
                                () => widget.state.database.matchPending(
                                  widget.pendingId!,
                                  p.id,
                                ),
                              );
                              if (context.mounted) Navigator.pop(context);
                            }
                          } else if (widget.mergeSourceId != null) {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text(
                                  'Confirmă asocierea produselor',
                                ),
                                content: Text(
                                  'Păstrează datele online ale produsului „${p.name}” și transferă codurile produsului importat. Continuă numai dacă ai verificat că este același produs.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Anulează'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Asociază'),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true) {
                              await widget.state.exclusive(
                                () => widget.state.database.merge(
                                  widget.mergeSourceId!,
                                  p.id,
                                ),
                              );
                              if (context.mounted) Navigator.pop(context);
                            }
                          } else if (widget.associateBarcode != null) {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Confirmă asocierea'),
                                content: Text(
                                  '${p.name}\nSKU: ${p.text('sku') ?? '—'}\nCod: ${widget.associateBarcode}',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Înapoi'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Asociază'),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true) {
                              await widget.state.exclusive(
                                () => widget.state.database.associate(
                                  p.id,
                                  widget.associateBarcode!,
                                ),
                              );
                              if (context.mounted) Navigator.pop(context);
                            }
                          } else {
                            await Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => ProductPage(widget.state, p.id),
                              ),
                            );
                          }
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LocalImage(
                                p.text('localImagePath'),
                                widget.state.images,
                                height: 100,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 16,
                                      ),
                                    ),
                                    if (p.text('sku') != null)
                                      Text(
                                        'SKU: ${p.text('sku')}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    if (p.text('barcode') != null)
                                      Text(
                                        p.text('barcode')!,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    const SizedBox(height: 8),
                                    Text(
                                      money(p.price),
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w800,
                                        color: p.active
                                            ? Colors.red.shade700
                                            : Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                      ),
                                    ),
                                    if (p.active &&
                                        p.number('discountPercent') != null)
                                      Text(
                                        '🔥 -${p.number('discountPercent')!.toStringAsFixed(0)}%',
                                      ),
                                    if (p.data['needsReview'] == 1)
                                      const Text(
                                        'Necesită verificare',
                                        style: TextStyle(color: Colors.orange),
                                      ),
                                    if (p.data['isInactive'] == 1)
                                      const Text('Produs inactiv în sursă'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class ProductPage extends StatefulWidget {
  final AppState state;
  final String id;
  const ProductPage(this.state, this.id, {super.key});
  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage> {
  late Future<Product?> product = widget.state.database.byId(widget.id);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Detalii produs')),
    body: FutureBuilder<Product?>(
      future: product,
      builder: (context, snapshot) {
        final p = snapshot.data;
        if (p == null) return const Center(child: Text('Se încarcă produsul…'));
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: LocalImage(
                p.text('localImagePath'),
                widget.state.images,
                height: 280,
                fullImageUrl: p.text('fullImageUrl'),
              ),
            ),
            const SizedBox(height: 24),
            Text(p.name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            SelectableText(
              'SKU: ${p.text('sku') ?? '—'}\nCod de bare: ${p.text('barcode') ?? '—'}',
            ),
            if (p.text('brand') != null) Text('Brand: ${p.text('brand')}'),
            if (p.text('categoryNodeId') != null)
              Text(
                'Categorie: ${widget.state.categories.where((c) => c.id == p.text('categoryNodeId')).firstOrNull?.name ?? p.text('categoryNodeId')}',
              ),
            const SizedBox(height: 16),
            if (p.active && p.number('oldPrice') != null)
              Text(
                'Preț vechi: ${money(p.number('oldPrice'))}',
                style: const TextStyle(decoration: TextDecoration.lineThrough),
              ),
            Text(
              money(p.price),
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            if (p.active)
              Text(
                p.text('promotionState') == 'observed'
                    ? 'Reducere observată • perioadă neprecizată'
                    : 'Promoție activă',
                style: const TextStyle(color: Colors.red),
              ),
            if (p.data['needsReview'] == 1) const Text('Necesită verificare'),
            const SizedBox(height: 12),
            Text(
              'Ultima actualizare: ${stamp(p.text('lastUpdated'))}\nPrețuri salvate din sursa publică sau din import.',
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: widget.state.busy
                  ? null
                  : () => guarded(context, () async {
                      final c = TextEditingController();
                      final value = await showDialog<String>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Asociază un cod de bare'),
                          content: TextField(
                            controller: c,
                            keyboardType: TextInputType.text,
                            decoration: const InputDecoration(
                              labelText: 'Cod de bare (text)',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Anulează'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(ctx, c.text.trim()),
                              child: const Text('Salvează'),
                            ),
                          ],
                        ),
                      );
                      if (value != null && value.isNotEmpty) {
                        await widget.state.exclusive(
                          () => widget.state.database.associate(
                            p.id,
                            codeText(value)!,
                          ),
                        );
                        setState(
                          () => product = widget.state.database.byId(widget.id),
                        );
                      }
                    }),
              icon: const Icon(Icons.link),
              label: const Text('ASOCIAZĂ COD DE BARE'),
            ),
            OutlinedButton.icon(
              onPressed: widget.state.busy
                  ? null
                  : () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ProductsPage(
                            widget.state,
                            title: 'Alege produsul online',
                            mergeSourceId: p.id,
                          ),
                        ),
                      );
                      if (context.mounted) Navigator.pop(context);
                    },
              icon: const Icon(Icons.merge),
              label: const Text('ASOCIAZĂ CU ALT PRODUS'),
            ),
            FutureBuilder<List<Map<String, Object?>>>(
              future: widget.state.database.db.query(
                'ProductBarcode',
                where: 'productId=?',
                whereArgs: [p.id],
              ),
              builder: (context, s) => SelectableText(
                'Coduri asociate: ${(s.data ?? []).map((r) => r['barcode']).join(', ')}',
              ),
            ),
          ],
        );
      },
    ),
  );
}
