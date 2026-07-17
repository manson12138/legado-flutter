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
      appBarTheme: AppBarTheme(
        elevation: ElevationToken.none,
        scrolledUnderElevation: ElevationToken.none,
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 48,
        titleTextStyle: TypographyToken.textTheme(base.textTheme).titleLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: ElevationToken.none,
        color: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.symmetric(vertical: 3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
          side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SpacingToken.medium,
          vertical: SpacingToken.small,
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
          borderSide: BorderSide(color: colorScheme.primary, width: 1),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minLeadingWidth: 28,
        minVerticalPadding: 6,
        horizontalTitleGap: SpacingToken.small,
        contentPadding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
        titleTextStyle: TypographyToken.textTheme(base.textTheme).bodyLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
        subtitleTextStyle: TypographyToken.textTheme(base.textTheme).bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        labelStyle: TypographyToken.textTheme(base.textTheme).labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: SpacingToken.small),
        labelPadding: const EdgeInsets.symmetric(horizontal: SpacingToken.xSmall),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(RadiusToken.small)),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.65)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: ElevationToken.none,
        height: 52,
        backgroundColor: colorScheme.surfaceContainer,
        indicatorColor: colorScheme.secondaryContainer,
        labelTextStyle: const WidgetStatePropertyAll<TextStyle?>(
          TextStyle(fontSize: 8, height: 1.1, letterSpacing: 0),
        ),
        iconTheme: const WidgetStatePropertyAll<IconThemeData>(IconThemeData(size: 20)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        elevation: ElevationToken.none,
        backgroundColor: colorScheme.surfaceContainer,
        indicatorColor: colorScheme.secondaryContainer,
        useIndicator: true,
        minWidth: 56,
        minExtendedWidth: 176,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(RadiusToken.sheet)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RadiusToken.large),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: ElevationToken.none,
        highlightElevation: ElevationToken.card,
        extendedPadding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(LayoutToken.minimumTouchTarget, LayoutToken.minimumTouchTarget),
          iconSize: 22,
          padding: const EdgeInsets.all(SpacingToken.small),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, LayoutToken.minimumTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(RadiusToken.medium)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, LayoutToken.minimumTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: SpacingToken.small),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RadiusToken.medium),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),
    );
  }
}
