import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_paths.dart';
import '../../domain/lebanon_map.dart';

class BasemapAttribution extends StatelessWidget {
  const BasemapAttribution({
    required this.style,
    this.bottomInset = 0,
    super.key,
  }) : assert(bottomInset >= 0);

  final LebanonBasemapStyle style;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: EdgeInsets.fromLTRB(4, 4, 4, 4 + bottomInset),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Tooltip(
          message: LebanonMapConfig.attributionText(style),
          child: Material(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: () => context.push(AppRoutes.legalDocument('open-source')),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  LebanonMapConfig.compactAttributionText(style),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
