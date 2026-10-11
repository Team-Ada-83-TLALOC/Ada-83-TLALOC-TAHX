// Technology wrapper for IHP SG13G2.
// Logical primitive: 256 x 64, synchronous read, synchronous write.
// IMPORTANT: this mapping assumes re_i and we_i are never asserted together,
// because the selected IHP macro is single-port.

module ino_cache_ram64_256 (
    input         clk_i,
    input         re_i,
    input  [7:0]  raddr_i,
    input         we_i,
    input  [7:0]  waddr_i,
    input  [63:0] wdata_i,
    output [63:0] rdata_o
);

    wire [7:0] addr = we_i ? waddr_i : raddr_i;

    RM_IHPSG13_1P_256x64_c2_bm_bist u_sram (
        .A_CLK       (clk_i),
        .A_MEN       (re_i | we_i),
        .A_WEN       (we_i),
        .A_REN       (re_i),
        .A_ADDR      (addr),
        .A_DIN       (wdata_i),
        .A_DLY       (1'b1),
        .A_DOUT      (rdata_o),
        .A_BM        (64'hFFFFFFFFFFFFFFFF),

        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR (8'b0),
        .A_BIST_DIN  (64'b0),
        .A_BIST_BM   (64'b0)
    );

endmodule
