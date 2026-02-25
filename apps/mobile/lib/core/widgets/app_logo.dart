import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({this.size = 72, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/branding/logo_placeholder.svg',
      width: size,
      height: size,
      semanticsLabel: 'Lebanon GIS Collector logo',
    );
  }
}
