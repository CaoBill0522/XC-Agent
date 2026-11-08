// 由 tool 脚本按 flutter_miuix 1.3.0 的 MiuixColors 字段生成；升级 miuix 后若字段变化需重新生成。
import 'dart:ui';

import 'package:flutter_miuix/miuix.dart';

/// miuix 的配色没有提供插值，这里逐字段插值，用于主题切换动画。
MiuixColors lerpMiuixColors(
  MiuixColors a,
  MiuixColors b,
  double t,
) => MiuixColors(
  primary: Color.lerp(a.primary, b.primary, t)!,
  onPrimary: Color.lerp(a.onPrimary, b.onPrimary, t)!,
  primaryVariant: Color.lerp(a.primaryVariant, b.primaryVariant, t)!,
  onPrimaryVariant: Color.lerp(a.onPrimaryVariant, b.onPrimaryVariant, t)!,
  error: Color.lerp(a.error, b.error, t)!,
  onError: Color.lerp(a.onError, b.onError, t)!,
  errorContainer: Color.lerp(a.errorContainer, b.errorContainer, t)!,
  onErrorContainer: Color.lerp(a.onErrorContainer, b.onErrorContainer, t)!,
  disabledPrimary: Color.lerp(a.disabledPrimary, b.disabledPrimary, t)!,
  disabledOnPrimary: Color.lerp(a.disabledOnPrimary, b.disabledOnPrimary, t)!,
  disabledPrimaryButton: Color.lerp(
    a.disabledPrimaryButton,
    b.disabledPrimaryButton,
    t,
  )!,
  disabledOnPrimaryButton: Color.lerp(
    a.disabledOnPrimaryButton,
    b.disabledOnPrimaryButton,
    t,
  )!,
  disabledPrimarySlider: Color.lerp(
    a.disabledPrimarySlider,
    b.disabledPrimarySlider,
    t,
  )!,
  primaryContainer: Color.lerp(a.primaryContainer, b.primaryContainer, t)!,
  onPrimaryContainer: Color.lerp(
    a.onPrimaryContainer,
    b.onPrimaryContainer,
    t,
  )!,
  secondary: Color.lerp(a.secondary, b.secondary, t)!,
  onSecondary: Color.lerp(a.onSecondary, b.onSecondary, t)!,
  secondaryVariant: Color.lerp(a.secondaryVariant, b.secondaryVariant, t)!,
  onSecondaryVariant: Color.lerp(
    a.onSecondaryVariant,
    b.onSecondaryVariant,
    t,
  )!,
  disabledSecondary: Color.lerp(a.disabledSecondary, b.disabledSecondary, t)!,
  disabledOnSecondary: Color.lerp(
    a.disabledOnSecondary,
    b.disabledOnSecondary,
    t,
  )!,
  disabledSecondaryVariant: Color.lerp(
    a.disabledSecondaryVariant,
    b.disabledSecondaryVariant,
    t,
  )!,
  disabledOnSecondaryVariant: Color.lerp(
    a.disabledOnSecondaryVariant,
    b.disabledOnSecondaryVariant,
    t,
  )!,
  secondaryContainer: Color.lerp(
    a.secondaryContainer,
    b.secondaryContainer,
    t,
  )!,
  onSecondaryContainer: Color.lerp(
    a.onSecondaryContainer,
    b.onSecondaryContainer,
    t,
  )!,
  secondaryContainerVariant: Color.lerp(
    a.secondaryContainerVariant,
    b.secondaryContainerVariant,
    t,
  )!,
  onSecondaryContainerVariant: Color.lerp(
    a.onSecondaryContainerVariant,
    b.onSecondaryContainerVariant,
    t,
  )!,
  tertiaryContainer: Color.lerp(a.tertiaryContainer, b.tertiaryContainer, t)!,
  onTertiaryContainer: Color.lerp(
    a.onTertiaryContainer,
    b.onTertiaryContainer,
    t,
  )!,
  tertiaryContainerVariant: Color.lerp(
    a.tertiaryContainerVariant,
    b.tertiaryContainerVariant,
    t,
  )!,
  background: Color.lerp(a.background, b.background, t)!,
  onBackground: Color.lerp(a.onBackground, b.onBackground, t)!,
  onBackgroundVariant: Color.lerp(
    a.onBackgroundVariant,
    b.onBackgroundVariant,
    t,
  )!,
  surface: Color.lerp(a.surface, b.surface, t)!,
  onSurface: Color.lerp(a.onSurface, b.onSurface, t)!,
  surfaceVariant: Color.lerp(a.surfaceVariant, b.surfaceVariant, t)!,
  onSurfaceSecondary: Color.lerp(
    a.onSurfaceSecondary,
    b.onSurfaceSecondary,
    t,
  )!,
  onSurfaceVariantSummary: Color.lerp(
    a.onSurfaceVariantSummary,
    b.onSurfaceVariantSummary,
    t,
  )!,
  onSurfaceVariantActions: Color.lerp(
    a.onSurfaceVariantActions,
    b.onSurfaceVariantActions,
    t,
  )!,
  disabledOnSurface: Color.lerp(a.disabledOnSurface, b.disabledOnSurface, t)!,
  surfaceContainer: Color.lerp(a.surfaceContainer, b.surfaceContainer, t)!,
  onSurfaceContainer: Color.lerp(
    a.onSurfaceContainer,
    b.onSurfaceContainer,
    t,
  )!,
  onSurfaceContainerVariant: Color.lerp(
    a.onSurfaceContainerVariant,
    b.onSurfaceContainerVariant,
    t,
  )!,
  surfaceContainerHigh: Color.lerp(
    a.surfaceContainerHigh,
    b.surfaceContainerHigh,
    t,
  )!,
  onSurfaceContainerHigh: Color.lerp(
    a.onSurfaceContainerHigh,
    b.onSurfaceContainerHigh,
    t,
  )!,
  surfaceContainerHighest: Color.lerp(
    a.surfaceContainerHighest,
    b.surfaceContainerHighest,
    t,
  )!,
  onSurfaceContainerHighest: Color.lerp(
    a.onSurfaceContainerHighest,
    b.onSurfaceContainerHighest,
    t,
  )!,
  outline: Color.lerp(a.outline, b.outline, t)!,
  dividerLine: Color.lerp(a.dividerLine, b.dividerLine, t)!,
  windowDimming: Color.lerp(a.windowDimming, b.windowDimming, t)!,
  sliderKeyPoint: Color.lerp(a.sliderKeyPoint, b.sliderKeyPoint, t)!,
  sliderKeyPointForeground: Color.lerp(
    a.sliderKeyPointForeground,
    b.sliderKeyPointForeground,
    t,
  )!,
  sliderBackground: Color.lerp(a.sliderBackground, b.sliderBackground, t)!,
);
