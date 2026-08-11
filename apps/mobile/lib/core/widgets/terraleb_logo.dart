import 'package:flutter/material.dart';

class TerraLebLogo extends StatefulWidget {
  const TerraLebLogo({
    this.width = 280,
    this.height = 112,
    this.brightness,
    this.padding = const EdgeInsets.all(6),
    this.semanticLabel = 'TerraLeb logo',
    super.key,
  });

  static const String lightAsset = 'assets/branding/terraleb_logo_light.png';
  static const String darkAsset = 'assets/branding/terraleb_logo_dark.png';

  final double width;
  final double height;
  final Brightness? brightness;
  final EdgeInsetsGeometry padding;
  final String semanticLabel;

  @override
  State<TerraLebLogo> createState() => _TerraLebLogoState();
}

class _TerraLebLogoState extends State<TerraLebLogo> {
  bool _assetsPrecached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_assetsPrecached) {
      return;
    }
    _assetsPrecached = true;
    precacheImage(const AssetImage(TerraLebLogo.lightAsset), context);
    precacheImage(const AssetImage(TerraLebLogo.darkAsset), context);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBrightness =
        widget.brightness ?? Theme.of(context).brightness;
    final asset = effectiveBrightness == Brightness.dark
        ? TerraLebLogo.darkAsset
        : TerraLebLogo.lightAsset;

    return Semantics(
      image: true,
      label: widget.semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: Padding(
            padding: widget.padding,
            child: Image.asset(
              asset,
              key: ValueKey<String>(asset),
              fit: BoxFit.contain,
              alignment: Alignment.center,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}
