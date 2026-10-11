// Technology wrapper for IHP SG13G2.
// Logical primitive: two replicas of 65536 x 2 bits.
// Each replica is packed as 4096 x 32 bits (16 counters/word)
// and banked over four 2P SRAMs of 1024 x 32.
//
// Port A of every physical SRAM is used for synchronous read.
// Port B is used for the common write broadcast to both logical replicas.
//
// NOTE: unlike the portable RTL, physical SRAM has no guaranteed power-up
// contents.  Architectural initialization to "01" must therefore be handled
// separately before predictions are trusted.

module ino_pred_ram2_2r_65536 (
    input         clk_i,
    input  [15:0] raddr0_i,
    output [1:0]  rdata0_o,
    input  [15:0] raddr1_i,
    output [1:0]  rdata1_o,
    input         we_i,
    input  [15:0] waddr_i,
    input  [1:0]  wdata_i
);

    wire [9:0] rword0 = raddr0_i[13:4];
    wire [9:0] rword1 = raddr1_i[13:4];
    wire [9:0] wword  = waddr_i [13:4];

    wire [1:0] rbank0 = raddr0_i[15:14];
    wire [1:0] rbank1 = raddr1_i[15:14];
    wire [1:0] wbank  = waddr_i [15:14];

    reg [1:0] rbank0_q;
    reg [1:0] rbank1_q;
    reg [3:0] rsel0_q;
    reg [3:0] rsel1_q;

    always @(posedge clk_i) begin
        rbank0_q <= rbank0;
        rbank1_q <= rbank1;
        rsel0_q  <= raddr0_i[3:0];
        rsel1_q  <= raddr1_i[3:0];
    end

    wire [31:0] wdata32 = {16{wdata_i}};
    wire [31:0] wmask32 = 32'h00000003 << {waddr_i[3:0], 1'b0};

    wire [31:0] pred_q0, pred_q1, pred_q2, pred_q3;
    wire [31:0] train_q0, train_q1, train_q2, train_q3;

    wire [31:0] pred_word =
        (rbank0_q == 2'd0) ? pred_q0 :
        (rbank0_q == 2'd1) ? pred_q1 :
        (rbank0_q == 2'd2) ? pred_q2 : pred_q3;

    wire [31:0] train_word =
        (rbank1_q == 2'd0) ? train_q0 :
        (rbank1_q == 2'd1) ? train_q1 :
        (rbank1_q == 2'd2) ? train_q2 : train_q3;

    wire [31:0] pred_shifted  = pred_word  >> {rsel0_q, 1'b0};
    wire [31:0] train_shifted = train_word >> {rsel1_q, 1'b0};

    assign rdata0_o = pred_shifted[1:0];
    assign rdata1_o = train_shifted[1:0];

    // Prediction replica ----------------------------------------------------
    RM_IHPSG13_2P_1024x32_c2_bm_bist p0 (
        .A_CLK(clk_i), .A_MEN(rbank0 == 2'd0), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword0), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(pred_q0), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd0)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );
    RM_IHPSG13_2P_1024x32_c2_bm_bist p1 (
        .A_CLK(clk_i), .A_MEN(rbank0 == 2'd1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword0), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(pred_q1), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd1)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );
    RM_IHPSG13_2P_1024x32_c2_bm_bist p2 (
        .A_CLK(clk_i), .A_MEN(rbank0 == 2'd2), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword0), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(pred_q2), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd2)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );
    RM_IHPSG13_2P_1024x32_c2_bm_bist p3 (
        .A_CLK(clk_i), .A_MEN(rbank0 == 2'd3), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword0), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(pred_q3), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd3)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

    // Training replica ------------------------------------------------------
    RM_IHPSG13_2P_1024x32_c2_bm_bist t0 (
        .A_CLK(clk_i), .A_MEN(rbank1 == 2'd0), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword1), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(train_q0), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd0)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );
    RM_IHPSG13_2P_1024x32_c2_bm_bist t1 (
        .A_CLK(clk_i), .A_MEN(rbank1 == 2'd1), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword1), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(train_q1), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd1)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );
    RM_IHPSG13_2P_1024x32_c2_bm_bist t2 (
        .A_CLK(clk_i), .A_MEN(rbank1 == 2'd2), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword1), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(train_q2), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd2)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );
    RM_IHPSG13_2P_1024x32_c2_bm_bist t3 (
        .A_CLK(clk_i), .A_MEN(rbank1 == 2'd3), .A_WEN(1'b0), .A_REN(1'b1),
        .A_ADDR(rword1), .A_DIN(32'b0), .A_DLY(1'b1), .A_DOUT(train_q3), .A_BM(32'b0),
        .B_CLK(clk_i), .B_MEN(we_i && (wbank == 2'd3)), .B_WEN(we_i), .B_REN(1'b0),
        .B_ADDR(wword), .B_DIN(wdata32), .B_DLY(1'b1), .B_DOUT(), .B_BM(wmask32),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0), .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0),
        .B_BIST_REN(1'b0), .B_BIST_ADDR(10'b0), .B_BIST_DIN(32'b0), .B_BIST_BM(32'b0)
    );

endmodule
