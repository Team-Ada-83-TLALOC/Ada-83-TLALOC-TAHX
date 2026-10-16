// Technology wrapper for IHP SG13G2 (macros shared with sg13cmos5l).
// Logical primitive: 512 x 32, one synchronous read port + one write port
// (INO_FETCH_RAM_1R : data and PC-line tag of the FETCH_UNIT(IN_ORDER) cache).
// One 2P 512x32 macro per 32-bit slice:
//   port A = read
//   port B = write

module ino_fetch_ram_1r_32_512 (
    input               clk_i,
    input  [8:0]        raddr_i,
    output [31:0]       rdata_o,
    input               we_i,
    input  [8:0]        waddr_i,
    input  [31:0]       wdata_i
);

    // w0 : bits 31..0
    RM_IHPSG13_2P_512x32_c2_bm_bist u_w0 (
        .A_CLK(clk_i), .A_MEN(1'b1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(raddr_i), .A_DIN(32'b0), .A_DLY(1'b1),
        .A_DOUT(rdata_o[31:0]), .A_BM(32'b0),

        .B_CLK(clk_i), .B_MEN(we_i), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(waddr_i), .B_DIN(wdata_i[31:0]), .B_DLY(1'b1),
        .B_DOUT(), .B_BM(32'hFFFFFFFF),

        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(9'b0),
        .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(9'b0),
        .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

endmodule
