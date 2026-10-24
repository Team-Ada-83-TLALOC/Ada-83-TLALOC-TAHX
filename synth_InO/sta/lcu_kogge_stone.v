// Unite de retenue ($lcu) en Kogge-Stone : profondeur log2(WIDTH) au lieu de WIDTH
// (implantation par defaut de Yosys 0.33 : propagation). Meme fonction que
// techlibs/common/choices/kogge-stone.v des versions recentes de Yosys.
(* techmap_celltype = "$lcu" *)
module _80_lcu_kogge_stone (P, G, CI, CO);
   parameter WIDTH = 2;
   (* force_downto *) input [WIDTH-1:0] P, G;
   input CI;
   (* force_downto *) output [WIDTH-1:0] CO;
   integer i, j;
   (* force_downto *) reg [WIDTH-1:0] p, g;
   always @* begin
      p = P;
      g = G;
      g[0] = g[0] | ( p[0] & CI );
      for ( i = 0; i < $clog2( WIDTH ); i = i + 1 ) begin
         for ( j = WIDTH - 1; j >= 2 ** i; j = j - 1 ) begin
            g[j] = g[j] | ( p[j] & g[j - 2 ** i] );
            p[j] = p[j] & p[j - 2 ** i];
         end
      end
   end
   assign CO = g;
endmodule
