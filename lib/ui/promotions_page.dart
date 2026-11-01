import 'package:flutter/material.dart';
import '../app_state.dart';
import '../domain/models.dart';
import 'online_price.dart';
import 'product_pages.dart';
import 'source_status.dart';

class OnlinePromotionsPanel extends StatelessWidget {
  final Future<bool> Function(Uri) open;
  const OnlinePromotionsPanel({super.key, this.open = openOnlinePrice});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Promoții online Linella',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Vezi listele de produse și prețurile afișate de Linella. Necesită internet. '
        'Dacă apare verificarea „Nu sunt robot”, completeaz-o în fila deschisă.',
      ),
      const SizedBox(height: 12),
      OnlinePriceButton(
        productUrl: 'https://linella.md/mega-oferta/',
        label: 'MEGA OFERTĂ — PRODUSE ONLINE',
        description: 'Produsele, prețurile și perioada campaniei de pe site.',
        open: open,
      ),
      const SizedBox(height: 16),
      OnlinePriceButton(
        productUrl: 'https://linella.md/preturi-mici-zi-de-zi/',
        label: 'PREȚURI MICI ZI DE ZI — ONLINE',
        description: 'Lista de oferte „Prețuri mici Zi de Zi” de pe Linella.',
        open: open,
      ),
      const SizedBox(height: 12),
      const Text(
        'Închide fila cu X sau Înapoi pentru a reveni. '
        'Vizualizarea online nu actualizează automat promoțiile salvate pe telefon.',
      ),
    ],
  );
}

class PromotionsPage extends StatelessWidget {
  final AppState state;
  const PromotionsPage(this.state, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Promoții')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const OnlinePromotionsPanel(),
        const SizedBox(height: 24),
        const Divider(),
        Text(
          'Promoții salvate offline',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Datele salvate pot fi vechi. Verifică oferta online înainte de cumpărare.',
        ),
        SourceStatus(state.database),
        OutlinedButton.icon(
          icon: const Icon(Icons.offline_bolt_outlined),
          label: const Text('VEZI PRODUSELE SALVATE ÎN PROMOȚIE'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ProductsPage(
                state,
                title: 'Promoții salvate',
                filter: const ProductFilter(promotions: true),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
