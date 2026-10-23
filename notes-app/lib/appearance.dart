import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The colours of an always-dark [Palette], beside its seed, which is used
/// as is for its primary colour rather than toned down.
typedef _Neon = ({Color background, Color secondary, Color tertiary});

/// A built-in colour scheme the app can be shown in, generated from [seed]
/// for both light and dark mode, or, for the neon ones, always dark.
enum Palette {
  honey('Honey', Color(0xFFF2B33D)),
  ocean('Ocean', Color(0xFF2E7DD7)),
  forest('Forest', Color(0xFF3F8F4F)),
  berry('Berry', Color(0xFFB0306A)),
  lavender('Lavender', Color(0xFF7E57C2)),
  slate('Slate', Color(0xFF607D8B)),
  grid('Grid', Color(0xFF00E5FF), (
    background: Color(0xFF02070B),
    secondary: Color(0xFFFF9E1B),
    tertiary: Color(0xFF7DF9FF),
  )),
  neon('Neon', Color(0xFFFF2BD6), (
    background: Color(0xFF0B0118),
    secondary: Color(0xFF00F0FF),
    tertiary: Color(0xFFFCEE0A),
  )),
  terminal('Terminal', Color(0xFF39FF14), (
    background: Color(0xFF010801),
    secondary: Color(0xFF00FF9C),
    tertiary: Color(0xFFB6FF00),
  ));

  const Palette(this.label, this.seed, [this._neon]);

  final String label;
  final Color seed;
  final _Neon? _neon;

  static const fallback = honey;

  /// Whether this is dark even when the device is in light mode.
  bool get alwaysDark => _neon != null;

  ThemeData theme(Brightness brightness) => switch (_neon) {
    null => ThemeData(
      colorSchemeSeed: seed,
      brightness: brightness,
      useMaterial3: true,
    ),
    final neon => _neonTheme(neon),
  };

  /// Glowing [seed] lines and text on a near-black [_Neon.background]
  /// faintly tinted with it.
  ThemeData _neonTheme(_Neon neon) {
    final bg = neon.background;
    Color tint(double t) => Color.lerp(bg, seed, t)!;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          primary: seed,
          onPrimary: Colors.black,
          primaryContainer: tint(0.18),
          onPrimaryContainer: seed,
          secondary: neon.secondary,
          onSecondary: Colors.black,
          secondaryContainer: Color.lerp(bg, neon.secondary, 0.18),
          onSecondaryContainer: neon.secondary,
          tertiary: neon.tertiary,
          onTertiary: Colors.black,
          surface: bg,
          onSurface: Color.lerp(Colors.white, seed, 0.15),
          onSurfaceVariant: Color.lerp(Colors.white, seed, 0.45),
          surfaceDim: bg,
          surfaceBright: tint(0.14),
          surfaceContainerLowest: Color.lerp(bg, Colors.black, 0.5),
          surfaceContainerLow: tint(0.04),
          surfaceContainer: tint(0.06),
          surfaceContainerHigh: tint(0.09),
          surfaceContainerHighest: tint(0.12),
          outline: seed.withValues(alpha: 0.7),
          outlineVariant: seed.withValues(alpha: 0.3),
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // Cards outlined in the neon colour, with its glow for a shadow.
      cardTheme: CardThemeData(
        elevation: 3,
        shadowColor: seed.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: seed.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}

/// The [Palette] the user picked, kept in SharedPreferences so it lasts
/// between runs. It's this device's choice, whoever is logged in.
class Appearance extends ValueNotifier<Palette> {
  Appearance(this._prefs) : super(_saved(_prefs));

  final SharedPreferences _prefs;

  static const _paletteKey = 'appearance_palette_v1';

  /// The saved palette, or [Palette.fallback] if there's none or it's one
  /// this version doesn't have.
  static Palette _saved(SharedPreferences prefs) {
    final name = prefs.getString(_paletteKey);
    return Palette.values.where((p) => p.name == name).firstOrNull ??
        Palette.fallback;
  }

  Future<void> pick(Palette palette) async {
    value = palette;
    await _prefs.setString(_paletteKey, palette.name);
  }
}

/// Makes an [Appearance] available to the widgets below, rebuilding those
/// that look it up when the palette changes.
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({
    super.key,
    required Appearance appearance,
    required super.child,
  }) : super(notifier: appearance);

  /// The nearest [Appearance], or null when there's none, e.g. in tests.
  static Appearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;

  /// The palette to show, [Palette.fallback] when there's no [Appearance].
  static Palette paletteOf(BuildContext context) =>
      maybeOf(context)?.value ?? Palette.fallback;
}
