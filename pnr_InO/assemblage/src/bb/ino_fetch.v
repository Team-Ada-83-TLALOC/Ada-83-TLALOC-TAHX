/* boite noire, ecrite par extraire_sommet.sh */
(* blackbox *)
module ino_fetch(clk_i, reset_i, halt_i, icache_invalidate_i, i_ready_i, i_rvalid_i, i_rdata_i, i_fault_i, consume_i, consumed_bytes_i, decode_stop_i, predict_valid_i, predict_pc_i, recovery_valid_i, recovery_pc_i, i_req_o, i_addr_o, window_o, window_count_o, window_pc_o, window_fault_o
);
  input clk_i;
  wire clk_i;
  input consume_i;
  wire consume_i;
  input [5:0] consumed_bytes_i;
  wire [5:0] consumed_bytes_i;
  input decode_stop_i;
  wire decode_stop_i;
  input halt_i;
  wire halt_i;
  output [31:0] i_addr_o;
  wire [31:0] i_addr_o;
  input i_fault_i;
  wire i_fault_i;
  input [63:0] i_rdata_i;
  wire [63:0] i_rdata_i;
  input i_ready_i;
  wire i_ready_i;
  output i_req_o;
  wire i_req_o;
  input i_rvalid_i;
  wire i_rvalid_i;
  input icache_invalidate_i;
  wire icache_invalidate_i;
  input [31:0] predict_pc_i;
  wire [31:0] predict_pc_i;
  input predict_valid_i;
  wire predict_valid_i;
  input [31:0] recovery_pc_i;
  wire [31:0] recovery_pc_i;
  input recovery_valid_i;
  wire recovery_valid_i;
  input reset_i;
  wire reset_i;
  output [5:0] window_count_o;
  wire [5:0] window_count_o;
  output [31:0] window_fault_o;
  wire [31:0] window_fault_o;
  output [255:0] window_o;
  wire [255:0] window_o;
  output [31:0] window_pc_o;
  wire [31:0] window_pc_o;
endmodule
