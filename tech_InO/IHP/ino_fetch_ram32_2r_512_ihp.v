// Technology wrapper for IHP SG13G2 (macros shared with sg13cmos5l).
// Logical primitive: 512 x 32, two synchronous read ports + one write port
// (INO_FETCH_RAM32_2R : tags and block table of FETCH_UNIT(IN_ORDER)).
// Two complete replicas, one per read port.  In each replica:
//   port A = read
//   port B = common write

module ino_fetch_ram32_2r_512 (
    input               clk_i,
    input  [8:0]        raddr0_i,
    output [31:0]       rdata0_o,
    input  [8:0]        raddr1_i,
    output [31:0]       rdata1_o,
    input               we_i,
    input  [8:0]        waddr_i,
    input  [31:0]       wdata_i
);

    // r0
    RM_IHPSG13_2P_512x32_c2_bm_bist u_r0 (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr0_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata0_o), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(9'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(9'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

    // r1
    RM_IHPSG13_2P_512x32_c2_bm_bist u_r1 (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr1_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata1_o), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(9'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(9'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

endmodule
