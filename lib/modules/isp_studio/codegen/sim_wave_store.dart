/// 仿真波形共享仓库：一键仿真产出的 wave.vcd 字节与查看器配置
/// （wave.sucl / wave.gtkw），供「仿真波形」标签页解析渲染、外部查看器
/// 兜底写盘。代次广播驱动标签页刷新。单例。
library;

import 'dart:async';
import 'dart:typed_data';

class SimWaveStore {
  SimWaveStore._();
  static final SimWaveStore instance = SimWaveStore._();

  Uint8List? currentVcd;
  String? currentSucl;
  String? currentGtkw;

  /// 波形代次：每次 [registerWave] 自增并广播。
  int generation = 0;
  final _genCtrl = StreamController<int>.broadcast();
  Stream<int> get onWave => _genCtrl.stream;

  void registerWave(Uint8List vcd, {String? sucl, String? gtkw}) {
    currentVcd = vcd;
    currentSucl = sucl;
    currentGtkw = gtkw;
    generation++;
    _genCtrl.add(generation);
  }
}
