/* boite noire, ecrite par extraire_sommet.sh */
(* blackbox *)
module ino_exec_arith(clk_i, reset_i, issue_valid_i, issue_class_i, issue_op_i, issue_a_i, issue_b_i, issue_c_i, sync_valid_i, ready_o, complete_valid_o, complete_result_valid_o, complete_result_o, \complete_fault_o.valid , \complete_fault_o.code );
  input clk_i;
  wire clk_i;
  output [7:0] \complete_fault_o.code ;
  wire [7:0] \complete_fault_o.code ;
  output \complete_fault_o.valid ;
  wire \complete_fault_o.valid ;
  output [63:0] complete_result_o;
  wire [63:0] complete_result_o;
  output complete_result_valid_o;
  wire complete_result_valid_o;
  output complete_valid_o;
  wire complete_valid_o;
  input [63:0] issue_a_i;
  wire [63:0] issue_a_i;
  input [63:0] issue_b_i;
  wire [63:0] issue_b_i;
  input [63:0] issue_c_i;
  wire [63:0] issue_c_i;
  input [2:0] issue_class_i;
  wire [2:0] issue_class_i;
  input [7:0] issue_op_i;
  wire [7:0] issue_op_i;
  input issue_valid_i;
  wire issue_valid_i;
  output [2:0] ready_o;
  wire [2:0] ready_o;
  input reset_i;
  wire reset_i;
  input sync_valid_i;
  wire sync_valid_i;
endmodule
