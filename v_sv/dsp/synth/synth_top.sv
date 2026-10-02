//=============================================================================
// synth_top.sv -- dsp 家族综合验证顶层 (只给 synth_check.tcl 用)
//
// 两种模式各例化一份 (rotate / vector), 端口全部引到顶层防裁剪。
// 期望: 综合零 ERROR / critical warning; vector 的增益补偿乘法映射 1 个
// DSP48 (util.rpt 可见); CORDIC 级联为纯 add/sub/shift 阵列。
//=============================================================================

`timescale 1ns / 1ps

module dsp_synth_top #(
  parameter int unsigned P = 16,
  parameter int unsigned D = 16,
  parameter int unsigned S = 16
) (
  input  logic        clk,
  input  logic        in_valid,
  input  logic [P-1:0] phase,
  input  logic [D-1:0] x,
  input  logic [D-1:0] y,
  output logic        ov_rot,
  output logic [D-1:0] sin_o,
  output logic [D-1:0] cos_o,
  output logic        ov_vec,
  output logic [D-1:0] mag_o,
  output logic [P-1:0] ph_o,
  output logic        cic_vld,
  output logic [D-1:0] cic_out
);

  dsp_cordic #(.MODE("rotate"), .P_DW(P), .D_DW(D), .STAGES(S)) u_rot (
    .clk(clk), .in_valid(in_valid), .in_phase(phase),
    .in_x(x), .in_y(y),
    .out_valid(ov_rot), .out_sin(sin_o), .out_cos(cos_o),
    .out_mag(), .out_phase());

  dsp_cordic #(.MODE("vector"), .P_DW(P), .D_DW(D), .STAGES(S),
               .GAIN_COMP(1'b1)) u_vec (
    .clk(clk), .in_valid(in_valid), .in_phase(phase),
    .in_x(x), .in_y(y),
    .out_valid(ov_vec), .out_sin(), .out_cos(),
    .out_mag(mag_o), .out_phase(ph_o));

  dsp_cic_decim #(.N(3), .R(64), .B_IN(D), .B_OUT(D), .ROUND(1'b1)) u_cic (
    .clk(clk), .rst(1'b0), .in_valid(in_valid), .in_data(sin_o[D-1:0]),
    .out_valid(cic_vld), .out_data(cic_out));

endmodule
