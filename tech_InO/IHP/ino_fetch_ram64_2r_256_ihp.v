// Technology wrapper for IHP SG13G2.
// Logical primitive: 256 x 64, two synchronous read ports + one write port.
// Two complete replicas are used.  In each replica:
//   port A = read
//   port B = common write
// Width 64 is implemented with two 32-bit macros.

module ino_fetch_ram64_2r_256 (
    input               clk_i,
    input  [7:0]    raddr0_i,
    output [63:0]        rdata0_o,
    input  [7:0]    raddr1_i,
    output [63:0]        rdata1_o,
    input               we_i,
    input  [7:0]    waddr_i,
    input  [63:0]        wdata_i
);

    // Replica 0, low 32 bits
    RM_IHPSG13_2P_256x32_c2_bm_bist u_r0_lo (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr0_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata0_o[31:0]), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i[31:0]), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(8'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

    // Replica 0, high 32 bits
    RM_IHPSG13_2P_256x32_c2_bm_bist u_r0_hi (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr0_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata0_o[63:32]), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i[63:32]), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(8'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

    // Replica 1, low 32 bits
    RM_IHPSG13_2P_256x32_c2_bm_bist u_r1_lo (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr1_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata1_o[31:0]), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i[31:0]), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(8'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

    // Replica 1, high 32 bits
    RM_IHPSG13_2P_256x32_c2_bm_bist u_r1_hi (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr1_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata1_o[63:32]), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i[63:32]), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(8'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

endmodule
