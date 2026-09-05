import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../domain/app_tile_provider.dart';
import '../../domain/lebanon_map.dart';

class BasemapAttribution extends ConsumerWidget {
  const BasemapAttribution({
    required this.style,
    this.bottomInset = 0,
    super.key,
  }) : assert(bottomInset >= 0);

  final LebanonBasemapStyle style;
  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = style == LebanonBasemapStyle.satellite
        ? ref.watch(mapProviderConfigurationProvider).valueOrNull
        : null;
    final exactAttribution =
        provider?.hybridAttribution ?? LebanonMapConfig.attributionText(style);
    return ValueListenableBuilder<MapProviderAvailability>(
      valueListenable: mapProviderAvailability,
      builder: (context, availability, _) {
        final degraded =
            style == LebanonBasemapStyle.satellite &&
            availability == MapProviderAvailability.degraded;
        return SafeArea(
          minimum: EdgeInsets.fromLTRB(4, 4, 4, 4 + bottomInset),
          child: Align(
            alignment: Alignment.bottomRight,
            child: Tooltip(
              message: degraded
                  ? 'Satellite unavailable. Street map shown. $exactAttribution'
                  : exactAttribution,
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
                child: InkWell(
                  onTap: () =>
                      context.push(AppRoutes.legalDocument('open-source')),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      degraded
                          ? 'Satellite unavailable · Street shown'
                          : LebanonMapConfig.compactAttributionText(style),
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
      },
    );
  }
}
