yosys -p 'read_ilang tahx_1_in_order_opt.il; chformal -remove; clean -purge; write_verilog -noattr tahx_1_in_order.v'
