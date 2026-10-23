# Vivado Customize IP 定制界面（DebugToolSet ISP Studio 生成）：
# 分页 + 控件化 + 参数联动（FOLD 仅 GSTRATEGY=0 面积档可编辑，
# enablement 由打包脚本 package_ip.tcl 的 enablement_tcl_expr 实现）。
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  set Page0 [ipgui::add_page $IPINST -name "Page0" -display_name {基本配置 General}]
  ipgui::add_param $IPINST -name "PIX_BITS" -parent $Page0 \
      -display_name {像素位宽 PIX_BITS} \
      -tooltip {像素位宽；决定数据通路宽度与 LUT ROM 深度（MAXV=2^PIX_BITS-1）。} \
      -widget comboBox
  ipgui::add_param $IPINST -name "MAX_WIDTH" -parent $Page0 \
      -display_name {最大行宽 MAX_WIDTH} \
      -tooltip {行缓冲最大行宽，直接决定 BRAM 用量。} \
      -widget comboBox
  set Page1 [ipgui::add_page $IPINST -name "Page1" -display_name {优化策略 Optimization}]
  ipgui::add_param $IPINST -name "GSTRATEGY" -parent $Page1 \
      -display_name {实现分档 GSTRATEGY} \
      -tooltip {0 面积优先 / 1 平衡 / 2 性能优先；当前白名单为点操作（II=1），窗口算子落地后分档生效。} \
      -widget comboBox
  ipgui::add_param $IPINST -name "FOLD" -parent $Page1 \
      -display_name {折叠因子 FOLD} \
      -tooltip {每像素 FOLD 拍、算子复用，吞吐 1/FOLD px/clk；仅 GSTRATEGY=0（面积优先）时可编辑。} \
      -widget comboBox
}
