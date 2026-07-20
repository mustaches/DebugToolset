import 'package:flutter/material.dart';

// VSCode "Dark+" default token colors for the text editor / diff view.
// These values are taken from the Visual Studio Code default dark theme
// so the in-app editor feels familiar to VSCode users.
const Color kVscodePlain = Color(0xFFD4D4D4);
const Color kVscodeKeyword = Color(0xFF569CD6);
const Color kVscodeControlKeyword = Color(0xFFC586C0);
const Color kVscodeString = Color(0xFFCE9178);
const Color kVscodeComment = Color(0xFF6A9955);
const Color kVscodeNumber = Color(0xFFB5CEA8);
const Color kVscodeOperator = Color(0xFFD4D4D4);
const Color kVscodePreprocessor = Color(0xFFC586C0);
const Color kVscodeFunction = Color(0xFFDCDCAA);
const Color kVscodeType = Color(0xFF4EC9B0);
const Color kVscodeVariable = Color(0xFF9CDCFE);

enum _TokenType {
  plain,
  keyword,
  controlKeyword,
  string,
  comment,
  number,
  operator,
  preprocessor,
  function,
  type,
  variable,
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

const Set<String> _verilogControlFlowKeywords = {
  // Block / procedural control
  'begin', 'end', 'fork', 'join', 'join_any', 'join_none',
  // Conditional
  'if', 'else', 'case', 'casex', 'casez', 'endcase', 'unique', 'unique0', 'priority',
  // Loops / jumps
  'for', 'while', 'do', 'repeat', 'forever', 'return', 'break', 'continue',
  // Procedural / timing
  'always', 'always_comb', 'always_ff', 'always_latch', 'initial', 'final',
  'assign', 'deassign', 'force', 'release', 'wait', 'disable',
  'posedge', 'negedge', 'edge',
};

const Set<String> _verilogKeywords = {
  // Verilog-2001 / SystemVerilog keywords (blue)
  'module', 'endmodule', 'primitive', 'endprimitive', 'macromodule',
  'input', 'output', 'inout', 'buf', 'wire', 'tri', 'triand', 'trior', 'trireg',
  'reg', 'logic', 'integer', 'int', 'longint', 'shortint', 'byte', 'bit',
  'time', 'realtime', 'real', 'shortreal', 'parameter', 'localparam', 'specparam',
  'alias', 'generate', 'endgenerate', 'genvar', 'function', 'endfunction', 'task', 'endtask',
  'specify', 'endspecify', 'pulsestyle_onevent', 'pulsestyle_ondetect', 'showcancelled',
  'noshowcancelled', 'small', 'medium', 'large', 'strong0', 'strong1', 'pull0', 'pull1',
  'weak0', 'weak1', 'highz0', 'highz1', 'supply0', 'supply1', 'cmos', 'rcmos', 'pmos',
  'rpmos', 'nmos', 'rnmos', 'tran', 'rtran', 'tranif0', 'tranif1', 'rtranif0', 'rtranif1',
  'and', 'nand', 'or', 'nor', 'xor', 'xnor', 'not', 'bufif0', 'bufif1', 'notif0', 'notif1',
  'scalared', 'vectored', 'signed', 'unsigned', 'automatic', 'static', 'const', 'var',
  'void', 'string', 'event', 'chandle', 'enum', 'struct', 'union', 'packed', 'tagged',
  'virtual', 'interface', 'endinterface', 'modport', 'clocking', 'endclocking', 'clockvar',
  'cover', 'covergroup', 'endgroup', 'coverpoint', 'cross', 'property', 'endproperty',
  'sequence', 'endsequence', 'assert', 'assume', 'restrict', 'expect', 'rand', 'randc',
  'randcase', 'randsequence', 'constraint', 'solve', 'before', 'dist', 'inside', 'with',
  'extends', 'implements', 'super', 'this', 'new', 'null', 'typedef', 'import', 'export',
  'context', 'extern', 'pure', 'ref', 'in', 'out', 'throughout',
  'until', 'since', 'nexttime', 's_nexttime', 's_eventually', 'eventually',
  's_always', 's_until', 's_until_with', 'until_with', 'weak', 'strong', 'accept_on',
  'reject_on', 'sync_accept_on', 'sync_reject_on', 'checker', 'endchecker',
  'class', 'endclass', 'package', 'endpackage', 'program', 'endprogram', 'config', 'endconfig',
  'bind', 'design', 'instance', 'cell', 'use', 'liblist', 'include',
};

const Set<String> _vhdlKeywords = {
  'library', 'use', 'entity', 'architecture', 'configuration', 'package', 'body',
  'component', 'port', 'generic', 'map', 'attribute', 'signal', 'variable', 'constant',
  'file', 'type', 'subtype', 'range', 'downto', 'to', 'of', 'is', 'are', 'in', 'out',
  'inout', 'buffer', 'linkage', 'process', 'function', 'procedure', 'return', 'begin',
  'end', 'if', 'then', 'else', 'elsif', 'case', 'when', 'others', 'select', 'with',
  'wait', 'on', 'until', 'for', 'while', 'loop', 'next', 'exit', 'assert', 'report',
  'severity', 'note', 'warning', 'error', 'failure', 'null', 'unaffected', 'transport',
  'inertial', 'reject', 'after', 'guarded', 'group', 'shared', 'protected', 'record',
  'access', 'alias', 'literal', 'units', 'new', 'all', 'open', 'context',
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

const LanguageMode _verilog = LanguageMode(
  name: 'Verilog',
  lineComments: ['//'],
  blockCommentStart: '/*',
  blockCommentEnd: '*/',
  stringDelimiters: ['"', "'"],
  keywords: {..._verilogKeywords, ..._verilogControlFlowKeywords},
);

const LanguageMode _vhdl = LanguageMode(
  name: 'VHDL',
  lineComments: ['--'],
  blockCommentStart: null,
  blockCommentEnd: null,
  stringDelimiters: ['"'],
  keywords: _vhdlKeywords,
);

const LanguageMode _xdc = LanguageMode(
  name: 'XDC',
  lineComments: ['#'],
  stringDelimiters: ['"', "'"],
  keywords: {
    // Vivado Tcl / XDC commands
    'set_property', 'get_property', 'report_property', 'create_clock',
    'create_generated_clock', 'set_clock_groups', 'set_false_path',
    'set_multicycle_path', 'set_max_delay', 'set_min_delay', 'set_input_delay',
    'set_output_delay', 'set_case_analysis', 'set_clock_latency',
    'set_clock_uncertainty', 'set_external_delay', 'set_data_check',
    'set_clock_sense', 'set_ideal_network', 'set_ideal_transition',
    'set_max_time_borrow', 'set_resistance', 'set_capacitance', 'set_load',
    'set_driving_cell', 'set_fanout_load', 'set_operating_conditions',
    'set_wire_load_model', 'set_wire_load_mode', 'set_voltage', 'set_temperature',
    'set_timing_derate', 'set_clock_transition', 'set_disable_timing',
    'set_max_fanout', 'set_max_transition', 'set_max_capacitance',
    'get_ports', 'get_pins', 'get_cells', 'get_nets', 'get_clocks',
    'get_timing_paths', 'get_designs', 'get_lib_cells', 'get_lib_pins',
    'current_instance', 'all_inputs', 'all_outputs', 'all_registers', 'all_clocks',
    'filter', 'find', 'lappend', 'set', 'puts', 'proc', 'return', 'if', 'else',
    'elseif', 'for', 'while', 'foreach', 'switch', 'case', 'default', 'break',
    'continue', 'expr', 'list', 'lindex', 'llength', 'concat', 'append', 'source',
    'namespace', 'package', 'require', 'catch', 'error', 'eval', 'info',
  },
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
  'v': _verilog, 'sv': _verilog, 'vhd': _vhdl, 'vhdl': _vhdl,
  'xdc': _xdc, 'ucf': _xdc,
  'xci': _markup, 'xpr': _markup, 'xco': _markup, 'xmp': _markup,
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

// Verilog number literal: [size][']<base><value>, e.g. 4'b1010, 16'hFF, 32'd100.
// Also supports signed specifier: 4'sb1010, and underscores: 4'b10_10.
bool _isVerilogNumberStart(String line, int i) {
  int j = i;
  while (j < line.length && _isDigit(line[j])) {
    j++;
  }
  if (j >= line.length || line[j] != "'") return false;
  j++;
  if (j < line.length && (line[j] == 's' || line[j] == 'S')) {
    j++;
  }
  if (j >= line.length) return false;
  final base = line[j].toLowerCase();
  return base == 'b' || base == 'o' || base == 'd' || base == 'h';
}

String _readVerilogNumber(String line, int i) {
  int j = i;
  while (j < line.length && _isDigit(line[j])) {
    j++;
  }
  // Skip apostrophe and optional 's'/'S'.
  j++; // '
  if (j < line.length && (line[j] == 's' || line[j] == 'S')) {
    j++;
  }
  if (j >= line.length) return line.substring(i);
  final base = line[j].toLowerCase();
  j++;

  bool validChar(String c) {
    if (c == '_' || c == '?' || c == 'x' || c == 'X' || c == 'z' || c == 'Z') return true;
    switch (base) {
      case 'b':
        return c == '0' || c == '1';
      case 'o':
        final u = c.codeUnitAt(0);
        return u >= 48 && u <= 55;
      case 'd':
        return _isDigit(c);
      case 'h':
        return _isDigit(c) || _isHexDigit(c);
    }
    return false;
  }

  while (j < line.length && validChar(line[j])) {
    j++;
  }
  return line.substring(i, j);
}

bool _isVerilogSpecialOperator(String op) {
  return op == '@' ||
      op == '#' ||
      op == '<=' ||
      op == '>=' ||
      op == '==' ||
      op == '!=' ||
      op == '===' ||
      op == '!==';
}

bool _isFollowedByHash(String line, int afterIndex) {
  int j = afterIndex;
  while (j < line.length && (line[j] == ' ' || line[j] == '\t')) {
    j++;
  }
  return j < line.length && line[j] == '#';
}

const Set<String> _cPreprocessorDirectives = {
  'include', 'import', 'define', 'undef', 'ifdef', 'ifndef', 'if', 'elif', 'else',
  'endif', 'pragma', 'error', 'line',
};

const Set<String> _cControlFlowKeywords = {
  'if', 'else', 'switch', 'case', 'default', 'for', 'foreach', 'while', 'do', 'break',
  'continue', 'return', 'goto', 'throw', 'try', 'catch', 'finally', 'co_await',
  'co_return', 'co_yield',
};

bool _isLineStart(String line, int i) {
  for (int k = 0; k < i; k++) {
    if (line[k] != ' ' && line[k] != '\t') return false;
  }
  return true;
}

bool _isFollowedByParen(String line, int afterIndex) {
  int j = afterIndex;
  while (j < line.length && (line[j] == ' ' || line[j] == '\t')) {
    j++;
  }
  return j < line.length && line[j] == '(';
}

_TokenType _classifyWord(String word, LanguageMode mode, String line, int afterIndex) {
  final lookup = mode.caseSensitive ? word : word.toLowerCase();
  if (mode.keywords.contains(lookup)) {
    if (mode.name == 'C family' || mode.name == 'VHDL' || mode.name == 'XDC') {
      if (_cControlFlowKeywords.contains(lookup)) {
        return _TokenType.controlKeyword;
      }
    } else if (mode.name == 'Verilog') {
      if (_verilogControlFlowKeywords.contains(lookup)) {
        return _TokenType.controlKeyword;
      }
    }
    return _TokenType.keyword;
  }

  // VSCode-style semantic heuristics for C-like and HDL languages.
  if (mode.name == 'C family' ||
      mode.name == 'Verilog' ||
      mode.name == 'VHDL') {
    if (word.endsWith('_t')) return _TokenType.type;
    if (_isFollowedByParen(line, afterIndex)) return _TokenType.function;
    if (mode.name == 'Verilog' && _isFollowedByHash(line, afterIndex)) {
      return _TokenType.function;
    }
    return _TokenType.variable;
  }

  return _TokenType.plain;
}

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
      color = kVscodeKeyword;
      break;
    case _TokenType.controlKeyword:
      color = kVscodeControlKeyword;
      break;
    case _TokenType.string:
      color = kVscodeString;
      break;
    case _TokenType.comment:
      color = kVscodeComment;
      break;
    case _TokenType.number:
      color = kVscodeNumber;
      break;
    case _TokenType.operator:
      color = kVscodeOperator;
      break;
    case _TokenType.preprocessor:
      color = kVscodePreprocessor;
      break;
    case _TokenType.function:
      color = kVscodeFunction;
      break;
    case _TokenType.type:
      color = kVscodeType;
      break;
    case _TokenType.variable:
      color = kVscodeVariable;
      break;
    case _TokenType.plain:
      color = baseStyle.color ?? kVscodePlain;
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

    // Preprocessor directive (C/C++ family only).
    if (line[i] == '#' && _isLineStart(line, i)) {
      flush();
      int j = i + 1;
      while (j < line.length && (line[j] == ' ' || line[j] == '\t')) {
        j++;
      }
      final directiveStart = j;
      while (j < line.length && _isWordChar(line[j])) {
        j++;
      }
      final directive = line.substring(directiveStart, j).toLowerCase();
      if (_cPreprocessorDirectives.contains(directive)) {
        spans.add(_span(line.substring(i, j), _TokenType.preprocessor, baseStyle));
        if (directive == 'include') {
          final rest = line.substring(j).trimLeft();
          if (rest.isNotEmpty) {
            spans.add(_span(rest, _TokenType.string, baseStyle));
          }
          break;
        }
        i = j;
        continue;
      }
      // Not a recognized directive: fall back to plain text so # stays uncolored.
      pending.write(line[i]);
      i++;
      continue;
    }

    // Number
    if (mode.name == 'Verilog' && _isVerilogNumberStart(line, i)) {
      flush();
      final number = _readVerilogNumber(line, i);
      spans.add(_span(number, _TokenType.number, baseStyle));
      i += number.length;
      continue;
    }

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
      final type = _classifyWord(word, mode, line, j);
      spans.add(_span(word, type, baseStyle));
      i = j;
      continue;
    }

    // Verilog special operators: sensitivity @, delay #, and comparison/equality.
    if (mode.name == 'Verilog' && (line[i] == '@' || line[i] == '#')) {
      flush();
      spans.add(_span(line[i], _TokenType.controlKeyword, baseStyle));
      i++;
      continue;
    }

    // Operator
    if (_isOperatorChar(line[i])) {
      flush();
      int j = i + 1;
      while (j < line.length && _isOperatorChar(line[j])) {
        j++;
      }
      final op = line.substring(i, j);
      final type = mode.name == 'Verilog' && _isVerilogSpecialOperator(op)
          ? _TokenType.controlKeyword
          : _TokenType.operator;
      spans.add(_span(op, type, baseStyle));
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
