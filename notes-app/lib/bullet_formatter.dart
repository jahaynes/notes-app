import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const bullet = '•';

/// Turns `* ` or `*word ` (or `*word` and Enter) at the start of a line into
/// a bullet, carries the bullet (and its indentation) onto the next line on
/// Enter, and removes it on Enter from an empty bullet line. Backspace just
/// after a bullet does as [outdentBullets].
///
/// Backspace straight after a conversion undoes it instead, so this
/// remembers the last one: keep one instance across rebuilds. Only
/// single-character insertions and deletions are touched, so pasted text and
/// larger edits pass through unchanged. Undo and redo go through formatters
/// too, and can be single characters, so give the field [undoActions], and
/// call [unformatted] around any undo or redo done otherwise.
class BulletFormatter extends TextInputFormatter {
  /// The value just after the last conversion to a bullet, and the value it
  /// replaced, until the next edit.
  TextEditingValue? _converted;
  TextEditingValue? _unconverted;

  /// Whether edits pass through untouched, while undoing or redoing.
  bool _off = false;

  /// Actions for an [Actions] around the field, so that undo and redo put
  /// back the text as it was, rather than it being formatted as if typed:
  /// undoing a deleted newline after a bullet would otherwise add another.
  late final Map<Type, Action<Intent>> undoActions = {
    UndoTextIntent: _Unformatted<UndoTextIntent>(this),
    RedoTextIntent: _Unformatted<RedoTextIntent>(this),
  };

  /// Runs [edit], such as an undo or redo, with formatting off.
  R unformatted<R>(R Function() edit) {
    _off = true;
    try {
      return edit();
    } finally {
      _off = false;
    }
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final converted = _converted;
    final unconverted = _unconverted;
    _converted = _unconverted = null;
    if (_off) return newValue;
    final cursor = newValue.selection;
    if (!cursor.isCollapsed || cursor.baseOffset < 0) return newValue;
    if (_isBackspace(oldValue, newValue)) {
      if (unconverted != null &&
          converted!.text == oldValue.text &&
          converted.selection == oldValue.selection) {
        return unconverted;
      }
      return _backspace(oldValue) ?? newValue;
    }
    final pos = cursor.baseOffset;
    final text = newValue.text;
    if (pos < 1 ||
        pos > text.length ||
        text.length != oldValue.text.length + 1 ||
        text.replaceRange(pos - 1, pos, '') != oldValue.text) {
      return newValue;
    }

    final typed = text[pos - 1];
    final lineStart = _lineStart(text, pos - 1);

    if (typed == ' ') {
      final converted = _starToBullet(
        newValue,
        lineStart,
        pos - 1,
        spaceTyped: true,
      );
      if (converted == null) return newValue;
      _unconverted = newValue;
      return _converted = converted;
    }

    if (typed == '\n') {
      final converted = _starToBullet(
        newValue,
        lineStart,
        pos - 1,
        needsWord: true,
      );
      return _newline(converted ?? newValue, lineStart);
    }

    return newValue;
  }

  /// Carries a bullet onto the line just started at the cursor in [value], or
  /// ends the list if the bullet's line, starting at [lineStart], is empty.
  TextEditingValue _newline(TextEditingValue value, int lineStart) {
    final text = value.text;
    final pos = value.selection.baseOffset;
    final prefixEnd = _prefixEnd(text, lineStart);
    if (prefixEnd == null || prefixEnd > pos - 1) return value;
    final nextNewline = text.indexOf('\n', pos);
    final rest = text.substring(pos, nextNewline == -1 ? null : nextNewline);
    if (text.substring(prefixEnd, pos - 1).trim().isEmpty &&
        rest.trim().isEmpty) {
      // Enter on an empty bullet ends the list.
      return _replace(value, lineStart, pos, '', lineStart);
    }
    final prefix = text.substring(lineStart, prefixEnd);
    return _replace(value, pos, pos, prefix, pos + prefix.length);
  }

  bool _isBackspace(TextEditingValue oldValue, TextEditingValue newValue) {
    final old = oldValue.selection;
    final pos = newValue.selection.baseOffset;
    return oldValue.text.length == newValue.text.length + 1 &&
        old.isCollapsed &&
        old.baseOffset == pos + 1 &&
        oldValue.text.replaceRange(pos, pos + 1, '') == newValue.text;
  }

  /// Backspace from just after a bullet, or null if the cursor wasn't there.
  TextEditingValue? _backspace(TextEditingValue oldValue) {
    final pos = oldValue.selection.baseOffset;
    final lineStart = _lineStart(oldValue.text, pos);
    if (_prefixEnd(oldValue.text, lineStart) != pos) return null;
    return outdentBullets(oldValue);
  }
}

/// Shortcuts for a [Shortcuts] around the field, so that undo and redo use
/// Flutter's history on the web too. There Flutter leaves them to the browser,
/// whose history is lost whenever a bullet edit replaces the text.
const bulletUndoShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyZ, control: true): UndoTextIntent(
    SelectionChangedCause.keyboard,
  ),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true): UndoTextIntent(
    SelectionChangedCause.keyboard,
  ),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
      RedoTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
      RedoTextIntent(SelectionChangedCause.keyboard),
  // As browsers on Windows have it.
  SingleActivator(LogicalKeyboardKey.keyY, control: true): RedoTextIntent(
    SelectionChangedCause.keyboard,
  ),
};

/// Does the action it overrides with [formatter] off.
class _Unformatted<T extends Intent> extends Action<T> {
  _Unformatted(this.formatter);

  final BulletFormatter formatter;

  @override
  bool isEnabled(T intent) => callingAction?.isEnabled(intent) ?? false;

  @override
  bool consumesKey(T intent) => callingAction?.consumesKey(intent) ?? false;

  @override
  Object? invoke(T intent) =>
      formatter.unformatted(() => callingAction?.invoke(intent));
}

TextEditingValue _replace(
  TextEditingValue value,
  int start,
  int end,
  String replacement,
  int cursor,
) => TextEditingValue(
  text: value.text.replaceRange(start, end, replacement),
  selection: TextSelection.collapsed(offset: cursor),
);

/// A star, then maybe a word without stars, so `*emphasis*` and `**bold**`
/// are left alone.
final _star = RegExp(r'^([ \t]*)\*([^\s*]*)$');

/// [value] with the star starting the line at [lineStart] made a bullet, if
/// the line up to [end] is a star and maybe (or with [needsWord], certainly)
/// a word. The collapsed cursor stays on the same text. With [spaceTyped], the
/// space at [end] already separates the bullet from what follows.
TextEditingValue? _starToBullet(
  TextEditingValue value,
  int lineStart,
  int end, {
  bool spaceTyped = false,
  bool needsWord = false,
}) {
  final star = _star.firstMatch(value.text.substring(lineStart, end));
  if (star == null) return null;
  final word = star[2]!.isNotEmpty;
  if (needsWord && !word) return null;
  final at = lineStart + star[1]!.length;
  final mark = spaceTyped && !word ? bullet : '$bullet ';
  final cursor = value.selection.baseOffset + mark.length - 1;
  return _replace(value, at, at + 1, mark, cursor);
}

/// The start of the line holding [offset].
int _lineStart(String text, int offset) =>
    offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

final _bulletPrefix = RegExp('[ \t]*$bullet ');

/// The end of the indentation and bullet starting the line at [lineStart], or
/// null if the line isn't a bullet.
int? _prefixEnd(String text, int lineStart) =>
    _bulletPrefix.matchAsPrefix(text, lineStart)?.end;

/// A controller that keeps a collapsed cursor out of bullets' indentation,
/// so that arrowing across it takes one step: leftwards it lands at the start
/// of the line, otherwise just after the bullet. It also draws tabs as wide
/// as [bulletIndent], since Flutter otherwise draws them a space wide.
class BulletEditingController extends TextEditingController {
  BulletEditingController({super.text});

  (TextStyle?, TextScaler)? _measuredFor;
  double _tabSpacing = 0;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final span = super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
    if (!text.contains('\t')) return span;
    // Letter spacing isn't scaled with the text, so measure at its scale.
    final scaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    if (_measuredFor != (style, scaler)) {
      _measuredFor = (style, scaler);
      _tabSpacing =
          _width(bulletIndent, style, scaler) - _width('\t', style, scaler);
    }
    return _widenTabs(span, TextStyle(letterSpacing: _tabSpacing));
  }

  static double _width(String text, TextStyle? style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// [span] with each tab in it given [tabStyle], keeping the same text.
  static TextSpan _widenTabs(TextSpan span, TextStyle tabStyle) {
    final text = span.text;
    final children = [
      if (text != null && text.contains('\t'))
        for (final (i, part) in text.split('\t').indexed) ...[
          if (i > 0) TextSpan(text: '\t', style: tabStyle),
          if (part.isNotEmpty) TextSpan(text: part),
        ]
      else if (text != null)
        TextSpan(text: text),
      for (final child in span.children ?? const <InlineSpan>[])
        child is TextSpan ? _widenTabs(child, tabStyle) : child,
    ];
    return TextSpan(
      style: span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      children: children,
    );
  }

  @override
  set value(TextEditingValue newValue) {
    super.value = _snap(value, newValue);
  }

  static TextEditingValue _snap(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final cursor = newValue.selection;
    if (!cursor.isValid || !cursor.isCollapsed) return newValue;
    if (newValue.text != oldValue.text) return newValue;
    final text = newValue.text;
    final pos = cursor.baseOffset;
    if (pos > text.length) return newValue;
    final lineStart = _lineStart(text, pos);
    final prefixEnd = _prefixEnd(text, lineStart);
    if (prefixEnd == null || pos <= lineStart || pos >= prefixEnd) {
      return newValue;
    }
    final old = oldValue.selection;
    final leftwards = old.isCollapsed && old.baseOffset == prefixEnd;
    return newValue.copyWith(
      selection: TextSelection.collapsed(
        offset: leftwards ? lineStart : prefixEnd,
      ),
    );
  }
}

/// One level of bullet indentation.
const bulletIndent = '    ';

final _levelOfSpaces = RegExp(' {1,${bulletIndent.length}}');

/// Indents every bullet line the selection touches. Before that, a star (and
/// maybe a word) from a line's start to the cursor becomes a bullet; and with
/// no bullet lines, it types a tab in place of the selection instead.
TextEditingValue indentBullets(TextEditingValue value) {
  final cursor = value.selection;
  if (cursor.isValid &&
      cursor.isCollapsed &&
      cursor.baseOffset <= value.text.length) {
    final lineStart = _lineStart(value.text, cursor.baseOffset);
    final converted = _starToBullet(value, lineStart, cursor.baseOffset);
    if (converted != null) return converted;
  }
  final edited = _editBulletLines(value, (line) => bulletIndent);
  if (edited != null) return edited;
  final selection = value.selection;
  if (!selection.isValid || selection.end > value.text.length) return value;
  return TextEditingValue(
    text: value.text.replaceRange(selection.start, selection.end, '\t'),
    selection: TextSelection.collapsed(offset: selection.start + 1),
  );
}

/// Removes one level of indentation from every bullet line the selection
/// touches, or the bullet itself from those with none. With no bullet lines,
/// it removes a level from each indented line instead, or failing that, the
/// tab just before the cursor, undoing [indentBullets] there.
TextEditingValue outdentBullets(TextEditingValue value) =>
    _editBulletLines(value, _outdentPrefix, remove: true) ??
    _editBulletLines(value, _outdentPrefix, remove: true, lines: _indented) ??
    _deleteTabBefore(value) ??
    value;

/// The prefix outdenting [line] removes.
String _outdentPrefix(String line) {
  if (line.startsWith('\t')) return '\t';
  // Up to a level of spaces, so shallower indents still line up after.
  final spaces = _levelOfSpaces.matchAsPrefix(line);
  return spaces?[0] ?? '$bullet ';
}

final _indented = RegExp('[ \t]');

/// [value] without the tab just before its collapsed cursor, or null if
/// there's none.
TextEditingValue? _deleteTabBefore(TextEditingValue value) {
  final cursor = value.selection;
  final pos = cursor.baseOffset;
  if (!cursor.isValid || !cursor.isCollapsed || pos > value.text.length) {
    return null;
  }
  if (pos < 1 || value.text[pos - 1] != '\t') return null;
  return _replace(value, pos - 1, pos, '', pos - 1);
}

/// Adds (or with [remove], strips) the prefix given by [prefixFor] at the
/// start of each bullet line (or line starting with [lines]) in the
/// selection, keeping the selection on the same text. Returns null if the
/// selection touches no such lines.
TextEditingValue? _editBulletLines(
  TextEditingValue value,
  String Function(String line) prefixFor, {
  bool remove = false,
  RegExp? lines,
}) {
  final selection = value.selection;
  final text = value.text;
  if (!selection.isValid || selection.end > text.length) return null;
  var base = selection.baseOffset;
  var extent = selection.extentOffset;
  final out = StringBuffer();
  var touched = false;

  var lineStart = _lineStart(text, selection.start);
  out.write(text.substring(0, lineStart));
  while (true) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline == -1 ? text.length : newline;
    var line = text.substring(lineStart, lineEnd);
    if ((lines ?? _bulletPrefix).matchAsPrefix(line) != null) {
      touched = true;
      final prefix = prefixFor(line);
      final at = out.length;
      if (remove) {
        line = line.substring(prefix.length);
        int shift(int o) => o - (o - at).clamp(0, prefix.length);
        base = shift(base);
        extent = shift(extent);
      } else {
        line = prefix + line;
        // A selection starting at the line start takes the new indent in.
        final collapsed = selection.isCollapsed;
        if (base > at || (collapsed && base == at)) base += prefix.length;
        if (extent > at || (collapsed && extent == at)) {
          extent += prefix.length;
        }
      }
    }
    out.write(line);
    // A selection ending at the start of a line doesn't take that line in.
    if (newline == -1 || newline + 1 >= selection.end) {
      out.write(text.substring(lineEnd));
      break;
    }
    out.write('\n');
    lineStart = newline + 1;
  }

  if (!touched) return null;
  return TextEditingValue(
    text: out.toString(),
    selection: TextSelection(baseOffset: base, extentOffset: extent),
  );
}
