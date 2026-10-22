// Technology wrapper for IHP SG13G2 (macros shared with sg13cmos5l).
// Logical primitive: INO_CACHE_RAM1P(WIDTH_G => 64, DEPTH_G => 1024) of INO_DCACHE_CORE
// (vhdl_InO/M3a_INO_CACHE_RAM1P.vhd), one RM_IHPSG13_1P_1024x64_c2_bm_bist:
//   en_i & !we_i : read  (A_REN = 1, A_WEN = 0) ;
//   en_i &  we_i : write of the bits selected by bm_i (A_REN = 0 : A_DOUT holds) ;
//   !en_i        : idle (A_MEN = 0 : A_DOUT holds).

module ino_cache_ram1p_64_1024 (
    input           clk_i,
    input           en_i,
    input           we_i,
    input  [9:0]    addr_i,
    input  [63:0]   wdata_i,
    input  [63:0]   bm_i,
    output [63:0]   rdata_o
);

    RM_IHPSG13_1P_1024x64_c2_bm_bist u_sram (
        .A_CLK       (clk_i),
        .A_MEN       (en_i),
        .A_WEN       (we_i),
        .A_REN       (~we_i),
        .A_ADDR      (addr_i),
        .A_DIN       (wdata_i),
        .A_DLY       (1'b1),
        .A_DOUT      (rdata_o),
        .A_BM        (bm_i),

        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR (10'b0),
        .A_BIST_DIN  (64'b0),
        .A_BIST_BM   (64'b0)
    );

endmodule
