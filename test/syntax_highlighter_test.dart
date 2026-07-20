import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/text_editor/utils/syntax_highlighter.dart';

void main() {
  group('SyntaxHighlighter VSCode-style classification', () {
    const baseStyle = TextStyle(color: kVscodePlain, fontFamily: 'Consolas');

    List<({String text, Color color})> extractSpans(String code, String ext) {
      final spans = SyntaxHighlighter.highlightText(code, ext, baseStyle: baseStyle);
      return spans
          .map((s) => (text: s.text ?? '', color: s.style?.color ?? kVscodePlain))
          .toList();
    }

    test('detects control flow keywords in C', () {
      final code = 'for (int i = 0; i < n; i++) {\n'
          '  if (i > 0) return;\n'
          '  while (true) break;\n'
          '}';
      final spans = extractSpans(code, 'c');

      final control = spans
          .where((s) => s.color == kVscodeControlKeyword)
          .map((s) => s.text)
          .toSet();
      expect(control, containsAll({'for', 'if', 'return', 'while', 'break'}));

      final normalKeywords = spans
          .where((s) => s.color == kVscodeKeyword)
          .map((s) => s.text)
          .toSet();
      expect(normalKeywords, containsAll({'int', 'true'}));
    });

    test('detects function declarations and calls in C', () {
      final code = 'void fft_1024_process(float *io_buffer)\n'
          '{\n'
          '    double w_m_real = cos(2.0 * M_PI / m);\n'
          '}';
      final spans = extractSpans(code, 'c');

      final functions = spans
          .where((s) => s.color == kVscodeFunction)
          .map((s) => s.text)
          .toList();
      expect(functions, containsAll(['fft_1024_process', 'cos']));
    });

    test('detects variables and macros in C', () {
      final code = 'int n = FFT_WINDOW_SIZE;\n'
          'double w_m_real = 0.0;';
      final spans = extractSpans(code, 'c');

      final variables = spans
          .where((s) => s.color == kVscodeVariable)
          .map((s) => s.text)
          .toList();
      expect(variables, containsAll(['n', 'FFT_WINDOW_SIZE', 'w_m_real']));
    });

    test('detects types by _t suffix in C', () {
      final code = 'typedef struct { double real; } complex_t;\n'
          'complex_t temp[FFT_WINDOW_SIZE];';
      final spans = extractSpans(code, 'c');

      final types = spans
          .where((s) => s.color == kVscodeType)
          .map((s) => s.text)
          .toList();
      expect(types, containsAll(['complex_t']));
    });

    test('detects preprocessor directives in C', () {
      final code = '#include <math.h>\n'
          '#define FFT_WINDOW_SIZE 1024';
      final spans = extractSpans(code, 'c');

      final preproc = spans
          .where((s) => s.color == kVscodePreprocessor)
          .map((s) => s.text)
          .toList();
      expect(preproc, containsAll(['#include', '#define']));

      final strings = spans
          .where((s) => s.color == kVscodeString)
          .map((s) => s.text)
          .toList();
      expect(strings, contains('<math.h>'));
    });

    test('highlights the real fft_1024.c file like VSCode', () {
      final file = File('cfile/fft_1024.c');
      expect(file.existsSync(), isTrue, reason: 'fft_1024.c must exist');
      final code = file.readAsStringSync();
      final spans = extractSpans(code, 'c');

      final functions = spans
          .where((s) => s.color == kVscodeFunction)
          .map((s) => s.text)
          .toSet();
      expect(functions, containsAll(<String>{
        'fft_1024_process',
        '_fft_reverse_bits',
        'cos',
        'sin',
      }));
    });

    test('highlights Verilog keywords and numbers', () {
      final code = 'module adder(\n'
          '  input  wire [7:0] a,\n'
          '  output logic [7:0] sum\n'
          ');\n'
          '  always @(posedge clk) begin\n'
          '    if (rst) sum <= 8\'h00;\n'
          '    else sum <= a + 8\'b1010_1010;\n'
          '  end\n'
          'endmodule';
      final spans = extractSpans(code, 'v');

      final keywords = spans
          .where((s) => s.color == kVscodeKeyword)
          .map((s) => s.text)
          .toSet();
      expect(keywords, containsAll({'module', 'input', 'wire', 'output', 'logic', 'endmodule'}));
      // begin/end/always are now control keywords, not regular keywords.
      expect(keywords, isNot(contains('always')));
      expect(keywords, isNot(contains('begin')));
      expect(keywords, isNot(contains('end')));

      final control = spans
          .where((s) => s.color == kVscodeControlKeyword)
          .map((s) => s.text)
          .toSet();
      expect(control, containsAll({'always', 'posedge', 'begin', 'if', 'else', 'end', '@', '<='}));
      // regular assignment '=' is not colored as control.
      expect(control, isNot(contains('=')));

      final numbers = spans
          .where((s) => s.color == kVscodeNumber)
          .map((s) => s.text)
          .toSet();
      expect(numbers, containsAll({"8'h00", "8'b1010_1010"}));
    });

    test('detects Verilog module instantiation with parameter override', () {
      final code = 'line_buffer #(DW, IW)\n'
          '  line_buf_l(\n'
          '    .rst(rst_all),\n'
          '    .clk(clk),\n'
          '    .din(xhdl4[i])\n'
          '  );';
      final spans = extractSpans(code, 'v');

      final functions = spans
          .where((s) => s.color == kVscodeFunction)
          .map((s) => s.text)
          .toSet();
      expect(functions, containsAll({'line_buffer', 'line_buf_l'}));

      final control = spans
          .where((s) => s.color == kVscodeControlKeyword)
          .map((s) => s.text)
          .toSet();
      expect(control, containsAll({'#'}));
    });

    test('highlights VHDL keywords', () {
      final code = 'library IEEE;\n'
          'use IEEE.STD_LOGIC_1164.ALL;\n'
          'entity adder is\n'
          '  port (\n'
          '    a : in std_logic;\n'
          '    b : out std_logic\n'
          '  );\n'
          'end entity;\n'
          'architecture rtl of adder is\n'
          '  signal s : std_logic;\n'
          'begin\n'
          '  process(a) begin\n'
          '    if rising_edge(clk) then\n'
          '      s <= a;\n'
          '    end if;\n'
          '  end process;\n'
          'end architecture;';
      final spans = extractSpans(code, 'vhd');

      final keywords = spans
          .where((s) => s.color == kVscodeKeyword)
          .map((s) => s.text)
          .toSet();
      expect(keywords, containsAll({'library', 'use', 'entity', 'is', 'port', 'in', 'out', 'architecture', 'of', 'signal', 'begin', 'process', 'end', 'then'}));

      final control = spans
          .where((s) => s.color == kVscodeControlKeyword)
          .map((s) => s.text)
          .toSet();
      expect(control, containsAll({'if'}));
    });

    test('highlights XDC constraints', () {
      final code = '# Clock constraint\n'
          'create_clock -period 10.0 [get_ports clk]\n'
          'set_property PACKAGE_PIN U18 [get_ports rst]\n'
          'set_false_path -from [get_clocks clk] -to [get_clocks clk_out]';
      final spans = extractSpans(code, 'xdc');

      final keywords = spans
          .where((s) => s.color == kVscodeKeyword)
          .map((s) => s.text)
          .toSet();
      expect(keywords, containsAll({'create_clock', 'set_property', 'set_false_path', 'get_ports', 'get_clocks'}));
    });
  });
}
