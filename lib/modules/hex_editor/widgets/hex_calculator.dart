import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String _formatHexOffset(int value) {
  final hex = (value & 0xFFFFFFFFFFFF).toRadixString(16).toUpperCase().padLeft(12, '0');
  return '0x${hex.substring(0, 4)} ${hex.substring(4, 8)} ${hex.substring(8, 12)}';
}

/// A hex calculator panel styled like a physical calculator.
/// Supports 0-9/A-F input, arithmetic, bitwise, and shift operations
/// on 48-bit addresses.
///
/// This widget renders only the calculator content (display + keypad) so it
/// can be embedded either in a standalone dialog or alongside another panel.
/// Results are delivered through [onConfirm]; dismissal through [onCancel].
class HexCalculatorDialog extends StatefulWidget {
  final int initialValue;
  final ValueChanged<int> onConfirm;
  final VoidCallback onCancel;

  const HexCalculatorDialog({
    super.key,
    required this.initialValue,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<HexCalculatorDialog> createState() => _HexCalculatorDialogState();
}

class _HexCalculatorDialogState extends State<HexCalculatorDialog> {
  static const int _mask = 0xFFFFFFFFFFFF;
  static const int _bitWidth = 48;

  late String _aInput;
  late String _bInput;
  // No default operator: null until the user explicitly picks one.
  String? _operator;
  // Initially the user edits operand A.
  bool _enteringB = false;

  @override
  void initState() {
    super.initState();
    _aInput = (widget.initialValue & _mask)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(12, '0');
    _bInput = '000000000000';
  }

  int get _aValue => int.parse(_aInput, radix: 16);
  int get _bValue => int.parse(_bInput, radix: 16);

  void _enterDigit(String digit) {
    setState(() {
      if (_enteringB) {
        _bInput = (_bInput.substring(1) + digit).toUpperCase();
      } else {
        _aInput = (_aInput.substring(1) + digit).toUpperCase();
      }
    });
  }

  void _setOperator(String op) {
    setState(() {
      _operator = op;
      _enteringB = true;
    });
  }

  void _clearEntry() {
    setState(() {
      if (_enteringB) {
        _bInput = '000000000000';
      } else {
        _aInput = '000000000000';
      }
    });
  }

  void _backspace() {
    setState(() {
      if (_enteringB) {
        _bInput = '0${_bInput.substring(0, 11)}';
      } else {
        _aInput = '0${_aInput.substring(0, 11)}';
      }
    });
  }

  /// Handles physical keyboard input so users can click a display line and
  /// type a hex value directly to overwrite it.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final label = event.logicalKey.keyLabel.toUpperCase();
    const hexChars = '0123456789ABCDEF';
    if (label.length == 1 && hexChars.contains(label)) {
      _enterDigit(label);
      return KeyEventResult.handled;
    }
    if (label == '+' || label == '-' || label == '*' || label == '/') {
      _setOperator(label);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _onEquals();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int _compute(int a, int b, String op) {
    switch (op) {
      case '+':
        return (a + b) & _mask;
      case '-':
        return (a - b) & _mask;
      case '*':
        return (a * b) & _mask;
      case '/':
        return b == 0 ? 0 : a ~/ b;
      case 'MOD':
        return b == 0 ? 0 : a % b;
      case 'AND':
        return (a & b) & _mask;
      case 'NAND':
        return (~(a & b)) & _mask;
      case 'OR':
        return (a | b) & _mask;
      case 'NOR':
        return (~(a | b)) & _mask;
      case 'XOR':
        return (a ^ b) & _mask;
      case 'NOT':
        return (~a) & _mask;
      case 'SHL':
        final shift = b % _bitWidth;
        return (a << shift) & _mask;
      case 'SHR':
        return a >> (b % _bitWidth);
      case 'ROL':
        final shift = b % _bitWidth;
        return ((a << shift) | (a >> (_bitWidth - shift))) & _mask;
      case 'ROR':
        final shift = b % _bitWidth;
        return ((a >> shift) | (a << (_bitWidth - shift))) & _mask;
      default:
        return a;
    }
  }

  void _onEquals() {
    final op = _operator;
    if (op == null) return;
    final result = _compute(_aValue, _bValue, op);
    setState(() {
      _aInput = result.toRadixString(16).toUpperCase().padLeft(12, '0');
      // Keep the user's chosen operator and operand B unchanged.
      _enteringB = false;
    });
  }

  String _operatorLabel(String op) {
    switch (op) {
      case '-':
        return '−';
      case '*':
        return '×';
      case '/':
        return '÷';
      default:
        return op;
    }
  }

  /// A display line that can be clicked to become the active operand for
  /// direct keyboard overwrite input.
  Widget _operandLine(
    String text,
    bool active,
    VoidCallback onTap, {
    Color color = Colors.white,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? Colors.cyanAccent : Colors.transparent,
                width: 1.5,
              ),
            ),
          ),
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: color,
              fontFamily: 'Consolas',
              fontSize: 16,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisplay() {
    final aFormatted = _formatHexOffset(_aValue);
    final bFormatted = _formatHexOffset(_bValue);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        // Recessed look: darker top fading down, opposite of raised buttons.
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D0D0D), Color(0xFF1F1F1F)],
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black, width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _operandLine(
                    aFormatted,
                    !_enteringB,
                    () => setState(() => _enteringB = false),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        _operator == null ? '' : _operatorLabel(_operator!),
                        style: TextStyle(
                          color: Colors.cyanAccent,
                          fontFamily: 'Consolas',
                          // Math symbols (+ − × ÷) are shown 1.5x larger.
                          fontSize: _operator != null && _operator!.length == 1
                              ? 21
                              : 14,
                          fontWeight: FontWeight.bold,
                          // Tight line box so larger symbols don't grow the row.
                          height: 1.0,
                          leadingDistribution: TextLeadingDistribution.even,
                        ),
                      ),
                      const Spacer(),
                      // Keep the B line's space even for unary NOT so the
                      // dialog height stays constant.
                      Visibility(
                        visible: _operator != null && _operator != 'NOT',
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: _operandLine(
                          bFormatted,
                          _enteringB,
                          () => setState(() => _enteringB = true),
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Inner shadow at the top edge (screen recessed into the case).
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 8,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.7),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Faint inner highlight at the bottom edge to complete the 3D inset.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 4,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.08),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Unified 5:3 rounded-rect key with a top-to-bottom gradient and drop
  /// shadow to simulate a 3D physical button.
  Widget _buildKeyButton({
    String label = '',
    IconData? icon,
    required VoidCallback onPressed,
    double width = 60,
    double height = 36,
    double fontSize = 14,
    Color textColor = Colors.white,
    List<Color> gradientColors = const [Color(0xFF4A4A4A), Color(0xFF2C2C2C)],
    String? fontFamily,
    double yOffset = 0,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Colors.black87,
            offset: Offset(0, 2),
            blurRadius: 3,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Center(
            child: icon != null
                ? Icon(icon, color: textColor, size: fontSize)
                : Transform.translate(
                    offset: Offset(0, yOffset),
                    child: Text(
                      label,
                      style: TextStyle(
                        color: textColor,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        fontFamily: fontFamily,
                        // Distribute line height evenly so glyphs from fallback
                        // fonts (e.g. × ÷ −) stay vertically centered.
                        height: 1.0,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildDigitButton(String digit) {
    return _buildKeyButton(
      label: digit,
      onPressed: () => _enterDigit(digit),
      fontSize: 16,
      fontFamily: 'Consolas',
      gradientColors: const [Color(0xFF2E5C7A), Color(0xFF1E3A50)],
    );
  }

  Widget _buildOpButton(String op) {
    return _buildKeyButton(
      label: _operatorLabel(op),
      onPressed: () => _setOperator(op),
      fontSize: op.length == 1 ? 24 : (op.length > 3 ? 10 : 12),
      // Nudge math symbols up slightly; their glyphs sit low in the em box.
      yOffset: op.length == 1 ? -2 : 0,
    );
  }

  /// Builds a row of keypad cells with fixed 8px gaps.
  Widget _keyRow(List<Widget> cells) {
    final children = <Widget>[];
    for (var i = 0; i < cells.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 8));
      children.add(cells[i]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// 6x6 keypad layout. The digit block is a 4x4 grid on the left; the '=' key
  /// and arithmetic operators occupy the right two columns, with 取消/确认 at
  /// the bottom-right.
  Widget _buildKeypad() {
    const gap = SizedBox(height: 8);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: CE, ROL, ROR, AND, OR, NOT
        _keyRow([
          _buildKeyButton(
            label: 'CE',
            onPressed: _clearEntry,
            fontSize: 12,
            gradientColors: const [Color(0xFF7A5A2E), Color(0xFF5A4022)],
          ),
          _buildOpButton('ROL'),
          _buildOpButton('ROR'),
          _buildOpButton('AND'),
          _buildOpButton('OR'),
          _buildOpButton('NOT'),
        ]),
        gap,
        // Row 2: ⌫, SHL, SHR, NAND, NOR, XOR
        _keyRow([
          _buildKeyButton(
            icon: Icons.backspace_outlined,
            onPressed: _backspace,
            fontSize: 18,
            gradientColors: const [Color(0xFF7A5A2E), Color(0xFF5A4022)],
          ),
          _buildOpButton('SHL'),
          _buildOpButton('SHR'),
          _buildOpButton('NAND'),
          _buildOpButton('NOR'),
          _buildOpButton('XOR'),
        ]),
        gap,
        // Rows 3-6: 4x4 digit grid on the left, operators/actions on the right.
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _keyRow([
                  _buildDigitButton('9'),
                  _buildDigitButton('8'),
                  _buildDigitButton('7'),
                  _buildDigitButton('F'),
                ]),
                gap,
                _keyRow([
                  _buildDigitButton('4'),
                  _buildDigitButton('5'),
                  _buildDigitButton('6'),
                  _buildDigitButton('E'),
                ]),
                gap,
                _keyRow([
                  _buildDigitButton('1'),
                  _buildDigitButton('2'),
                  _buildDigitButton('3'),
                  _buildDigitButton('D'),
                ]),
                gap,
                _keyRow([
                  _buildDigitButton('0'),
                  _buildDigitButton('A'),
                  _buildDigitButton('B'),
                  _buildDigitButton('C'),
                ]),
              ],
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _keyRow([
                  _buildOpButton('+'),
                  _buildOpButton('-'),
                ]),
                gap,
                _keyRow([
                  _buildOpButton('*'),
                  _buildOpButton('/'),
                ]),
                gap,
                _buildKeyButton(
                  label: '=',
                  onPressed: _onEquals,
                  width: 128,
                  height: 36,
                  fontSize: 22,
                  gradientColors: const [Color(0xFF7A5A2E), Color(0xFF5A4022)],
                ),
                gap,
                _keyRow([
                  _buildKeyButton(
                    label: '取消',
                    onPressed: widget.onCancel,
                    fontSize: 12,
                  ),
                  _buildKeyButton(
                    label: '确认',
                    onPressed: () => widget.onConfirm(_aValue),
                    fontSize: 12,
                  ),
                ]),
              ],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 6 cells * 60 + 5 gaps * 8 = 400: display matches keypad edge-to-edge.
      width: 400,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDisplay(),
            const SizedBox(height: 14),
            Center(child: _buildKeypad()),
          ],
        ),
      ),
    );
  }
}
