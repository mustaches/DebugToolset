# Vivado IP Packager：把 isp_ip_multi_band_eq_axis 打包为可定制 IP（参数在 Customize IP
# 界面可改）。用法：vivado -mode batch -source package_ip.tcl
set ip_name isp_ip_multi_band_eq
create_project -in_memory -part xczu3eg-sbva484-1-e
add_files isp_ip_multi_band_eq_core.v
add_files isp_ip_multi_band_eq_top.v
add_files isp_ip_multi_band_eq_axis.v
update_compile_order -fileset sources_1
ipx::package_project -root_dir ./ip_repo -vendor debugtoolset -library isp \
    -taxonomy /UserIP
set_property name $ip_name [ipx::current_core]
set_property display_name "isp_ip_multi_band_eq (ISP Studio)" [ipx::current_core]
set_property vendor_display_name "DebugToolSet" [ipx::current_core]
# 参数组（Customize IP 界面）：
ipx::add_user_parameter PIX_BITS [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters PIX_BITS]
set_property value 8 [ipx::get_user_parameters PIX_BITS]
ipx::add_user_parameter MAX_WIDTH [ipx::current_core]
set_property value 4096 [ipx::get_user_parameters MAX_WIDTH]
# 优化策略（当前白名单为点操作，预留窗口算子分档；GUI 可改）。
ipx::add_user_parameter GSTRATEGY [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters GSTRATEGY]
set_property value 0 [ipx::get_user_parameters GSTRATEGY]
ipx::add_user_parameter FOLD [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters FOLD]
set_property value 4 [ipx::get_user_parameters FOLD]
# 取值合法性（组合列表校验，与定制界面下拉同源）：
set_property value_validation_type list [ipx::get_user_parameters PIX_BITS]
set_property value_validation_list {8 10 12 14 16} [ipx::get_user_parameters PIX_BITS]
set_property value_validation_type list [ipx::get_user_parameters MAX_WIDTH]
set_property value_validation_list {640 1280 1920 2048 4096 8192} [ipx::get_user_parameters MAX_WIDTH]
set_property value_validation_type list [ipx::get_user_parameters GSTRATEGY]
set_property value_validation_list {0 1 2} [ipx::get_user_parameters GSTRATEGY]
set_property value_validation_type list [ipx::get_user_parameters FOLD]
set_property value_validation_list {1 2 4} [ipx::get_user_parameters FOLD]
# FOLD 仅面积档（GSTRATEGY=0）可编辑；旧版 Vivado 不支持该属性时静默跳过。
catch {
  set_property enablement_tcl_expr {$GSTRATEGY == 0} \
    [ipx::get_model_parameters FOLD -of_objects [ipx::current_core]]
}
set_property supported_families {zynquplus} [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::check_integrity [ipx::current_core]
# 定制界面（xgui tcl）拷入组件目录（Vivado 打开 Customize IP 时读取）：
set xguiDir "./ip_repo/$ip_name/xgui"
file mkdir $xguiDir
file copy -force -- "xgui/isp_ip_multi_band_eq_v1_0.tcl" $xguiDir/
puts "IP 已打包到 ./ip_repo"
