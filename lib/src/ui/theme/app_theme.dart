import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 根据统一 Design Token 构建 Android 与 iOS 共用的 Material 3 主题。
abstract final class AppTheme {
  /// 创建应用亮色主题。
  static ThemeData light() {
    return _build(ColorToken.lightScheme());
  }

  /// 创建应用深色主题。
  static ThemeData dark() {
    return _build(ColorToken.darkScheme());
  }

  /// 使用指定颜色方案组装共享主题规则。
  static ThemeData _build(ColorScheme colorScheme) {
    /// Material 3 提供的基础主题，后续 Token 在此基础上收敛视觉差异。
    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
    );
    return base.copyWith(
      textTheme: TypographyToken.textTheme(base.textTheme),
      scaffoldBackgroundColor: colorScheme.surface,
      cardTheme: CardThemeData(
        elevation: ElevationToken.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
        ),
      ),
    );
  }
}
