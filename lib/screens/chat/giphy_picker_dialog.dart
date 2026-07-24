import 'package:flutter/material.dart';

import '../../services/giphy_client.dart';

Future<PublicGif?> showGiphyPickerDialog({
  required BuildContext context,
  required GiphyClient client,
}) {
  return showDialog<PublicGif>(
    context: context,
    builder: (context) => _GiphyPickerDialog(client: client),
  );
}

class _GiphyPickerDialog extends StatefulWidget {
  final GiphyClient client;

  const _GiphyPickerDialog({required this.client});

  @override
  State<_GiphyPickerDialog> createState() => _GiphyPickerDialogState();
}

class _GiphyPickerDialogState extends State<_GiphyPickerDialog> {
  final _searchController = TextEditingController();
  late Future<List<PublicGif>> _results;

  @override
  void initState() {
    super.initState();
    _results = widget.client.configured
        ? widget.client.trending()
        : Future.value(const []);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _search([String? query]) {
    if (!widget.client.configured) return;
    setState(() {
      _results = widget.client.search(query ?? _searchController.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            tooltip: 'Close',
            icon: const Icon(Icons.close),
          ),
          title: const Text('Choose a GIF'),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: SearchBar(
                  controller: _searchController,
                  enabled: widget.client.configured,
                  hintText: 'Search GIPHY',
                  leading: const Icon(Icons.search),
                  trailing: [
                    IconButton(
                      onPressed: widget.client.configured ? _search : null,
                      tooltip: 'Search',
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ],
                  onSubmitted: _search,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Icon(Icons.public, size: 14),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Search words and GIF browsing are sent to GIPHY.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(
                      'POWERED BY GIPHY',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: widget.client.configured
                    ? _GifResults(results: _results, onRetry: () => _search())
                    : const _MissingApiKey(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GifResults extends StatelessWidget {
  final Future<List<PublicGif>> results;
  final VoidCallback onRetry;

  const _GifResults({required this.results, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PublicGif>>(
      future: results,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _GifError(error: snapshot.error, onRetry: onRetry);
        }
        final gifs = snapshot.data ?? const [];
        if (gifs.isEmpty) {
          return const Center(child: Text('No GIFs found.'));
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: gifs.length,
          itemBuilder: (context, index) {
            final gif = gifs[index];
            return Semantics(
              button: true,
              label: gif.title.isEmpty ? 'Send GIF' : 'Send ${gif.title}',
              child: InkWell(
                onTap: () => Navigator.pop(context, gif),
                borderRadius: BorderRadius.circular(10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    gif.previewUrl.toString(),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : const ColoredBox(
                            color: Color(0x14000000),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Color(0x14000000),
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MissingApiKey extends StatelessWidget {
  const _MissingApiKey();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: SelectionArea(
            child: Text(
              'GIPHY search needs a free developer API key. Rebuild Patrick '
              'Messenger with:\n\n'
              '--dart-define=GIPHY_API_KEY=your_key_here',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class _GifError extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;

  const _GifError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44),
            const SizedBox(height: 12),
            Text(
              error is GiphyException
                  ? error.toString()
                  : 'GIPHY could not be reached.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
