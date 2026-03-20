import 'dart:math';
import 'package:flutter/material.dart';
import '../models/live_config.dart';
import '../theme/sdk_theme.dart';

/// Floating reaction animation widget.
/// Shows emoji reactions floating upward with random paths.
class ReactionAnimation extends StatelessWidget {
  final List<LiveReaction> reactions;
  final VoidCallback? onReactionComplete;

  const ReactionAnimation({
    super.key,
    required this.reactions,
    this.onReactionComplete,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 80,
      height: 300,
      child: Stack(
        children: reactions
            .map((r) => _FloatingEmoji(
                  key: ValueKey('${r.userId}_${r.timestamp.millisecondsSinceEpoch}'),
                  emoji: r.emoji,
                ))
            .toList(),
      ),
    );
  }
}

class _FloatingEmoji extends StatefulWidget {
  final String emoji;

  const _FloatingEmoji({super.key, required this.emoji});

  @override
  State<_FloatingEmoji> createState() => _FloatingEmojiState();
}

class _FloatingEmojiState extends State<_FloatingEmoji>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _positionAnimation;
  late Animation<double> _opacityAnimation;
  late Animation<double> _scaleAnimation;
  late double _horizontalOffset;

  @override
  void initState() {
    super.initState();
    final random = Random();
    _horizontalOffset = random.nextDouble() * 60 - 30;

    _controller = AnimationController(
      duration: Duration(milliseconds: 2000 + random.nextInt(1000)),
      vsync: this,
    );

    _positionAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.6, 1.0, curve: Curves.easeIn),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.2).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.3, curve: Curves.elasticOut),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          bottom: _positionAnimation.value * 280,
          left: 30 +
              _horizontalOffset *
                  sin(_positionAnimation.value * pi * 2),
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: Transform.scale(
              scale: _scaleAnimation.value,
              child: Text(
                widget.emoji,
                style: const TextStyle(fontSize: 28),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reaction button bar for live streams.
class ReactionBar extends StatelessWidget {
  final ValueChanged<String> onReaction;

  static const List<String> defaultEmojis = ['❤️', '🔥', '😂', '😍', '👏', '🎉'];

  const ReactionBar({super.key, required this.onReaction});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SdkTheme.radiusXL),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: defaultEmojis.map((emoji) {
          return GestureDetector(
            onTap: () => onReaction(emoji),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(emoji, style: const TextStyle(fontSize: 24)),
            ),
          );
        }).toList(),
      ),
    );
  }
}
