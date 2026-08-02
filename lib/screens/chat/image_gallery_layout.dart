import 'package:flutter/material.dart';

typedef ImageGalleryItemBuilder =
    Widget Function(BuildContext context, int index);

class ImageGalleryLayout extends StatelessWidget {
  final int itemCount;
  final ImageGalleryItemBuilder itemBuilder;
  final ValueChanged<int>? onItemTap;

  const ImageGalleryLayout({
    required this.itemCount,
    required this.itemBuilder,
    this.onItemTap,
    super.key,
  });

  static const _spacing = 3.0;

  Widget _tile(BuildContext context, int index, {int hiddenCount = 0}) {
    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          itemBuilder(context, index),
          if (hiddenCount > 0)
            ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Text(
                  '+$hiddenCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (onItemTap == null) return tile;

    return Semantics(
      button: true,
      label: 'Open picture ${index + 1}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onItemTap!(index),
        child: tile,
      ),
    );
  }

  Widget _two(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _tile(context, 0)),
        const SizedBox(width: _spacing),
        Expanded(child: _tile(context, 1)),
      ],
    );
  }

  Widget _three(BuildContext context) {
    return Row(
      children: [
        Expanded(flex: 2, child: _tile(context, 0)),
        const SizedBox(width: _spacing),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _tile(context, 1)),
              const SizedBox(height: _spacing),
              Expanded(child: _tile(context, 2)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fourOrMore(BuildContext context) {
    final hiddenCount = itemCount - 4;

    return Row(
      children: [
        Expanded(flex: 2, child: _tile(context, 0)),
        const SizedBox(width: _spacing),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _tile(context, 1)),
              const SizedBox(height: _spacing),
              Expanded(child: _tile(context, 2)),
              const SizedBox(height: _spacing),
              Expanded(child: _tile(context, 3, hiddenCount: hiddenCount)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (itemCount <= 0) return const SizedBox.shrink();

    final aspectRatio = switch (itemCount) {
      1 => 4 / 3,
      2 => 1.65,
      3 => 1.4,
      _ => 1.45,
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: switch (itemCount) {
          1 => _tile(context, 0),
          2 => _two(context),
          3 => _three(context),
          _ => _fourOrMore(context),
        },
      ),
    );
  }
}
