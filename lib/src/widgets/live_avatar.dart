import 'package:flutter/material.dart';
import '../theme/sdk_theme.dart';

/// Circular avatar that shows the user's photo when available and gracefully
/// falls back to the initial letter when the URL is null/empty/blank OR the
/// image fails to load (e.g. a 404).
///
/// The old inline pattern (`url != null ? NetworkImage(url!) : null`) treated an
/// empty string `""` as a valid URL — producing a blank circle and a broken
/// `NetworkImage("")` for every user without a profile picture. This widget
/// fixes that everywhere it's used.
class LiveAvatar extends StatefulWidget {
  final String? imageUrl;
  final String name;
  final double radius;
  final Color? backgroundColor;
  final double? fontSize;

  const LiveAvatar({
    super.key,
    required this.imageUrl,
    required this.name,
    this.radius = 14,
    this.backgroundColor,
    this.fontSize,
  });

  @override
  State<LiveAvatar> createState() => _LiveAvatarState();
}

class _LiveAvatarState extends State<LiveAvatar> {
  bool _failed = false;

  bool get _hasImage =>
      !_failed &&
      widget.imageUrl != null &&
      widget.imageUrl!.trim().isNotEmpty;

  @override
  void didUpdateWidget(LiveAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retry if the URL changed (e.g. a recycled list row showing a new user).
    if (oldWidget.imageUrl != widget.imageUrl) _failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = widget.name.trim();
    final initial = trimmed.isNotEmpty ? trimmed[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor:
          widget.backgroundColor ?? SdkTheme.primaryPink.withValues(alpha: 0.3),
      backgroundImage:
          _hasImage ? NetworkImage(widget.imageUrl!.trim()) : null,
      onBackgroundImageError: _hasImage
          ? (_, _) {
              if (mounted) setState(() => _failed = true);
            }
          : null,
      child: _hasImage
          ? null
          : Text(
              initial,
              style: TextStyle(
                color: Colors.white,
                fontSize: widget.fontSize ?? widget.radius * 0.8,
                fontWeight: FontWeight.bold,
              ),
            ),
    );
  }
}
