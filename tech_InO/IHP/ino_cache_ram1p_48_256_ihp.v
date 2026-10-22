// Technology wrapper for IHP SG13G2 (macros shared with sg13cmos5l).
// Logical primitive: INO_CACHE_RAM1P(WIDTH_G => 48, DEPTH_G => 256) of INO_DCACHE_CORE
// (vhdl_InO/M3a_INO_CACHE_RAM1P.vhd), one RM_IHPSG13_1P_256x48_c2_bm_bist:
//   en_i & !we_i : read  (A_REN = 1, A_WEN = 0) ;
//   en_i &  we_i : write of the bits selected by bm_i (A_REN = 0 : A_DOUT holds) ;
//   !en_i        : idle (A_MEN = 0 : A_DOUT holds).

module ino_cache_ram1p_48_256 (
    input           clk_i,
    input           en_i,
    input           we_i,
    input  [7:0]    addr_i,
    input  [47:0]   wdata_i,
    input  [47:0]   bm_i,
    output [47:0]   rdata_o
);

    RM_IHPSG13_1P_256x48_c2_bm_bist u_sram (
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
        .A_BIST_ADDR (8'b0),
        .A_BIST_DIN  (48'b0),
        .A_BIST_BM   (48'b0)
    );

endmodule
