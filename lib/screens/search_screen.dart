import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../matrix/display_names.dart';
import '../search/search_index_service.dart';

class MessageSearchScreen extends StatefulWidget {
  final Client client;
  final SearchIndexService searchIndex;
  final String? roomId;
  final FutureOr<void> Function(MessageSearchResult result) openResult;

  const MessageSearchScreen({
    required this.client,
    required this.searchIndex,
    required this.openResult,
    this.roomId,
    super.key,
  });

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<MessageSearchResult> _results = const [];
  bool _mediaOnly = false;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    widget.searchIndex.addListener(_indexChanged);
    final needsLocalIndex = widget.roomId == null
        ? widget.searchIndex.hasRoomsUsingLocalSearch
        : !widget.searchIndex.usesSharedSearch(widget.roomId);
    if (widget.searchIndex.indexedDocuments == 0 && needsLocalIndex) {
      unawaited(widget.searchIndex.rebuild());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    widget.searchIndex.removeListener(_indexChanged);
    super.dispose();
  }

  void _indexChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _search);
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    final results = await widget.searchIndex.search(
      query,
      roomId: widget.roomId,
      mediaOnly: _mediaOnly,
    );
    if (!mounted || query != _controller.text.trim()) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.roomId == null ? 'Search messages' : 'Search chat'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => _scheduleSearch(),
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Words in messages, captions, or pictures',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          _search();
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                FilterChip(
                  selected: !_mediaOnly,
                  label: const Text('All'),
                  onSelected: (_) {
                    setState(() => _mediaOnly = false);
                    _search();
                  },
                ),
                const SizedBox(width: 8),
                FilterChip(
                  selected: _mediaOnly,
                  avatar: const Icon(Icons.photo_outlined, size: 18),
                  label: const Text('Media'),
                  onSelected: (_) {
                    setState(() => _mediaOnly = true);
                    _search();
                  },
                ),
                const Spacer(),
                if (widget.searchIndex.usesSharedSearch(widget.roomId))
                  const Text('Shared encrypted search')
                else if (widget.searchIndex.rebuilding)
                  const Text('Indexing…')
                else
                  Text('${widget.searchIndex.indexedDocuments} indexed'),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                ? Center(
                    child: Text(
                      _controller.text.trim().isEmpty
                          ? 'Type something to search.'
                          : 'No matching messages.',
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      final room = widget.client.getRoomById(result.roomId);
                      return ListTile(
                        leading: Icon(
                          result.media
                              ? Icons.photo_outlined
                              : Icons.chat_bubble_outline,
                        ),
                        title: Text(result.senderName),
                        subtitle: Text(
                          result.text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (widget.roomId == null && room != null)
                              Text(
                                readableMatrixRoomName(room),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            Text(
                              MaterialLocalizations.of(
                                context,
                              ).formatMediumDate(result.timestamp),
                            ),
                          ],
                        ),
                        onTap: () => widget.openResult(result),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
