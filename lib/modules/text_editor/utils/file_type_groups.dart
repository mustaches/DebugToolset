import 'package:file_selector/file_selector.dart';

/// Categorized file type groups for the text editor / diff-patch module.
///
/// These groups are shown as separate categories in the file picker dropdown,
/// making it easier to locate C/C++, C#, Python, Verilog, and other source
/// files.
const List<XTypeGroup> kTextEditorFileGroups = [
  XTypeGroup(
    label: 'C / C++ / C# / VB / VC',
    extensions: [
      // C/C++ source and headers
      'c', 'cpp', 'cc', 'cxx', 'c++', 'cp', 'tcc', 'i', 'ii',
      'h', 'hpp', 'hxx', 'h++', 'hh', 'inl', 'ipp', 'pch',
      // C#
      'cs', 'cshtml', 'aspx', 'ascx', 'ashx', 'svc', 'csproj',
      // VB
      'vb', 'vbs', 'vbproj',
      // Visual Studio / Visual C++ project and solution files
      'vc', 'vcproj', 'vcxproj', 'filters', 'user', 'sln',
      // Visual Studio build artifacts and resources
      'props', 'targets', 'manifest', 'resx', 'rc', 'idl', 'odl', 'def',
      // C# / VB configuration
      'config', 'settings',
    ],
  ),
  XTypeGroup(
    label: 'Python',
    extensions: ['py'],
  ),
  XTypeGroup(
    label: 'FPGA / Vivado',
    extensions: [
      'v', 'sv', 'vhd', 'vhdl',       // HDL
      'xci', 'xpr', 'bd',             // Vivado project / block design
      'xdc', 'ucf',                   // constraints
      'tcl',                          // Tcl scripts
      'coe', 'mif',                   // memory initialization
      'edif', 'ngc', 'dcp',           // netlist / checkpoint
      'xco', 'xmp', 'bmm',            // Xilinx legacy files
      'do', 'wcfg',                   // simulation / waveform
      'rpt', 'sdf',                   // report / SDF
    ],
  ),
  XTypeGroup(
    label: 'Other Source',
    extensions: [
      'dart', 'java', 'js', 'ts', 'go', 'rs', 'swift', 'kt', 'm', 'mm',
    ],
  ),
  XTypeGroup(
    label: 'Scripts / Config / Markup / Logs',
    extensions: [
      'txt', 'cfg', 'ini', 'json', 'xml', 'md', 'yaml', 'yml', 'toml',
      'css', 'html', 'htm', 'sh', 'bat', 'ps1', 'sql', 'cmake', 'make',
      'mk', 'asm', 's',
      // System / application log files
      'log', 'out', 'err', 'trace', 'dbg', 'syslog', 'debug', 'audit', 'access',
    ],
  ),
  XTypeGroup(
    label: 'All Files',
    extensions: [],
  ),
];
