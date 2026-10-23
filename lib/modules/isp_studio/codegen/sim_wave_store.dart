/// 仿真波形共享仓库：一键仿真产出的 wave.vcd 字节，供「仿真波形」
/// 标签页解析渲染。代次广播驱动标签页刷新。单例。
library;

import 'dart:async';
import 'dart:typed_data';

import 'ip_target.dart';

class SimWaveStore {
  SimWaveStore._();
  static final SimWaveStore instance = SimWaveStore._();

  Uint8List? currentVcd;

  /// 当前波形的来源编组与厂商（一键仿真登记时填写；Open VCD 打开的外部
  /// 波形为 null——Signal 右键菜单「跳转到Verilog」随之不可用）。
  String? sourceGroupId;
  IpVendor? sourceVendor;

  /// 波形代次：每次 [registerWave] 自增并广播。
  int generation = 0;
  final _genCtrl = StreamController<int>.broadcast();
  Stream<int> get onWave => _genCtrl.stream;

  void registerWave(
    Uint8List vcd, {
    String? groupId,
    IpVendor? vendor,
  }) {
    currentVcd = vcd;
    sourceGroupId = groupId;
    sourceVendor = vendor;
    generation++;
    _genCtrl.add(generation);
  }
}
