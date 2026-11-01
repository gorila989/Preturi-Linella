import 'package:flutter/material.dart';
import '../app_state.dart';
import '../domain/models.dart';
import '../services/sync_service.dart';
import '../services/linella_parser.dart';
import 'product_pages.dart';
import 'scanner_page.dart';
import 'transfer_pages.dart';
import 'widgets.dart';
import 'source_status.dart';
import 'promotions_page.dart';
import 'pending_page.dart';
import 'storage_page.dart';

class HomePage extends StatefulWidget {
  final AppState state;
  const HomePage(this.state, {super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;
  bool megaCheckRequested = false;
  final expanded = <String>{};
  List<CategoryNode> homeCategories(AppState s) {
    final list = <CategoryNode>[];
    void add(String? parent) {
      for (final n in s.categories.where((n) => n.parentId == parent)) {
        list.add(n);
        if (expanded.contains(n.id)) add(n.id);
      }
    }

    add(null);
    return list;
  }

  Widget homeCategory(AppState s, CategoryNode n) {
    final children = s.categories.any((c) => c.parentId == n.id);
    void toggle() {
      setState(() {
        if (!expanded.add(n.id)) expanded.remove(n.id);
      });
    }

    void products() {
      open(
        ProductsPage(
          s,
          title: n.name,
          filter: ProductFilter(categoryId: n.id),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: n.level * 14.0),
      child: Card(
        child: Column(
          children: [
            ListTile(
              title: Text(n.name),
              onTap: children ? toggle : products,
              trailing: children
                  ? IconButton(
                      onPressed: toggle,
                      icon: Icon(
                        expanded.contains(n.id) ? Icons.remove : Icons.add,
                      ),
                    )
                  : const Icon(Icons.chevron_right),
            ),
            if (children && expanded.contains(n.id))
              TextButton(
                onPressed: products,
                child: const Text('VEZI TOATE PRODUSELE'),
              ),
          ],
        ),
      ),
    );
  }

  void open(Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  Future<void> scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (code == null || !mounted) return;
    await guarded(context, () async {
      final product = await widget.state.database.barcode(code);
      if (!mounted) return;
      if (product != null) {
        open(ProductPage(widget.state, product.id));
        return;
      }
      final pending = await widget.state.database.pending(query: code);
      if (!mounted) return;
      if (pending.isNotEmpty) {
        open(PendingPage(widget.state, initialQuery: code));
        return;
      }
      final action = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Produsul nu a fost găsit.'),
          content: SelectableText('Cod: $code'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, 'search'),
              child: const Text('CĂUTARE MANUALĂ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, 'associate'),
              child: const Text('ASOCIAZĂ PRODUS'),
            ),
          ],
        ),
      );
      if (action != null && mounted) {
        open(
          ProductsPage(
            widget.state,
            associateBarcode: action == 'associate' ? code : null,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(9),
          child: Image.asset('assets/logo.png'),
        ),
        title: const Text(
          'CAUTĂ PREȚ',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.3),
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizare date',
            onPressed: () => open(SyncPage(s)),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (v) {
          if (v == 2) {
            scan();
            return;
          }
          if (v == 3) {
            open(PromotionsPage(s));
            return;
          }
          setState(() => index = v);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            label: 'Acasă',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            label: 'Categorii',
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Scanare',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_fire_department_outlined),
            label: 'Promoții',
          ),
          NavigationDestination(icon: Icon(Icons.menu), label: 'Mai multe'),
        ],
      ),
      body: Column(
        children: [
          if (s.syncing)
            Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                dense: true,
                leading: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: const Text('Actualizare în curs…'),
                subtitle: Text(
                  s.report?.operation ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => open(SyncPage(s)),
              ),
            ),
          if (s.writing) const LinearProgressIndicator(),
          if (index == 0) SourceStatus(s.database),
          Expanded(
            child: index == 1
                ? CategoryTree(s)
                : index == 4
                ? more(s)
                : TopList(
                    count: 7 + homeCategories(s).length,
                    builder: (context, i) => switch (i) {
                      0 => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Catalogul tău, disponibil offline',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      1 => TextField(
                        readOnly: true,
                        onTap: () => open(ProductsPage(s)),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Caută produs, SKU sau cod de bare',
                        ),
                      ),
                      2 => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: FilledButton.icon(
                          onPressed: scan,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text('SCANEAZĂ'),
                          ),
                        ),
                      ),
                      3 =>
                        s.productCount == 0
                            ? Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'BUN VENIT ÎN CAUTĂ PREȚ',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Descarcă datele publice sau importă un fișier. După salvare, căutarea și scanarea funcționează fără internet.',
                                      ),
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton.icon(
                                            onPressed: () => open(SyncPage(s)),
                                            icon: const Icon(Icons.bolt),
                                            label: const Text(
                                              'DESCARCĂ DATELE',
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                open(ImportPage(s)),
                                            child: const Text('IMPORTĂ FIȘIER'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  '${s.productCount} produse salvate • SQLite local',
                                ),
                              ),
                      4 => Card(
                        color: Theme.of(
                          context,
                        ).colorScheme.errorContainer.withValues(alpha: 0.4),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '🔥 MEGA OFERTĂ',
                                style: TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Countdown(
                                s.promotion,
                                verify: () {
                                  if (s.busy) return;
                                  setState(() => megaCheckRequested = true);
                                  s.sync(SyncMode.quick);
                                },
                              ),
                              if (megaCheckRequested &&
                                  !s.syncing &&
                                  (s.report?.errors ?? 0) > 0)
                                const Text(
                                  'Nu s-a putut verifica noua ofertă. Verifică conexiunea la internet. Oferta salvată este păstrată.',
                                ),
                              const SizedBox(height: 12),
                              FilledButton.tonal(
                                onPressed: () => open(
                                  ProductsPage(
                                    s,
                                    title: 'Mega Ofertă',
                                    filter: const ProductFilter(
                                      collection: 'mega',
                                    ),
                                  ),
                                ),
                                child: const Text('VEZI PRODUSELE'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      5 => Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(18),
                          title: const Text(
                            '⭐ CELE MAI BUNE OFERTE',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: const Text(
                            'Selecția salvată din sursa publică',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => open(
                            ProductsPage(
                              s,
                              title: 'Cele mai bune oferte',
                              filter: const ProductFilter(collection: 'best'),
                            ),
                          ),
                        ),
                      ),
                      6 => Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(18),
                          leading: const Icon(Icons.folder_outlined),
                          title: const Text('CATEGORII'),
                          subtitle: Text(
                            '${s.categories.where((c) => c.parentId == null).length} categorii • toate nivelurile',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => setState(() => index = 1),
                        ),
                      ),
                      _ => homeCategory(s, homeCategories(s)[i - 7]),
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget more(AppState s) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final item in <(IconData, String, VoidCallback)>[
        (Icons.sync, 'Actualizare date', () => open(SyncPage(s))),
        (Icons.download, 'Importă produse / SKU', () => open(ImportPage(s))),
        (Icons.link, 'Identificatori neasociați', () => open(PendingPage(s))),
        (Icons.storage, 'Setări • Stocare', () => open(StoragePage(s))),
        (
          Icons.upload,
          'Exportă produse / SKU',
          () => exportProducts(context, s, const ProductFilter()),
        ),
        (Icons.save_outlined, 'Backup / Restaurare', () => open(BackupPage(s))),
        (
          Icons.rule,
          'Necesită verificare',
          () => open(
            ProductsPage(
              s,
              title: 'Necesită verificare',
              filter: const ProductFilter(review: true),
            ),
          ),
        ),
        (Icons.history, 'Istoric actualizări', () => history(context, s)),
        (
          Icons.receipt_long,
          'Istoric importuri',
          () => history(context, s, imports: true),
        ),
      ])
        Card(
          child: ListTile(
            leading: Icon(item.$1),
            title: Text(item.$2),
            trailing: const Icon(Icons.chevron_right),
            onTap: item.$3,
          ),
        ),
      SwitchListTile(
        title: const Text('Setări • Mod întunecat'),
        value: s.dark,
        onChanged: s.setDark,
      ),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
            'CAUTĂ PREȚ • 2.0.9\nCatalog personal offline.\nDate publice Linella și fișiere importate.\nInternetul este folosit la actualizare și la vizualizarea paginii Linella.\nPrețurile salvate pot diferi de cele actuale din magazin.',
          ),
        ),
      ),
    ],
  );
}

class CategoryTree extends StatefulWidget {
  final AppState state;
  final Set<String>? selection;
  final VoidCallback? onChanged;
  const CategoryTree(this.state, {super.key, this.selection, this.onChanged});
  @override
  State<CategoryTree> createState() => _CategoryTreeState();
}

class _CategoryTreeState extends State<CategoryTree> {
  final expanded = <String>{};
  List<CategoryNode> visible() {
    final result = <CategoryNode>[];
    void add(String? parent) {
      for (final n in widget.state.categories.where(
        (n) => n.parentId == parent,
      )) {
        result.add(n);
        if (expanded.contains(n.id)) add(n.id);
      }
    }

    add(null);
    return result;
  }

  Future<void> configure(CategoryNode n) async {
    final controller = TextEditingController(text: n.sourceUrl ?? '');
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Adresă Linella • ${n.name}'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'https://linella.md/…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Salvează'),
          ),
        ],
      ),
    );
    if (url == null || !mounted) return;
    await guarded(
      context,
      () => widget.state.exclusive(() async {
        final safe = LinellaParser().publicUrl(url);
        await widget.state.database.db.update(
          'CategoryNode',
          {'sourceUrl': safe},
          where: 'id=?',
          whereArgs: [n.id],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = visible();
    return TopList(
      count: rows.length,
      builder: (context, i) {
        final n = rows[i],
            children = widget.state.categories.any((c) => c.parentId == n.id);
        return Padding(
          padding: EdgeInsets.only(left: n.level * 16.0),
          child: Card(
            child: Column(
              children: [
                ListTile(
                  onLongPress: widget.selection == null
                      ? () => configure(n)
                      : null,
                  leading: widget.selection == null
                      ? Icon(
                          children
                              ? Icons.folder_outlined
                              : Icons.label_outline,
                        )
                      : Checkbox(
                          value: widget.selection!.contains(n.id),
                          onChanged: (v) {
                            setState(() {
                              if (v!) {
                                widget.selection!.add(n.id);
                              } else {
                                widget.selection!.remove(n.id);
                              }
                            });
                            widget.onChanged?.call();
                          },
                        ),
                  title: Text(n.name),
                  trailing: children
                      ? IconButton(
                          tooltip: expanded.contains(n.id)
                              ? 'Restrânge'
                              : 'Extinde',
                          onPressed: () => setState(() {
                            if (!expanded.add(n.id)) expanded.remove(n.id);
                          }),
                          icon: Icon(
                            expanded.contains(n.id) ? Icons.remove : Icons.add,
                          ),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () => children
                      ? setState(() {
                          if (!expanded.add(n.id)) expanded.remove(n.id);
                        })
                      : Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => ProductsPage(
                              widget.state,
                              title: n.name,
                              filter: ProductFilter(categoryId: n.id),
                            ),
                          ),
                        ),
                ),
                if (children &&
                    expanded.contains(n.id) &&
                    widget.selection == null)
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ProductsPage(
                          widget.state,
                          title: n.name,
                          filter: ProductFilter(categoryId: n.id),
                        ),
                      ),
                    ),
                    child: const Text('VEZI TOATE PRODUSELE'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class SyncPage extends StatefulWidget {
  final AppState state;
  const SyncPage(this.state, {super.key});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  bool forceImages = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final s = widget.state;
      return Scaffold(
        appBar: AppBar(title: const Text('Actualizare date')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Datele noi se salvează pe pagini. Poți căuta, scana și naviga în timpul actualizării.',
              style: TextStyle(fontSize: 16),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Server catalog'),
              subtitle: Text(
                s.apiUrl.isEmpty
                    ? 'Introdu adresa Render înainte de prima sincronizare'
                    : s.apiUrl,
              ),
              trailing: const Icon(Icons.edit),
              onTap: s.busy
                  ? null
                  : () async {
                      final controller = TextEditingController(text: s.apiUrl);
                      final value = await showDialog<String>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Adresa backendului'),
                          content: TextField(
                            controller: controller,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(
                              hintText: 'https://nume.onrender.com',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('ANULEAZĂ'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(c, controller.text.trim()),
                              child: const Text('SALVEAZĂ'),
                            ),
                          ],
                        ),
                      );
                      if (value != null && context.mounted) {
                        await guarded(context, () => s.setApiUrl(value));
                      }
                    },
            ),
            SourceStatus(s.database),
            const SizedBox(height: 18),
            if (s.productCount == 0) ...[
              const Text('Prima configurare'),
              FilledButton(
                onPressed: s.busy ? null : () => s.sync(SyncMode.full),
                child: const Text('ACTUALIZARE INIȚIALĂ COMPLETĂ'),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Continuă cu ecranul blocat'),
              subtitle: const Text('Serviciu Android cu notificare de progres'),
              value: s.background,
              onChanged: s.busy ? null : s.setBackground,
            ),
            FilledButton.icon(
              onPressed: s.busy
                  ? null
                  : () => s.sync(SyncMode.quick, forceImages: forceImages),
              icon: const Icon(Icons.bolt),
              label: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('ACTUALIZARE RAPIDĂ'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Descarcă numai modificările publicate de server. Actualizarea totală recitește catalogul din API.',
              ),
            ),
            OutlinedButton.icon(
              onPressed: s.busy
                  ? null
                  : () => s.sync(SyncMode.full, forceImages: forceImages),
              icon: const Icon(Icons.sync),
              label: const Text('ACTUALIZARE TOTALĂ'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Reverifică imaginile existente'),
              subtitle: const Text(
                'Opțional; poate crește durata și traficul.',
              ),
              value: forceImages,
              onChanged: s.busy ? null : (v) => setState(() => forceImages = v),
            ),
            FutureBuilder<List<Map<String, Object?>>>(
              future: s.database.db.rawQuery(
                "SELECT syncType,max(finishedAt) finishedAt FROM SyncHistory WHERE status='complete' GROUP BY syncType",
              ),
              builder: (c, r) => Text(
                (r.data ?? [])
                    .map(
                      (x) =>
                          'Ultima descărcare ${syncName(x['syncType'])}: ${stamp(x['finishedAt'])}',
                    )
                    .join('\n'),
              ),
            ),
            if (s.report != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.report!.operation,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (s.syncing) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                        TextButton(
                          onPressed: s.cancelSync,
                          child: const Text('ANULEAZĂ'),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(s.report!.summary),
                      TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => TextReport(
                              'Raport actualizare',
                              s.report!.log.join('\n'),
                            ),
                          ),
                        ),
                        child: const Text('VEZI DETALIILE'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Cu actualizarea în fundal activată, Android afișează o notificare și poate continua cu ecranul blocat. Oprirea forțată sau limitele Android pot întrerupe operația; paginile deja salvate rămân disponibile.',
            ),
          ],
        ),
      );
    },
  );
}

class SelectCategories extends StatefulWidget {
  final AppState state;
  const SelectCategories(this.state, {super.key});
  @override
  State<SelectCategories> createState() => _SelectCategoriesState();
}

class _SelectCategoriesState extends State<SelectCategories> {
  final selected = <String>{};
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Selectează categorii')),
    body: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => setState(
                () => selected.addAll(widget.state.categories.map((c) => c.id)),
              ),
              child: const Text('SELECTEAZĂ TOATE'),
            ),
            TextButton(
              onPressed: () => setState(selected.clear),
              child: const Text('DESELECTEAZĂ TOATE'),
            ),
          ],
        ),
        Expanded(
          child: CategoryTree(
            widget.state,
            selection: selected,
            onChanged: () => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: selected.isEmpty || widget.state.busy
                ? null
                : () {
                    widget.state.sync(
                      SyncMode.selected,
                      selected: Set.of(selected),
                    );
                    Navigator.pop(context);
                  },
            child: Text('ACTUALIZEAZĂ SELECȚIA (${selected.length})'),
          ),
        ),
      ],
    ),
  );
}
