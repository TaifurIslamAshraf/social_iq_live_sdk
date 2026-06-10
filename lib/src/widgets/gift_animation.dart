import 'dart:math';
import 'package:flutter/material.dart';
import '../models/live_config.dart';
import '../theme/sdk_theme.dart';

/// Floating gift animation — shows gift emojis rising and fading, with a small
/// sender/label chip. Mirrors [ReactionAnimation] but richer (gifts cost coins).
class GiftAnimation extends StatelessWidget {
  final List<LiveGift> gifts;

  const GiftAnimation({super.key, required this.gifts});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      height: 320,
      child: Stack(
        children: gifts
            .map((g) => _FloatingGift(
                  key: ValueKey(
                      '${g.userId}_${g.timestamp.microsecondsSinceEpoch}'),
                  gift: g,
                ))
            .toList(),
      ),
    );
  }
}

class _FloatingGift extends StatefulWidget {
  final LiveGift gift;
  const _FloatingGift({super.key, required this.gift});

  @override
  State<_FloatingGift> createState() => _FloatingGiftState();
}

class _FloatingGiftState extends State<_FloatingGift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _position;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  late final double _horizontalOffset;

  @override
  void initState() {
    super.initState();
    final random = Random();
    _horizontalOffset = random.nextDouble() * 40 - 20;

    _controller = AnimationController(
      duration: Duration(milliseconds: 3000 + random.nextInt(800)),
      vsync: this,
    );
    _position = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.7, 1.0, curve: Curves.easeIn),
      ),
    );
    _scale = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.35, curve: Curves.elasticOut),
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
    final g = widget.gift;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          bottom: _position.value * 290,
          left: 60 + _horizontalOffset * sin(_position.value * pi * 2),
          child: Opacity(
            opacity: _opacity.value,
            child: Transform.scale(scale: _scale.value, child: child),
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(g.emoji, style: const TextStyle(fontSize: 40)),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(SdkTheme.radiusXL),
            ),
            child: Text(
              g.userName == null ? g.label : '${g.userName} · ${g.label}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ),
          if (g.healthGained > 0) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(SdkTheme.radiusXL),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.favorite, color: Colors.white, size: 11),
                  const SizedBox(width: 3),
                  Text(
                    '+${g.healthGained} health',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Bottom-sheet gift picker. Returns the chosen [GiftType] via [onSelect].
/// Show with [showGiftPicker].
class GiftPickerSheet extends StatelessWidget {
  final List<GiftType> catalog;
  final ValueChanged<GiftType> onSelect;

  const GiftPickerSheet({
    super.key,
    required this.catalog,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Send a gift',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.95,
              children: catalog.map((g) {
                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).pop();
                    onSelect(g);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(g.emoji, style: const TextStyle(fontSize: 32)),
                        const SizedBox(height: 6),
                        Text(g.label,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.monetization_on,
                                color: Colors.amber, size: 13),
                            const SizedBox(width: 3),
                            Text('${g.coin}',
                                style: const TextStyle(
                                    color: Colors.amber,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Convenience: open the gift picker as a modal bottom sheet.
Future<void> showGiftPicker({
  required BuildContext context,
  required List<GiftType> catalog,
  required ValueChanged<GiftType> onSelect,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => GiftPickerSheet(catalog: catalog, onSelect: onSelect),
  );
}
