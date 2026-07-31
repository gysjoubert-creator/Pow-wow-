import 'package:flutter/material.dart';

abstract class AppColors {
  static const Color orangeBg = Color(0xFFF06D53);
  static const Color orangeBg2 = Color(0xFFF16B5D);
  static const Color orangeBg3 = Color(0xFFFB923C);
  static const Color redBg = Color(0xFFFF6B6B);
  static const Color redBg2 = Color(0xFFF5DCD0);
  static const Color greyBg = Color(0xFFE1DDD1);
  static const Color greyBg2 = Color(0xFFF1F5F9);
  static const Color greyBg3 = Color(0xFFE2E8F0);
  static const Color greyBg4 = Color(0xFFCBD5E1);
  static const Color blueBg = Color(0xFF38BDF8);
  static const Color tealBg = Color(0xFF47A49D);
  static const Color whiteBg = Color(0xFFFDFCFB);
  static const Color whiteBg2 = Color(0xFFFAF9F6);
  static const Color greenBg = Color(0xFF2DD4BF);
  static const Color greenBg2 = Color(0xFFC0DBC0);
  static const Color violetBg = Color(0xFFA855F7);
  static const Color blackText = Color(0xFF0F172A);
  static const Color blackText2 = Color(0xFF1E293B);
  static const Color blackText3 = Color(0xFF475569);
  static const Color blackText4 = Color(0xFF334155);

  static const Color whiteText = Color(0xFFFFFFFF);
  static const Color greenText = Color(0xFF4C898A);
  static const Color greyText = Color(0xFF64748B);
  static const Color greyText2 = Color(0xFF94A3B8);
}

abstract class AppTextStyle {
  static const _fontSize = 16.0;
  static const _fontColor = AppColors.blackText;

  /// fontSize: 16, w400, color: blackText (#0F172A)
  static const mainRegular = TextStyle(
    fontWeight: AppFontWeight.regular,
    fontSize: _fontSize,
    color: _fontColor,
  );

  /// fontSize: 16, w700, color: blackText (#0F172A)
  static const mainBold = TextStyle(
    fontWeight: AppFontWeight.bold,
    fontSize: _fontSize,
    color: _fontColor,
  );

  /// fontSize: 16, w600, color: blackText (#0F172A)
  static const mainSemibold = TextStyle(
    fontWeight: AppFontWeight.semibold,
    fontSize: _fontSize,
    color: _fontColor,
  );
}

abstract class AppFontWeight {
  static const FontWeight regular = FontWeight.w400;
  static const FontWeight semibold = FontWeight.w600;
  static const FontWeight bold = FontWeight.w700;
}
