import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/config/app_env.dart';
import '../../../../core/constants/design_tokens.dart';
import '../../../../core/widgets/app_card.dart';

class FeaturePhotoGalleryItem {
  const FeaturePhotoGalleryItem({
    required this.id,
    required this.imagePath,
    required this.label,
    this.imageBytes,
    this.loadImageBytes,
    this.subtitle,
    this.isLocalFile = false,
    this.onRemove,
  });

  final String id;
  final String imagePath;
  final String label;
  final List<int>? imageBytes;
  final Future<List<int>> Function()? loadImageBytes;
  final String? subtitle;
  final bool isLocalFile;
  final VoidCallback? onRemove;
}

ImageProvider<Object>? featurePhotoImageProvider(
  FeaturePhotoGalleryItem item, {
  Map<String, String> httpHeaders = const <String, String>{},
}) {
  final bytes = item.imageBytes;
  if (bytes != null && bytes.isNotEmpty) {
    return MemoryImage(Uint8List.fromList(bytes));
  }

  if (item.imagePath.trim().isEmpty) {
    return null;
  }

  if (item.isLocalFile) {
    if (kIsWeb) {
      return null;
    }
    return FileImage(File(item.imagePath));
  }

  final raw = item.imagePath.trim();
  final uri = Uri.tryParse(raw);
  final resolvedUrl = uri != null && uri.hasScheme
      ? raw
      : '${AppEnv.apiBaseUrl}${raw.startsWith('/') ? raw : '/$raw'}';
  return NetworkImage(resolvedUrl, headers: httpHeaders);
}

class FeaturePhotoGallery extends StatelessWidget {
  const FeaturePhotoGallery({
    required this.items,
    this.httpHeaders = const <String, String>{},
    super.key,
  });

  final List<FeaturePhotoGalleryItem> items;
  final Map<String, String> httpHeaders;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 156,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final item = items[index];
          return SizedBox(
            width: 160,
            child: AppCard(
              padding: EdgeInsets.zero,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => _FeaturePhotoViewerScreen(
                    items: items,
                    initialIndex: index,
                    httpHeaders: httpHeaders,
                  ),
                ),
              ),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(14),
                          ),
                          child: ColoredBox(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: _PhotoImage(
                              item: item,
                              httpHeaders: httpHeaders,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (item.subtitle?.trim().isNotEmpty == true) ...[
                              const SizedBox(height: 4),
                              Text(
                                item.subtitle!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (item.onRemove != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: item.onRemove,
                          icon: const Icon(Icons.close, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PhotoImage extends StatefulWidget {
  const _PhotoImage({
    required this.item,
    required this.httpHeaders,
    this.fit = BoxFit.cover,
  });

  final FeaturePhotoGalleryItem item;
  final Map<String, String> httpHeaders;
  final BoxFit fit;

  @override
  State<_PhotoImage> createState() => _PhotoImageState();
}

class _PhotoImageState extends State<_PhotoImage> {
  Future<List<int>>? _protectedBytes;

  @override
  void initState() {
    super.initState();
    _refreshProtectedBytes();
  }

  @override
  void didUpdateWidget(covariant _PhotoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.imagePath != widget.item.imagePath ||
        oldWidget.item.loadImageBytes != widget.item.loadImageBytes) {
      _refreshProtectedBytes();
    }
  }

  void _refreshProtectedBytes() {
    _protectedBytes =
        widget.item.imageBytes == null && widget.item.loadImageBytes != null
        ? widget.item.loadImageBytes!()
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final protectedBytes = _protectedBytes;
    if (protectedBytes != null) {
      return FutureBuilder<List<int>>(
        future: protectedBytes,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final bytes = snapshot.data;
          if (snapshot.hasError || bytes == null || bytes.isEmpty) {
            return const Center(child: Icon(Icons.broken_image_outlined));
          }
          return Image.memory(
            Uint8List.fromList(bytes),
            fit: widget.fit,
            width: double.infinity,
            errorBuilder: (_, _, _) =>
                const Center(child: Icon(Icons.broken_image_outlined)),
          );
        },
      );
    }

    final provider = featurePhotoImageProvider(
      widget.item,
      httpHeaders: widget.httpHeaders,
    );
    if (provider == null) {
      return const Center(child: Icon(Icons.photo_outlined, size: 32));
    }

    return Image(
      image: provider,
      fit: widget.fit,
      width: double.infinity,
      errorBuilder: (_, _, _) =>
          const Center(child: Icon(Icons.broken_image_outlined, size: 32)),
      loadingBuilder: (context, child, progress) {
        if (progress == null) {
          return child;
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}

class _FeaturePhotoViewerScreen extends StatefulWidget {
  const _FeaturePhotoViewerScreen({
    required this.items,
    required this.initialIndex,
    required this.httpHeaders,
  });

  final List<FeaturePhotoGalleryItem> items;
  final int initialIndex;
  final Map<String, String> httpHeaders;

  @override
  State<_FeaturePhotoViewerScreen> createState() =>
      _FeaturePhotoViewerScreenState();
}

class _FeaturePhotoViewerScreenState extends State<_FeaturePhotoViewerScreen> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _currentIndex = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items[_currentIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_currentIndex + 1} / ${widget.items.length}'),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.items.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) => InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: _PhotoImage(
                    item: widget.items[index],
                    httpHeaders: widget.httpHeaders,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                Text(
                  currentItem.label,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                if (currentItem.subtitle?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    currentItem.subtitle!,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
