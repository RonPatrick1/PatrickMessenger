import 'package:flutter/material.dart';

class LiamIcon extends StatelessWidget {
  static const assetName = 'assets/images/liam.png';

  final double size;

  const LiamIcon({this.size = 28, super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: Image.asset(
            assetName,
            width: size,
            height: size,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            semanticLabel: 'Liam',
          ),
        ),
      ),
    );
  }
}
