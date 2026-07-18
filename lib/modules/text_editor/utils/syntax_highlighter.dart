import 'package:flutter/material.dart';

enum _TokenType {
  plain,
  keyword,
  string,
  comment,
  number,
  operator,
}

/// Describes a language for simple regex-free syntax highlighting.
class LanguageMode {
  final String name;
  final List<String> lineComments;
  final String? blockCommentStart;
  final String? blockCommentEnd;
  final List<String> stringDelimiters;
  final List<String> multiLineStringDelimiters;
  final Set<String> keywords;
  final bool caseSensitive;

  const LanguageMode({
    required this.name,
    this.lineComments = const [],
    this.blockCommentStart,
    this.blockCommentEnd,
    this.stringDelimiters = const [],
    this.multiLineStringDelimiters = const [],
    this.keywords = const {},
    this.caseSensitive = true,
  });
}

class _BlockCommentState {
  bool inBlockComment = false;
}

class _MultiLineStringState {
  bool inMultiLineString = false;
  String? delimiter;
}

// ---------------------------------------------------------------------------
// Keyword sets
// ---------------------------------------------------------------------------

const Set<String> _cFamilyKeywords = {
  // C / C++
  'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do', 'double',
  'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline', 'int', 'long',
  'register', 'restrict', 'return', 'short', 'signed', 'sizeof', 'static', 'struct',
  'switch', 'typedef', 'union', 'unsigned', 'void', 'volatile', 'while',
  'bool', 'true', 'false', 'nullptr', 'class', 'public', 'private', 'protected',
  'virtual', 'override', 'template', 'typename', 'namespace', 'using', 'new', 'delete',
  'explicit', 'friend', 'operator', 'this', 'throw', 'try', 'catch', 'noexcept',
  'decltype', 'constexpr', 'consteval', 'constinit', 'co_await', 'co_return', 'co_yield',
  'concept', 'requires', 'export', 'import', 'module', 'static_cast', 'dynamic_cast',
  'reinterpret_cast', 'const_cast', 'alignas', 'alignof',
  // C#
  'abstract', 'as', 'base', 'byte', 'checked', 'decimal', 'delegate', 'event',
 'finally', 'fixed', 'foreach', 'implicit', 'in', 'interface',
  'internal', 'is', 'lock', 'null', 'object', 'out', 'params',
 'readonly', 'ref', 'sbyte', 'sealed', 'stackalloc',
  'string', 'typeof', 'uint', 'ulong', 'unchecked', 'unsafe',
  'ushort', 'add', 'remove', 'get', 'set', 'value', 'var', 'dynamic',
  'async', 'await', 'yield', 'partial', 'record', 'init', 'required', 'when', 'nameof', 'with',
  // Java / JS / TS / Dart / Go / Rust / Swift / Kotlin / Objective-C
  'function', 'let', 'undefined', 'from', 'extends', 'implements',
  'package', 'super', 'instanceof', 'def', 'mixin', 'final', 'late', 'String',
  'num', 'List', 'Map', 'Set', 'Future', 'Stream', 'Object', 'Never', 'assert', 'library',
  'part', 'show', 'hide', 'deferred', 'covariant',
 'external', 'factory',
  'func', 'chan', 'go', 'defer', 'select', 'range', 'fallthrough', 'nil', 'make',
  'append', 'cap', 'copy', 'len', 'panic', 'recover', 'print', 'println',
  'fn', 'mut', 'trait', 'impl', 'mod', 'pub', 'crate', 'self', 'Self', 'where', 'match',
  'move', 'dyn', 'Box', 'Option', 'Result', 'Vec', 'Some', 'None', 'Ok', 'Err',
  'repeat', 'guard', 'associatedtype', 'some', 'any', 'throws', 'rethrows', 'open',
  'fileprivate', 'fun', 'val', 'by', 'lateinit', 'companion', 'suspend',
  '@interface', '@implementation', '@end', '@class', '@protocol', '@property', '@synthesize',
  '@dynamic', '@selector', '@autoreleasepool', '@try', '@catch', '@finally', '@throw',
  '@import', '@compatibility_alias', 'id', 'Nil', 'YES', 'NO', 'TRUE', 'FALSE',
  'nonatomic', 'assign', 'retain', 'strong', 'weak', 'readwrite',
};

const Set<String> _pythonKeywords = {
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class',
  'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global',
  'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return',
  'try', 'while', 'with', 'yield', 'self', 'cls',
};

const Set<String> _vbKeywords = {
  'AddHandler', 'AddressOf', 'Alias', 'And', 'AndAlso', 'As', 'Boolean', 'ByRef', 'Byte',
  'ByVal', 'Call', 'Case', 'Catch', 'CBool', 'CByte', 'CChar', 'CDate', 'CDbl', 'CDec',
  'Char', 'CInt', 'Class', 'CLng', 'CObj', 'Const', 'Continue', 'CSByte', 'CShort', 'CSng',
  'CStr', 'CType', 'CUInt', 'CULng', 'CUShort', 'Date', 'Decimal', 'Declare', 'Default',
  'Delegate', 'Dim', 'DirectCast', 'Do', 'Double', 'Each', 'Else', 'ElseIf', 'End', 'Enum',
  'Erase', 'Error', 'Event', 'Exit', 'False', 'Finally', 'For', 'Friend', 'Function', 'Get',
  'GetType', 'GetXMLNamespace', 'Global', 'GoSub', 'GoTo', 'Handles', 'If', 'Implements',
  'Imports', 'In', 'Inherits', 'Integer', 'Interface', 'Is', 'IsNot', 'Let', 'Lib', 'Like',
  'Long', 'Loop', 'Me', 'Mod', 'Module', 'MustInherit', 'MustOverride', 'MyBase', 'MyClass',
  'Namespace', 'Narrowing', 'New', 'Next', 'Not', 'Nothing', 'NotInheritable', 'NotOverridable',
  'Object', 'Of', 'On', 'Operator', 'Option', 'Optional', 'Or', 'OrElse', 'Out', 'Overloads',
  'Overridable', 'Overrides', 'ParamArray', 'Partial', 'Private', 'Property', 'Protected',
  'Public', 'RaiseEvent', 'ReadOnly', 'ReDim', 'RemoveHandler', 'Resume', 'Return', 'SByte',
  'Select', 'Set', 'Shadows', 'Shared', 'Short', 'Single', 'Static', 'Step', 'Stop', 'String',
  'Structure', 'Sub', 'SyncLock', 'Then', 'Throw', 'To', 'True', 'Try', 'TryCast', 'TypeOf',
  'UInteger', 'ULong', 'UShort', 'Using', 'Variant', 'Wend', 'When', 'While', 'Widening', 'With',
  'WithEvents', 'WriteOnly', 'Xor',
};

const Set<String> _hdlKeywords = {
  // Verilog
  'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'logic', 'integer',
  'parameter', 'localparam', 'assign', 'always', 'initial', 'begin', 'end', 'if', 'else',
  'case', 'casex', 'casez', 'endcase', 'for', 'while', 'repeat', 'forever', 'posedge',
  'negedge', 'or', 'and', 'nand', 'nor', 'xor', 'xnor', 'buf', 'not', 'supply0', 'supply1',
  'tri', 'triand', 'trior', 'trireg', 'vectored', 'scalared', 'signed', 'unsigned', 'genvar',
  'generate', 'endgenerate', 'function', 'endfunction', 'task', 'endtask', 'specify',
  'endspecify', 'realtime', 'time', 'event', 'defparam', 'disable', 'fork', 'join', 'wait',
  'deassign', 'release', 'force', 'strong0', 'strong1', 'weak0', 'weak1', 'highz0', 'highz1',
  'small', 'medium', 'large', 'primitive', 'endprimitive', 'table', 'endtable',
  // VHDL
  'library', 'use', 'entity', 'architecture', 'port', 'signal', 'variable', 'constant',
  'process', 'component', 'configuration', 'package', 'body', 'type', 'subtype', 'array',
  'record', 'access', 'file', 'alias', 'attribute', 'literal', 'range', 'downto', 'to',
  'others', 'all', 'of', 'is', 'are', 'with', 'select', 'unaffected', 'group', 'guarded',
  'reject', 'on', 'after', 'transport', 'inertial', 'null', 'map', 'out',
  'buffer', 'in', 'through', 'when', 'then', 'elsif', 'return', 'procedure', 'exit', 'next',
  'loop', 'assert', 'report', 'severity', 'note', 'warning', 'error', 'failure',
};

const Set<String> _scriptKeywords = {
  'if', 'else', 'elif', 'fi', 'then', 'for', 'while', 'do', 'done', 'until', 'case', 'esac',
  'in', 'select', 'function', 'return', 'break', 'continue', 'exit', 'echo', 'read', 'set',
  'unset', 'export', 'local', 'source', 'true', 'false', 'switch', 'default', 'param',
  'CmdletBinding', 'Process', 'Begin', 'End', 'filter', 'foreach', 'where', 'throw', 'try',
  'catch', 'finally', 'class', 'enum', 'module', 'using', 'namespace', 'proc', 'puts', 'expr',
  'variable', 'upvar', 'global', 'eval', 'yield',
};

// ---------------------------------------------------------------------------
// Language modes
// ---------------------------------------------------------------------------

const LanguageMode _cFamily = LanguageMode(
  name: 'C family',
  lineComments: ['//'],
  blockCommentStart: '/*',
  blockCommentEnd: '*/',
  stringDelimiters: ['"', "'"],
  keywords: _cFamilyKeywords,
);

const LanguageMode _python = LanguageMode(
  name: 'Python',
  lineComments: ['#'],
  stringDelimiters: ['"', "'"],
  multiLineStringDelimiters: ['"""', "'''"],
  keywords: _pythonKeywords,
);

const LanguageMode _vb = LanguageMode(
  name: 'VB',
  lineComments: ["'", 'REM'],
  stringDelimiters: ['"'],
  keywords: _vbKeywords,
  caseSensitive: false,
);

const LanguageMode _hdl = LanguageMode(
  name: 'HDL',
  lineComments: ['//', '--'],
  blockCommentStart: '/*',
  blockCommentEnd: '*/',
  stringDelimiters: ['"', "'"],
  keywords: _hdlKeywords,
);

const LanguageMode _script = LanguageMode(
  name: 'Script',
  lineComments: ['#'],
  stringDelimiters: ['"', "'"],
  keywords: _scriptKeywords,
);

const LanguageMode _batch = LanguageMode(
  name: 'Batch',
  lineComments: ['REM', '::'],
  stringDelimiters: ['"'],
  keywords: _scriptKeywords,
  caseSensitive: false,
);

const LanguageMode _ini = LanguageMode(
  name: 'INI',
  lineComments: [';', '#'],
  stringDelimiters: ['"', "'"],
  keywords: {},
);

const LanguageMode _json = LanguageMode(
  name: 'JSON',
  stringDelimiters: ['"'],
  keywords: {},
);

const LanguageMode _markup = LanguageMode(
  name: 'Markup',
  blockCommentStart: '<!--',
  blockCommentEnd: '-->',
  stringDelimiters: ['"', "'"],
  keywords: {
    'html', 'head', 'body', 'title', 'meta', 'link', 'script', 'style', 'div', 'span',
    'p', 'a', 'img', 'br', 'hr', 'table', 'tr', 'td', 'th', 'ul', 'ol', 'li', 'h1', 'h2',
    'h3', 'h4', 'h5', 'h6', 'form', 'input', 'button', 'label', 'select', 'option',
    'xml', 'version', 'encoding', 'standalone',
  },
);

const LanguageMode _css = LanguageMode(
  name: 'CSS',
  blockCommentStart: '/*',
  blockCommentEnd: '*/',
  stringDelimiters: ['"', "'"],
  keywords: {
    'color', 'background', 'border', 'margin', 'padding', 'width', 'height', 'display',
    'position', 'top', 'left', 'right', 'bottom', 'font', 'text', 'align', 'center',
    'none', 'block', 'inline', 'flex', 'grid', 'absolute', 'relative', 'fixed', 'sticky',
    'px', 'em', 'rem', 'vh', 'vw', '%', 'important',
  },
);

const LanguageMode _plain = LanguageMode(
  name: 'Plain',
  keywords: {},
);

// ---------------------------------------------------------------------------
// Extension mapping
// ---------------------------------------------------------------------------

const Map<String, LanguageMode> _languageByExtension = {
  // C / C++ / C# / VB / VC
  'c': _cFamily, 'cpp': _cFamily, 'cc': _cFamily, 'cxx': _cFamily, 'c++': _cFamily,
  'cp': _cFamily, 'tcc': _cFamily, 'i': _cFamily, 'ii': _cFamily,
  'h': _cFamily, 'hpp': _cFamily, 'hxx': _cFamily, 'h++': _cFamily, 'hh': _cFamily,
  'inl': _cFamily, 'ipp': _cFamily, 'pch': _cFamily,
  'cs': _cFamily, 'cshtml': _cFamily, 'aspx': _cFamily, 'ascx': _cFamily,
  'ashx': _cFamily, 'svc': _cFamily, 'csproj': _cFamily, 'vbproj': _cFamily,
  'vcproj': _cFamily, 'vcxproj': _cFamily, 'filters': _cFamily, 'user': _cFamily,
  'sln': _cFamily, 'props': _cFamily, 'targets': _cFamily, 'manifest': _cFamily,
  'resx': _cFamily, 'rc': _cFamily, 'idl': _cFamily, 'odl': _cFamily, 'def': _cFamily,
  'config': _cFamily, 'settings': _cFamily, 'vc': _cFamily,
  'vb': _vb, 'vbs': _vb,
  // Python
  'py': _python,
  // HDL / FPGA
  'v': _hdl, 'sv': _hdl, 'vhd': _hdl, 'vhdl': _hdl,
  'xdc': _script, 'xci': _script, 'xpr': _script, 'xco': _script, 'xmp': _script,
  'bmm': _script, 'do': _script, 'wcfg': _script, 'tcl': _script,
  'coe': _plain, 'mif': _plain, 'edif': _plain, 'ngc': _plain, 'dcp': _plain, 'rpt': _plain,
  'sdf': _plain,
  // Other source
  'java': _cFamily, 'js': _cFamily, 'ts': _cFamily, 'm': _cFamily, 'mm': _cFamily,
  'go': _cFamily, 'rs': _cFamily, 'swift': _cFamily, 'kt': _cFamily, 'dart': _cFamily,
  // Scripts / Config / Markup / Logs
  'sh': _script, 'bat': _batch, 'ps1': _script, 'yaml': _script, 'yml': _script,
  'ini': _ini, 'cfg': _ini, 'toml': _ini, 'conf': _ini,
  'json': _json,
  'xml': _markup, 'html': _markup, 'htm': _markup, 'md': _markup, 'svg': _markup,
  'css': _css,
  'log': _plain, 'out': _plain, 'err': _plain, 'trace': _plain, 'dbg': _plain,
  'syslog': _plain, 'debug': _plain, 'audit': _plain, 'access': _plain,
  'txt': _plain,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 48 && u <= 57;
}

bool _isHexDigit(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 48 && u <= 57) || (u >= 65 && u <= 70) || (u >= 97 && u <= 102);
}

bool _isWordStart(String c) => RegExp(r'^[a-zA-Z_]$').hasMatch(c);
bool _isWordChar(String c) => RegExp(r'^[a-zA-Z0-9_]$').hasMatch(c);
bool _isOperatorChar(String c) => RegExp(r'^[+\-*/=<>!&|^%~?:]$').hasMatch(c);

int? _lineCommentLength(String line, int i, LanguageMode mode) {
  if (mode.lineComments.isEmpty) return null;
  for (final marker in mode.lineComments) {
    final bool matches = mode.caseSensitive
        ? line.startsWith(marker, i)
        : line.toLowerCase().startsWith(marker.toLowerCase(), i);
    if (matches) {
      // Avoid matching markers that are prefixes of identifiers (e.g. REM in REMINDER).
      if (marker.length > 1 && _isWordStart(marker[0])) {
        final after = i + marker.length;
        if (after < line.length && _isWordChar(line[after])) continue;
      }
      return marker.length;
    }
  }
  return null;
}

TextSpan _span(String text, _TokenType type, TextStyle baseStyle) {
  Color color;
  switch (type) {
    case _TokenType.keyword:
      color = Colors.cyanAccent;
      break;
    case _TokenType.string:
      color = Colors.orangeAccent;
      break;
    case _TokenType.comment:
      color = Colors.greenAccent;
      break;
    case _TokenType.number:
      color = Colors.yellow;
      break;
    case _TokenType.operator:
      color = Colors.pinkAccent;
      break;
    case _TokenType.plain:
      color = baseStyle.color ?? Colors.white;
      break;
  }
  return TextSpan(text: text, style: baseStyle.copyWith(color: color));
}

List<TextSpan> _tokenizeLine(
  String line,
  LanguageMode mode,
  TextStyle baseStyle,
  _BlockCommentState blockState,
  _MultiLineStringState multiLineState,
) {
  final spans = <TextSpan>[];

  // Continuation of a block comment from the previous line.
  if (blockState.inBlockComment && mode.blockCommentEnd != null) {
    final end = line.indexOf(mode.blockCommentEnd!);
    if (end != -1) {
      final len = end + mode.blockCommentEnd!.length;
      spans.add(_span(line.substring(0, len), _TokenType.comment, baseStyle));
      line = line.substring(len);
      blockState.inBlockComment = false;
    } else {
      spans.add(_span(line, _TokenType.comment, baseStyle));
      return spans;
    }
  }

  int i = 0;
  final pending = StringBuffer();

  void flush() {
    if (pending.isNotEmpty) {
      spans.add(_span(pending.toString(), _TokenType.plain, baseStyle));
      pending.clear();
    }
  }

  while (i < line.length) {
    // Line comment
    final lineCommentLen = _lineCommentLength(line, i, mode);
    if (lineCommentLen != null) {
      flush();
      spans.add(_span(line.substring(i), _TokenType.comment, baseStyle));
      break;
    }

    // Multi-line string (Python triple quotes, etc.)
    if (mode.multiLineStringDelimiters.isNotEmpty) {
      String? mlDelimiter;
      for (final d in mode.multiLineStringDelimiters) {
        if (line.startsWith(d, i)) {
          mlDelimiter = d;
          break;
        }
      }
      if (mlDelimiter != null) {
        flush();
        final end = line.indexOf(mlDelimiter, i + mlDelimiter.length);
        if (end != -1) {
          spans.add(_span(line.substring(i, end + mlDelimiter.length), _TokenType.string, baseStyle));
          i = end + mlDelimiter.length;
        } else {
          spans.add(_span(line.substring(i), _TokenType.string, baseStyle));
          multiLineState.inMultiLineString = true;
          multiLineState.delimiter = mlDelimiter;
          i = line.length;
        }
        continue;
      }
    }

    // Single-line string / character literal
    if (mode.stringDelimiters.contains(line[i])) {
      flush();
      final quote = line[i];
      final sb = StringBuffer(quote);
      int j = i + 1;
      bool escape = false;
      for (; j < line.length; j++) {
        final ch = line[j];
        if (escape) {
          sb.write(ch);
          escape = false;
        } else if (ch == r'\') {
          sb.write(ch);
          escape = true;
        } else if (ch == quote) {
          sb.write(ch);
          break;
        } else {
          sb.write(ch);
        }
      }
      spans.add(_span(sb.toString(), _TokenType.string, baseStyle));
      i = j + 1;
      continue;
    }

    // Block comment
    if (mode.blockCommentStart != null && line.startsWith(mode.blockCommentStart!, i)) {
      flush();
      final end = line.indexOf(mode.blockCommentEnd!, i + mode.blockCommentStart!.length);
      if (end != -1) {
        final len = end + mode.blockCommentEnd!.length;
        spans.add(_span(line.substring(i, len), _TokenType.comment, baseStyle));
        i = len;
      } else {
        spans.add(_span(line.substring(i), _TokenType.comment, baseStyle));
        blockState.inBlockComment = true;
        i = line.length;
      }
      continue;
    }

    // Number
    if (_isDigit(line[i])) {
      flush();
      int j = i + 1;
      while (j < line.length) {
        final c = line[j];
        if (_isDigit(c) ||
            c == '.' ||
            c == '_' ||
            c == 'x' ||
            c == 'X' ||
            c == 'b' ||
            c == 'B' ||
            c == 'o' ||
            c == 'O' ||
            _isHexDigit(c) ||
            c == 'e' ||
            c == 'E') {
          j++;
        } else {
          break;
        }
      }
      spans.add(_span(line.substring(i, j), _TokenType.number, baseStyle));
      i = j;
      continue;
    }

    // Word
    if (_isWordStart(line[i])) {
      flush();
      int j = i + 1;
      while (j < line.length && _isWordChar(line[j])) {
        j++;
      }
      final word = line.substring(i, j);
      final lookup = mode.caseSensitive ? word : word.toLowerCase();
      final type = mode.keywords.contains(lookup) ? _TokenType.keyword : _TokenType.plain;
      spans.add(_span(word, type, baseStyle));
      i = j;
      continue;
    }

    // Operator
    if (_isOperatorChar(line[i])) {
      flush();
      int j = i + 1;
      while (j < line.length && _isOperatorChar(line[j])) {
        j++;
      }
      spans.add(_span(line.substring(i, j), _TokenType.operator, baseStyle));
      i = j;
      continue;
    }

    // Plain text / punctuation
    pending.write(line[i]);
    i++;
  }

  flush();
  return spans;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

class SyntaxHighlighter {
  SyntaxHighlighter._();

  static List<TextSpan> highlightText(
    String text,
    String? extension, {
    required TextStyle baseStyle,
  }) {
    if (text.isEmpty) {
      return [TextSpan(text: '', style: baseStyle)];
    }

    final mode = _languageByExtension[extension?.toLowerCase()] ?? _plain;
    final blockState = _BlockCommentState();
    final multiLineState = _MultiLineStringState();
    final spans = <TextSpan>[];
    final lines = text.split('\n');

    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));

      final line = lines[i];
      if (multiLineState.inMultiLineString && multiLineState.delimiter != null) {
        final end = line.indexOf(multiLineState.delimiter!);
        if (end != -1) {
          spans.add(_span(line.substring(0, end + multiLineState.delimiter!.length), _TokenType.string, baseStyle));
          final rest = line.substring(end + multiLineState.delimiter!.length);
          multiLineState.inMultiLineString = false;
          multiLineState.delimiter = null;
          spans.addAll(_tokenizeLine(rest, mode, baseStyle, blockState, multiLineState));
        } else {
          spans.add(_span(line, _TokenType.string, baseStyle));
        }
      } else {
        spans.addAll(_tokenizeLine(line, mode, baseStyle, blockState, multiLineState));
      }
    }

    return spans;
  }
}
