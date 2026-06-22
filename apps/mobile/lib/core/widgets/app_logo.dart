import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum AppLogoVariant { mark, icon, horizontal }

class AppLogo extends StatelessWidget {
  const AppLogo({
    this.size = 72,
    this.variant = AppLogoVariant.mark,
    super.key,
  });

  final double size;
  final AppLogoVariant variant;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final asset = switch (variant) {
      AppLogoVariant.icon => 'assets/branding/terraleb_icon.svg',
      AppLogoVariant.horizontal => brightness == Brightness.dark
          ? 'assets/branding/terraleb_horizontal_dark.svg'
          : 'assets/branding/terraleb_horizontal_light.svg',
      AppLogoVariant.mark => brightness == Brightness.dark
          ? 'assets/branding/terraleb_mark_dark.svg'
          : 'assets/branding/terraleb_mark_light.svg',
    };
    final isHorizontal = variant == AppLogoVariant.horizontal;
    return SvgPicture.asset(
      asset,
      width: isHorizontal ? size * 3.5 : size,
      height: size,
      semanticsLabel: 'TerraLeb logo',
    );
  }
}
