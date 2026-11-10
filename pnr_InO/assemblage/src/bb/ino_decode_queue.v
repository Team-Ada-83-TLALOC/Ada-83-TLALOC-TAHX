/* boite noire, ecrite par extraire_sommet.sh */
(* blackbox *)
module ino_decode_queue(clk_i, reset_i, flush_i, push_block_i, push_count_i, push_valid_i, pop_take_i, push_ready_o, \pop_slot_o.valid , \pop_slot_o.canon , \pop_slot_o.pc , \pop_slot_o.pred );
  input clk_i;
  wire clk_i;
  input flush_i;
  wire flush_i;
  output [55:0] \pop_slot_o.canon ;
  wire [55:0] \pop_slot_o.canon ;
  output [31:0] \pop_slot_o.pc ;
  wire [31:0] \pop_slot_o.pc ;
  output [53:0] \pop_slot_o.pred ;
  wire [53:0] \pop_slot_o.pred ;
  output \pop_slot_o.valid ;
  wire \pop_slot_o.valid ;
  input pop_take_i;
  wire pop_take_i;
  input [571:0] push_block_i;
  wire [571:0] push_block_i;
  input [3:0] push_count_i;
  wire [3:0] push_count_i;
  output push_ready_o;
  wire push_ready_o;
  input push_valid_i;
  wire push_valid_i;
  input reset_i;
  wire reset_i;
endmodule
