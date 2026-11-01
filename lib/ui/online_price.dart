import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Only open the product's stored official link; never infer it from an SKU.
Uri? linellaProductUri(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      !const ['linella.md', 'www.linella.md'].contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      uri.path.isEmpty ||
      uri.path == '/') {
    return null;
  }
  return uri;
}

Future<bool> openOnlinePrice(Uri uri) async {
  // Do not silently leave the app or fall back to a restricted WebView.
  if (!await supportsLaunchMode(LaunchMode.inAppBrowserView)) return false;
  return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}

class OnlinePriceButton extends StatefulWidget {
  final String? productUrl;
  final Future<bool> Function(Uri) open;
  const OnlinePriceButton({
    super.key,
    required this.productUrl,
    this.open = openOnlinePrice,
  });

  @override
  State<OnlinePriceButton> createState() => _OnlinePriceButtonState();
}

class _OnlinePriceButtonState extends State<OnlinePriceButton> {
  bool opening = false;
  String? error;

  Future<void> open(Uri uri) async {
    setState(() {
      opening = true;
      error = null;
    });
    try {
      if (!await widget.open(uri) && mounted) {
        setState(
          () => error =
              'Fila online nu este disponibilă. Instalează sau actualizează Chrome pe telefon, apoi reîncearcă.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Nu s-a putut deschide pagina. Verifică browserul telefonului și reîncearcă.',
        );
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = linellaProductUri(widget.productUrl);
    if (uri == null) {
      return const Text('Acest produs nu are o pagină Linella asociată.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: opening ? null : () => open(uri),
          icon: const Icon(Icons.public),
          label: Text(opening ? 'SE DESCHIDE…' : 'VEZI PREȚUL PE LINELLA'),
        ),
        const Text(
          'Online • pagina produsului se deschide într-o filă în aplicație. '
          'Dacă apare o verificare de securitate, urmează pașii de pe site. '
          'Închide fila pentru a reveni. Prețul online nu se salvează automat.',
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
