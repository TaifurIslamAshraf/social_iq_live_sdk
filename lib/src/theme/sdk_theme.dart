import 'package:flutter/material.dart';

/// SDK Theme constants matching the IQ Social app design.
class SdkTheme {
  SdkTheme._();

  // Primary colors
  static const Color primaryRed = Color(0xFFFF1744);
  static const Color primaryPink = Color(0xFFFF4081);
  static const Color accentPink = Color(0xFFFF6090);

  // Background
  static const Color backgroundWhite = Color(0xFFFFFFFF);
  static const Color backgroundLight = Color(0xFFF5F5F5);
  static const Color backgroundDark = Color(0xFF1A1A2E);
  static const Color backgroundOverlay = Color(0x80000000);

  // Text
  static const Color textPrimary = Color(0xFF212121);
  static const Color textSecondary = Color(0xFF757575);
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textOnDark = Color(0xDEFFFFFF);

  // Status
  static const Color liveRed = Color(0xFFFF0000);
  static const Color onlineGreen = Color(0xFF4CAF50);
  static const Color endCallRed = Color(0xFFD32F2F);
  static const Color acceptGreen = Color(0xFF43A047);

  // Gradients
  static const LinearGradient liveGradient = LinearGradient(
    colors: [Color(0xFFFF1744), Color(0xFFFF6D00)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient callGradient = LinearGradient(
    colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient audioCallGradient = LinearGradient(
    colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Shadows
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.08),
      blurRadius: 10,
      offset: const Offset(0, 2),
    ),
  ];

  // Border Radius
  static const double radiusSmall = 8.0;
  static const double radiusMedium = 12.0;
  static const double radiusLarge = 20.0;
  static const double radiusXL = 28.0;
  static const double radiusRound = 50.0;

  // Text Styles
  static const TextStyle headingBold = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: textWhite,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: textWhite,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: textSecondary,
  );

  static const TextStyle labelBold = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textWhite,
  );

  static const TextStyle commentName = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: textWhite,
  );

  static const TextStyle commentText = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: textOnDark,
  );
}
