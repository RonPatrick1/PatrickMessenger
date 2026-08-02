import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/media_save_service.dart';

class SwipeableGalleryImage {
  final Uint8List bytes;
  final String name;
  final String mimeType;

  const SwipeableGalleryImage({
    required this.bytes,
    required this.name,
    required this.mimeType,
  });
}

typedef SwipeableGalleryImageLoader = Future<SwipeableGalleryImage> Function();

class SwipeableImageGallery extends StatefulWidget {
  final List<SwipeableGalleryImageLoader> imageLoaders;
  final int initialIndex;
  final bool? desktopControlsOverride;

  const SwipeableImageGallery({
    required this.imageLoaders,
    this.initialIndex = 0,
    this.desktopControlsOverride,
    super.key,
  }) : assert(imageLoaders.length > 0);

  @override
  State<SwipeableImageGallery> createState() => _SwipeableImageGalleryState();
}

class _SwipeableImageGalleryState extends State<SwipeableImageGallery> {
  late final PageController _controller;
  late final List<Future<SwipeableGalleryImage>> _images;
  late int _index;

  final Set<int> _saved = <int>{};
  Timer? _statusTimer;
  DateTime? _lastWheel;
  bool _zoomMode = false;
  bool _saving = false;
  String? _status;

  bool get _desktop {
    final override = widget.desktopControlsOverride;
    if (override != null) return override;

    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.imageLoaders.length - 1);
    _controller = PageController(initialPage: _index);
    _images = widget.imageLoaders
        .map((loader) => loader())
        .toList(growable: false);
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (_zoomMode ||
        index < 0 ||
        index >= _images.length ||
        !_controller.hasClients) {
      return;
    }
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _zoomMode) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(_index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(_index + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onWheel(PointerSignalEvent event) {
    if (!_desktop || _zoomMode || event is! PointerScrollEvent) return;
    final now = DateTime.now();
    if (_lastWheel != null &&
        now.difference(_lastWheel!) < const Duration(milliseconds: 280)) {
      return;
    }
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    _lastWheel = now;
    _go(delta > 0 ? _index + 1 : _index - 1);
  }

  void _clearStatusLater() {
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _status = null);
    });
  }

  Future<void> _save() async {
    if (_saving || _saved.contains(_index)) return;
    final savingIndex = _index;
    setState(() {
      _saving = true;
      _status = 'Downloading and saving picture…';
    });
    try {
      final image = await _images[savingIndex];
      final result = await MediaSaveService.saveImage(
        bytes: image.bytes,
        name: image.name,
        mimeType: image.mimeType,
      );
      if (!mounted) return;
      setState(() {
        if (result != null) _saved.add(savingIndex);
        _status = result?.message ?? 'Save canceled.';
      });
      _clearStatusLater();
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'The picture could not be saved.');
      _clearStatusLater();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _page(int index) {
    return FutureBuilder<SwipeableGalleryImage>(
      future: _images[index],
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image != null) {
          final picture = Center(
            child: Image.memory(
              image.bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          );
          if (_zoomMode && index == _index) {
            return InteractiveViewer(minScale: 1, maxScale: 5, child: picture);
          }
          return picture;
        }
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Picture unavailable',
              style: TextStyle(color: Colors.white),
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final saved = _saved.contains(_index);
    final controlStyle = IconButton.styleFrom(
      backgroundColor: colors.primaryContainer,
      foregroundColor: colors.onPrimaryContainer,
    );

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerSignal: _onWheel,
                child: ScrollConfiguration(
                  behavior: const _GalleryScrollBehavior(),
                  child: PageView.builder(
                    key: const ValueKey('swipeable-gallery-page-view'),
                    controller: _controller,
                    physics: _zoomMode
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    itemCount: _images.length,
                    onPageChanged: (index) {
                      setState(() {
                        _index = index;
                        _zoomMode = false;
                        _status = null;
                      });
                    },
                    itemBuilder: (context, index) => _page(index),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    IconButton.filled(
                      onPressed: () => Navigator.pop(context),
                      style: controlStyle,
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                    ),
                    Expanded(
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Text(
                              '${_index + 1} of ${_images.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton.filled(
                      onPressed: () {
                        setState(() => _zoomMode = !_zoomMode);
                      },
                      style: controlStyle,
                      icon: Icon(
                        _zoomMode ? Icons.zoom_out_map : Icons.zoom_in,
                      ),
                      tooltip: _zoomMode ? 'Exit zoom' : 'Enable zoom',
                    ),
                    const SizedBox(width: 6),
                    IconButton.filled(
                      onPressed: _saving || saved ? null : _save,
                      style: controlStyle,
                      icon: saved
                          ? const Icon(Icons.check)
                          : _saving
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      tooltip: saved ? 'Picture saved' : 'Save picture',
                    ),
                  ],
                ),
              ),
            ),
            if (_desktop && _index > 0)
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filled(
                    onPressed: _zoomMode ? null : () => _go(_index - 1),
                    style: controlStyle,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: 'Previous picture',
                  ),
                ),
              ),
            if (_desktop && _index < _images.length - 1)
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filled(
                    onPressed: _zoomMode ? null : () => _go(_index + 1),
                    style: controlStyle,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: 'Next picture',
                  ),
                ),
              ),
            if (_status != null)
              Positioned(
                left: 24,
                right: 24,
                bottom: 20,
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: Material(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        child: Text(_status!),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GalleryScrollBehavior extends MaterialScrollBehavior {
  const _GalleryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };
}
