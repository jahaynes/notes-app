import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteish/bullet_formatter.dart';

/// Types [char] at the end of [before] and returns the formatted text, with
/// `|` marking the cursor.
String _type(String before, String char) {
  final old = TextEditingValue(
    text: before,
    selection: TextSelection.collapsed(offset: before.length),
  );
  final typed = before + char;
  final result = BulletFormatter().formatEditUpdate(
    old,
    TextEditingValue(
      text: typed,
      selection: TextSelection.collapsed(offset: typed.length),
    ),
  );
  return result.text.replaceRange(
    result.selection.baseOffset,
    result.selection.baseOffset,
    '|',
  );
}

/// Parses [marked] into a value, with `|` marking the cursor or two `|`s
/// marking a selection.
TextEditingValue _value(String marked) {
  final start = marked.indexOf('|');
  final end = marked.indexOf('|', start + 1);
  return TextEditingValue(
    text: marked.replaceAll('|', ''),
    selection: TextSelection(
      baseOffset: start,
      extentOffset: end == -1 ? start : end - 1,
    ),
  );
}

/// Renders [value] in the same marked form as [_value] reads.
String _marked(TextEditingValue value) {
  final s = value.selection;
  if (s.isCollapsed) return value.text.replaceRange(s.start, s.start, '|');
  return value.text
      .replaceRange(s.end, s.end, '|')
      .replaceRange(s.start, s.start, '|');
}

void main() {
  test('star then space at line start becomes a bullet', () {
    expect(_type('*', ' '), '• |');
    expect(_type('intro\n  *', ' '), 'intro\n  • |');
  });

  test('star then a word at line start becomes a bullet on space', () {
    expect(_type('*milk', ' '), '• milk |');
    expect(_type('a\n  *milk', ' '), 'a\n  • milk |');
  });

  test('enter after a star and a word makes a bullet and carries it on', () {
    expect(_type('*milk', '\n'), '• milk\n• |');
    expect(_type('  *milk', '\n'), '  • milk\n  • |');
  });

  test('enter after a lone star is left alone', () {
    expect(_type('*', '\n'), '*\n|');
    expect(_type('*milk*', '\n'), '*milk*\n|');
  });

  test('emphasis and bold are left alone', () {
    expect(_type('*milk*', ' '), '*milk* |');
    expect(_type('**bold**', ' '), '**bold** |');
    expect(_type('**bold', ' '), '**bold |');
  });

  test('star elsewhere is left alone', () {
    expect(_type('a *', ' '), 'a * |');
    expect(_type('**', ' '), '** |');
  });

  test('enter continues a bullet with its indentation', () {
    expect(_type('  • milk', '\n'), '  • milk\n  • |');
  });

  test('enter on an empty bullet ends the list', () {
    expect(_type('• milk\n• ', '\n'), '• milk\n|');
  });

  test('enter before a bullet\'s text keeps the bullet on both lines', () {
    final old = _value('• |milk');
    final result = BulletFormatter().formatEditUpdate(
      old,
      const TextEditingValue(
        text: '• \nmilk',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    expect(_marked(result), '• \n• |milk');
  });

  test('enter on a plain line is left alone', () {
    expect(_type('milk', '\n'), 'milk\n|');
  });

  test('pasted text is left alone', () {
    const old = TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );
    const pasted = TextEditingValue(
      text: '* a\n',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(BulletFormatter().formatEditUpdate(old, pasted), pasted);
  });
  test('enter as the first character is left alone', () {
    expect(_type('', '\n'), '\n|');
  });

  group('indent', () {
    test('indents the bullet line holding the cursor', () {
      expect(_marked(indentBullets(_value('• mi|lk'))), '    • mi|lk');
    });

    test('indents every bullet line in the selection', () {
      expect(
        _marked(indentBullets(_value('• a\n• |b\nplain\n• c|\n• d'))),
        '• a\n    • |b\nplain\n    • c|\n• d',
      );
    });

    test('skips a line the selection ends at the start of', () {
      expect(_marked(indentBullets(_value('|• a\n|• b'))), '|    • a\n|• b');
    });

    test('ignores a selection past the end of the text', () {
      const stale = TextEditingValue(
        text: '• a',
        selection: TextSelection.collapsed(offset: 10),
      );
      expect(indentBullets(stale), stale);
      expect(outdentBullets(stale), stale);
    });

    test('turns a star, with or without a word, into a bullet', () {
      expect(_marked(indentBullets(_value('*|'))), '• |');
      expect(_marked(indentBullets(_value('a\n  *milk|'))), 'a\n  • milk|');
      expect(_marked(indentBullets(_value('*milk*|'))), '*milk*\t|');
    });

    test('types a tab off bullet lines', () {
      expect(_marked(indentBullets(_value('a|b|c'))), 'a\t|c');
      expect(_marked(indentBullets(_value('|'))), '\t|');
    });
  });

  group('outdent', () {
    test('removes one level from the bullet line', () {
      expect(_marked(outdentBullets(_value('      • mi|lk'))), '  • mi|lk');
      expect(_marked(outdentBullets(_value('  • mi|lk'))), '• mi|lk');
      expect(_marked(outdentBullets(_value('\t• |milk'))), '• |milk');
    });

    test('removes the bullet from an unindented bullet line', () {
      expect(_marked(outdentBullets(_value('a\n• mi|lk'))), 'a\nmi|lk');
      expect(_marked(outdentBullets(_value('• |milk'))), '|milk');
    });

    test('works on each line of a selection', () {
      expect(_marked(outdentBullets(_value('|    • a\n• b|'))), '|• a\nb|');
    });

    test('leaves plain lines alone', () {
      expect(_marked(outdentBullets(_value('  pl|ain'))), '  pl|ain');
    });

    test('keeps a cursor inside the removed indent on the line', () {
      expect(_marked(outdentBullets(_value(' | • a'))), '|• a');
    });
  });
  group('backspace after a bullet', () {
    /// Backspaces at the cursor in [marked] and returns the formatted result.
    String backspace(String marked) {
      final old = _value(marked);
      final pos = old.selection.baseOffset;
      return _marked(
        BulletFormatter().formatEditUpdate(
          old,
          TextEditingValue(
            text: old.text.replaceRange(pos - 1, pos, ''),
            selection: TextSelection.collapsed(offset: pos - 1),
          ),
        ),
      );
    }

    test('removes a level of indentation', () {
      expect(backspace('a\n      • |milk'), 'a\n  • |milk');
    });

    test('removes an unindented bullet', () {
      expect(backspace('a\n• |milk'), 'a\n|milk');
    });

    test('straight after a conversion gives back the star', () {
      final formatter = BulletFormatter();
      final converted = formatter.formatEditUpdate(
        _value('a\n*|'),
        _value('a\n* |'),
      );
      expect(_marked(converted), 'a\n• |');
      final undone = formatter.formatEditUpdate(converted, _value('a\n•|'));
      expect(_marked(undone), 'a\n* |');
    });

    test('straight after a word conversion gives back the star', () {
      final formatter = BulletFormatter();
      final converted = formatter.formatEditUpdate(
        _value('*milk|'),
        _value('*milk |'),
      );
      expect(_marked(converted), '• milk |');
      final undone = formatter.formatEditUpdate(converted, _value('• milk|'));
      expect(_marked(undone), '*milk |');
    });

    test('after typing past a conversion removes the bullet', () {
      final formatter = BulletFormatter();
      final converted = formatter.formatEditUpdate(_value('*|'), _value('* |'));
      final typed = formatter.formatEditUpdate(converted, _value('• x|'));
      final deleted = formatter.formatEditUpdate(typed, _value('• |'));
      expect(_marked(formatter.formatEditUpdate(deleted, _value('•|'))), '|');
    });

    test('elsewhere deletes a character as usual', () {
      expect(backspace('• mi|lk'), '• m|lk');
      expect(backspace('a |b'), 'a|b');
    });
  });

  group('cursor', () {
    late BulletEditingController controller;
    setUp(() => controller = BulletEditingController(text: 'a\n  • milk'));

    int moveTo(int offset) {
      controller.selection = TextSelection.collapsed(offset: offset);
      return controller.selection.baseOffset;
    }

    test('skips the indentation in one step each way', () {
      expect(moveTo(6), 6); // Just after the bullet.
      expect(moveTo(5), 2); // Left lands at the line start.
      expect(moveTo(3), 6); // Right jumps past the bullet.
    });

    test('lands after the bullet when placed in the indentation', () {
      expect(moveTo(0), 0);
      expect(moveTo(4), 6);
    });

    test('leaves selections alone', () {
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      expect(controller.selection.extentOffset, 4);
    });
  });
  testWidgets('tabs are drawn as wide as an indent level', (tester) async {
    final controller = BulletEditingController(text: 'a\tb');
    late TextSpan span;
    const style = TextStyle(fontSize: 16);
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          span = controller.buildTextSpan(
            context: context,
            style: style,
            withComposing: false,
          );
          return const SizedBox();
        },
      ),
    );

    expect(span.toPlainText(), 'a\tb');
    final painter = TextPainter(
      text: TextSpan(style: style, children: [span]),
      textDirection: TextDirection.ltr,
    )..layout();
    final plain = TextPainter(
      text: const TextSpan(text: 'a${bulletIndent}b', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(painter.width, closeTo(plain.width, 0.01));
  });
  testWidgets('tabs stay an indent level wide with scaled text', (
    tester,
  ) async {
    final controller = BulletEditingController(text: 'a\tb');
    const scaler = TextScaler.linear(2);
    const style = TextStyle(fontSize: 16);
    late TextSpan span;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: scaler),
        child: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: style,
              withComposing: false,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    double width(InlineSpan span) => (TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout()).width;
    expect(
      width(TextSpan(style: style, children: [span])),
      closeTo(
        width(const TextSpan(text: 'a${bulletIndent}b', style: style)),
        0.01,
      ),
    );
  });
}
