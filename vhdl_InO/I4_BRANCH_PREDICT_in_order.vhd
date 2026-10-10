library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;

        --------------------------------------------------------------------------------
        -- BRANCH_PREDICT, architecture IN_ORDER.
        --
        -- Meme contrat de prediction que RTL, mais la table gshare n'est plus un
        -- tableau de 65536 entiers mis a jour jusqu'a RETIRE_WIDTH fois par front.
        -- Le coeur InO ne retire qu'une instruction par cycle : une RAM explicite
        -- 65536 x 2 fournit quatre lectures de prediction et une lecture
        -- d'apprentissage, avec une seule ecriture par cycle.
        --
        -- Le RAS (32 x 64) reste volontairement en registres pour cette premiere
        -- etape : il est petit et permet de mesurer separement le gain du gshare.
        --
        -- La RAM gshare est initialisee a "01" a l'elaboration, comme le modele de
        -- reference. RESET remet ghist/RAS/dentry a leur etat initial mais ne balaie
        -- pas les 65536 compteurs ; un RESET reasserted apres fonctionnement conserve
        -- donc l'apprentissage. Cela n'affecte que la performance, jamais la
        -- correction architecturale.
        --------------------------------------------------------------------------------

architecture IN_ORDER of BRANCH_PREDICT is

   constant GSHARE : positive := 2 ** ghist_t'length;
   constant OP_CALLI : opcode_t := x"33";

   type ras_array_t is array(0 to RAS_DEPTH - 1) of address_t;
   type idx_array_t is array(0 to DECODE_WIDTH - 1) of natural range 0 to GSHARE - 1;
   type ctr_array_t is array(0 to DECODE_WIDTH - 1) of std_logic_vector(1 downto 0);

   signal ghist : ghist_t;
   signal ras : ras_array_t := (others => (others => '0'));
   signal ras_ptr : natural range 0 to RAS_DEPTH - 1;

   signal next_ghist : ghist_t;
   signal next_ras : ras_array_t;
   signal next_ras_ptr : natural range 0 to RAS_DEPTH - 1;
   signal out_cnt : natural range 0 to DECODE_WIDTH;

   signal dentry, next_dentry : address_t;
   signal tr_valid, tr_taken : std_logic;
   signal tr_key, tr_fin, tr_target : address_t;
   signal c_valid, c_taken : std_logic;
   signal c_key, c_fin, c_target : address_t;

   -- Gshare explicite.
   signal pred_idx : idx_array_t;
   signal pred_ctr : ctr_array_t;
   signal train_idx : natural range 0 to GSHARE - 1;
   signal train_ctr : std_logic_vector(1 downto 0);
   signal train_we : std_logic;
   signal train_wdata : std_logic_vector(1 downto 0);

   -- Etat combinatoire apres chaque case. Chaque etage ne lit que l'etat
   -- produit par l'etage precedent : le graphe logique est donc acyclique
   -- par construction (contrairement au processus imperatif avec for/exit).
   type pred_stage_t is record
      g           : ghist_t;
      p           : natural range 0 to RAS_DEPTH - 1;
      rs          : ras_array_t;
      blk         : decoded_block_t;
      n           : natural range 0 to DECODE_WIDTH;
      stopped     : std_logic;
      redirect    : std_logic;
      redirect_pc : address_t;
      e           : address_t;
      cv, ct      : std_logic;
      ck, cf, cg  : address_t;
   end record;

   signal s0, s1, s2, s3, s4 : pred_stage_t;

   function IS_BRANCH_COND(op : opcode_t) return boolean is
   begin
      return unsigned(op) >= 16#E4# and unsigned(op) <= 16#EB#;
   end function;

   function IS_BRA(op : opcode_t) return boolean is
   begin
      return unsigned(op) >= 16#E0# and unsigned(op) <= 16#E3#;
   end function;

   function INDEX(pc : address_t; h : ghist_t) return natural is
   begin
      return to_integer(unsigned(std_logic_vector(pc(15 downto 0)) xor h));
   end function;

   function AFTER_COND_GHIST(slot : decoded_slot_t;
                             ctr  : std_logic_vector(1 downto 0);
                             h    : ghist_t) return ghist_t is
   begin
      if IS_BRANCH_COND(slot.canon.op) then
         if unsigned(ctr) >= 2 then
            return h(h'high - 1 downto 0) & '1';
         else
            return h(h'high - 1 downto 0) & '0';
         end if;
      end if;
      return h;
   end function;

begin

   assert DECODE_WIDTH = 4
      report "BRANCH_PREDICT(IN_ORDER) : la RAM gshare suppose DECODE_WIDTH = 4"
      severity failure;

   OUT_VALID_o <= IN_VALID_i;
   IN_READY_o <= OUT_READY_i;
   OUT_COUNT_o <= to_unsigned(out_cnt, OUT_COUNT_o'length);
   TRAIN_VALID_o <= tr_valid;
   TRAIN_TAKEN_o <= tr_taken;
   TRAIN_KEY_o <= tr_key;
   TRAIN_FIN_o <= tr_fin;
   TRAIN_TARGET_o <= tr_target;

   --------------------------------------------------------------------------------
   -- Prediction deroulee en quatre etages combinatoires explicites.
   --
   -- s0 est l'etat avant la case 0 ; s1 celui apres la case 0, etc.
   -- Une case prise positionne stopped, de sorte que les etages suivants recopient
   -- simplement l'etat sans le modifier. Cette ecriture exprime directement le
   -- materiel souhaite et evite les retroactions artificielles que GHDL creait
   -- avec les variables relues/reecrites dans un for comportant exit.
   --------------------------------------------------------------------------------

   STAGE_INIT : process(all)
      variable v : pred_stage_t;
      variable n0 : natural;
   begin
      v.g := ghist;
      v.p := ras_ptr;
      v.rs := ras;
      v.blk := IN_BLOCK_i;
      n0 := to_integer(IN_COUNT_i);
      if n0 > DECODE_WIDTH then
         v.n := DECODE_WIDTH;
      else
         v.n := n0;
      end if;
      v.stopped := '0';
      v.redirect := '0';
      v.redirect_pc := (others => '0');
      v.e := dentry;
      v.cv := '0';
      v.ct := '0';
      v.ck := (others => '0');
      v.cf := (others => '0');
      v.cg := (others => '0');
      s0 <= v;
   end process STAGE_INIT;

   pred_idx(0) <= INDEX(IN_BLOCK_i(0).pc, s0.g);
   pred_idx(1) <= INDEX(IN_BLOCK_i(1).pc, s1.g);
   pred_idx(2) <= INDEX(IN_BLOCK_i(2).pc, s2.g);
   pred_idx(3) <= INDEX(IN_BLOCK_i(3).pc, s3.g);

   SLOT0 : process(all)
      variable v : pred_stage_t;
      variable taken : boolean;
      variable target, fin : address_t;
      variable op : opcode_t;
      variable pnew : natural range 0 to RAS_DEPTH - 1;
   begin
      v := s0;
      if v.stopped = '0' and 0 < v.n then
         op := v.blk(0).canon.op;
         target := v.blk(0).pc + v.blk(0).canon.len + unsigned(resize(v.blk(0).canon.val, 64));
         fin := v.blk(0).pc + v.blk(0).canon.len - 1;
         if v.e(63 downto 5) /= fin(63 downto 5) then
            v.e := fin(63 downto 5) & "00000";
         end if;
         v.blk(0).pred := NO_PREDICTION;
         v.blk(0).pred.ghist := v.g;
         v.blk(0).pred.ras_ptr := to_unsigned(v.p, ras_ptr_t'length);
         taken := false;

         if IS_BRANCH_COND(op) then
            taken := unsigned(pred_ctr(0)) >= 2;
            if not taken and v.cv = '0' then
               v.cv := '1'; v.ct := '0'; v.ck := v.e; v.cf := fin;
            end if;
            v.blk(0).pred.target := target;
            if taken then v.g := v.g(v.g'high - 1 downto 0) & '1';
            else          v.g := v.g(v.g'high - 1 downto 0) & '0'; end if;
         elsif IS_BRA(op) then
            taken := true;
            v.blk(0).pred.target := target;
         elsif op = OP_CALL or op = OP_CALLI then
            if op = OP_CALL then
               taken := true;
               v.blk(0).pred.target := target;
            end if;
            v.rs(v.p) := v.blk(0).pc + v.blk(0).canon.len;
            if v.p = RAS_DEPTH - 1 then pnew := 0; else pnew := v.p + 1; end if;
            v.p := pnew;
         elsif op = OP_RTD_0 or op = OP_RTD_N then
            if v.p = 0 then pnew := RAS_DEPTH - 1; else pnew := v.p - 1; end if;
            v.p := pnew;
            taken := true;
            v.blk(0).pred.target := v.rs(pnew);
         end if;

         if taken then
            v.blk(0).pred.taken := '1';
            v.n := 1;
            v.stopped := '1';
            v.redirect := '1';
            v.redirect_pc := v.blk(0).pred.target;
            v.cv := '1'; v.ct := '1'; v.ck := v.e; v.cf := fin; v.cg := v.blk(0).pred.target;
            v.e := v.blk(0).pred.target;
         end if;
      end if;
      s1 <= v;
   end process SLOT0;

   SLOT1 : process(all)
      variable v : pred_stage_t;
      variable taken : boolean;
      variable target, fin : address_t;
      variable op : opcode_t;
      variable pnew : natural range 0 to RAS_DEPTH - 1;
   begin
      v := s1;
      if v.stopped = '0' and 1 < v.n then
         op := v.blk(1).canon.op;
         target := v.blk(1).pc + v.blk(1).canon.len + unsigned(resize(v.blk(1).canon.val, 64));
         fin := v.blk(1).pc + v.blk(1).canon.len - 1;
         if v.e(63 downto 5) /= fin(63 downto 5) then
            v.e := fin(63 downto 5) & "00000";
         end if;
         v.blk(1).pred := NO_PREDICTION;
         v.blk(1).pred.ghist := v.g;
         v.blk(1).pred.ras_ptr := to_unsigned(v.p, ras_ptr_t'length);
         taken := false;

         if IS_BRANCH_COND(op) then
            taken := unsigned(pred_ctr(1)) >= 2;
            if not taken and v.cv = '0' then
               v.cv := '1'; v.ct := '0'; v.ck := v.e; v.cf := fin;
            end if;
            v.blk(1).pred.target := target;
            if taken then v.g := v.g(v.g'high - 1 downto 0) & '1';
            else          v.g := v.g(v.g'high - 1 downto 0) & '0'; end if;
         elsif IS_BRA(op) then
            taken := true;
            v.blk(1).pred.target := target;
         elsif op = OP_CALL or op = OP_CALLI then
            if op = OP_CALL then
               taken := true;
               v.blk(1).pred.target := target;
            end if;
            v.rs(v.p) := v.blk(1).pc + v.blk(1).canon.len;
            if v.p = RAS_DEPTH - 1 then pnew := 0; else pnew := v.p + 1; end if;
            v.p := pnew;
         elsif op = OP_RTD_0 or op = OP_RTD_N then
            if v.p = 0 then pnew := RAS_DEPTH - 1; else pnew := v.p - 1; end if;
            v.p := pnew;
            taken := true;
            v.blk(1).pred.target := v.rs(pnew);
         end if;

         if taken then
            v.blk(1).pred.taken := '1';
            v.n := 2;
            v.stopped := '1';
            v.redirect := '1';
            v.redirect_pc := v.blk(1).pred.target;
            v.cv := '1'; v.ct := '1'; v.ck := v.e; v.cf := fin; v.cg := v.blk(1).pred.target;
            v.e := v.blk(1).pred.target;
         end if;
      end if;
      s2 <= v;
   end process SLOT1;

   SLOT2 : process(all)
      variable v : pred_stage_t;
      variable taken : boolean;
      variable target, fin : address_t;
      variable op : opcode_t;
      variable pnew : natural range 0 to RAS_DEPTH - 1;
   begin
      v := s2;
      if v.stopped = '0' and 2 < v.n then
         op := v.blk(2).canon.op;
         target := v.blk(2).pc + v.blk(2).canon.len + unsigned(resize(v.blk(2).canon.val, 64));
         fin := v.blk(2).pc + v.blk(2).canon.len - 1;
         if v.e(63 downto 5) /= fin(63 downto 5) then
            v.e := fin(63 downto 5) & "00000";
         end if;
         v.blk(2).pred := NO_PREDICTION;
         v.blk(2).pred.ghist := v.g;
         v.blk(2).pred.ras_ptr := to_unsigned(v.p, ras_ptr_t'length);
         taken := false;

         if IS_BRANCH_COND(op) then
            taken := unsigned(pred_ctr(2)) >= 2;
            if not taken and v.cv = '0' then
               v.cv := '1'; v.ct := '0'; v.ck := v.e; v.cf := fin;
            end if;
            v.blk(2).pred.target := target;
            if taken then v.g := v.g(v.g'high - 1 downto 0) & '1';
            else          v.g := v.g(v.g'high - 1 downto 0) & '0'; end if;
         elsif IS_BRA(op) then
            taken := true;
            v.blk(2).pred.target := target;
         elsif op = OP_CALL or op = OP_CALLI then
            if op = OP_CALL then
               taken := true;
               v.blk(2).pred.target := target;
            end if;
            v.rs(v.p) := v.blk(2).pc + v.blk(2).canon.len;
            if v.p = RAS_DEPTH - 1 then pnew := 0; else pnew := v.p + 1; end if;
            v.p := pnew;
         elsif op = OP_RTD_0 or op = OP_RTD_N then
            if v.p = 0 then pnew := RAS_DEPTH - 1; else pnew := v.p - 1; end if;
            v.p := pnew;
            taken := true;
            v.blk(2).pred.target := v.rs(pnew);
         end if;

         if taken then
            v.blk(2).pred.taken := '1';
            v.n := 3;
            v.stopped := '1';
            v.redirect := '1';
            v.redirect_pc := v.blk(2).pred.target;
            v.cv := '1'; v.ct := '1'; v.ck := v.e; v.cf := fin; v.cg := v.blk(2).pred.target;
            v.e := v.blk(2).pred.target;
         end if;
      end if;
      s3 <= v;
   end process SLOT2;

   SLOT3 : process(all)
      variable v : pred_stage_t;
      variable taken : boolean;
      variable target, fin : address_t;
      variable op : opcode_t;
      variable pnew : natural range 0 to RAS_DEPTH - 1;
   begin
      v := s3;
      if v.stopped = '0' and 3 < v.n then
         op := v.blk(3).canon.op;
         target := v.blk(3).pc + v.blk(3).canon.len + unsigned(resize(v.blk(3).canon.val, 64));
         fin := v.blk(3).pc + v.blk(3).canon.len - 1;
         if v.e(63 downto 5) /= fin(63 downto 5) then
            v.e := fin(63 downto 5) & "00000";
         end if;
         v.blk(3).pred := NO_PREDICTION;
         v.blk(3).pred.ghist := v.g;
         v.blk(3).pred.ras_ptr := to_unsigned(v.p, ras_ptr_t'length);
         taken := false;

         if IS_BRANCH_COND(op) then
            taken := unsigned(pred_ctr(3)) >= 2;
            if not taken and v.cv = '0' then
               v.cv := '1'; v.ct := '0'; v.ck := v.e; v.cf := fin;
            end if;
            v.blk(3).pred.target := target;
            if taken then v.g := v.g(v.g'high - 1 downto 0) & '1';
            else          v.g := v.g(v.g'high - 1 downto 0) & '0'; end if;
         elsif IS_BRA(op) then
            taken := true;
            v.blk(3).pred.target := target;
         elsif op = OP_CALL or op = OP_CALLI then
            if op = OP_CALL then
               taken := true;
               v.blk(3).pred.target := target;
            end if;
            v.rs(v.p) := v.blk(3).pc + v.blk(3).canon.len;
            if v.p = RAS_DEPTH - 1 then pnew := 0; else pnew := v.p + 1; end if;
            v.p := pnew;
         elsif op = OP_RTD_0 or op = OP_RTD_N then
            if v.p = 0 then pnew := RAS_DEPTH - 1; else pnew := v.p - 1; end if;
            v.p := pnew;
            taken := true;
            v.blk(3).pred.target := v.rs(pnew);
         end if;

         if taken then
            v.blk(3).pred.taken := '1';
            v.n := 4;
            v.stopped := '1';
            v.redirect := '1';
            v.redirect_pc := v.blk(3).pred.target;
            v.cv := '1'; v.ct := '1'; v.ck := v.e; v.cf := fin; v.cg := v.blk(3).pred.target;
            v.e := v.blk(3).pred.target;
         end if;
      end if;
      s4 <= v;
   end process SLOT3;

   OUT_BLOCK_o <= s4.blk;
   out_cnt <= s4.n;
   next_ghist <= s4.g;
   next_ras <= s4.rs;
   next_ras_ptr <= s4.p;
   PREDICT_PC_o <= s4.redirect_pc;
   next_dentry <= s4.e;
   c_valid <= s4.cv;
   c_taken <= s4.ct;
   c_key <= s4.ck;
   c_fin <= s4.cf;
   c_target <= s4.cg;
   PREDICT_VALID_o <= '1' when s4.redirect = '1' and IN_VALID_i = '1' and OUT_READY_i = '1' else '0';

   -- L'InO n'emet qu'une entree RETIRE valide, en position 0.
   train_idx <= INDEX(RETIRE_i(0).pc, RETIRE_i(0).ghist);

   TRAIN_COUNTER : process(RETIRE_i, train_ctr, RESET_i)
      variable v : unsigned(1 downto 0);
   begin
      train_we <= '0';
      train_wdata <= train_ctr;
      v := unsigned(train_ctr);

      if RESET_i = '0'
         and RETIRE_i(0).valid = '1'
         and RETIRE_i(0).is_control = '1'
         and RETIRE_i(0).conditional = '1' then
         train_we <= '1';
         if RETIRE_i(0).taken = '1' then
            if v < 3 then v := v + 1; end if;
         elsif v > 0 then
            v := v - 1;
         end if;
         train_wdata <= std_logic_vector(v);
      end if;
   end process TRAIN_COUNTER;

   U_GSHARE : entity work.INO_PRED_RAM2_5R(RTL)
      generic map (DEPTH_G => GSHARE)
      port map (
         CLK_i => CLK_i,
         RADDR0_i => pred_idx(0), RDATA0_o => pred_ctr(0),
         RADDR1_i => pred_idx(1), RDATA1_o => pred_ctr(1),
         RADDR2_i => pred_idx(2), RDATA2_o => pred_ctr(2),
         RADDR3_i => pred_idx(3), RDATA3_o => pred_ctr(3),
         RADDR4_i => train_idx,   RDATA4_o => train_ctr,
         WE_i => train_we, WADDR_i => train_idx, WDATA_i => train_wdata );

   --------------------------------------------------------------------------------
   -- Etat speculatif. L'apprentissage gshare est realise par U_GSHARE ; il ne
   -- reste ici que ghist/RAS/dentry et l'apprentissage du BT de FETCH_UNIT.
   --------------------------------------------------------------------------------

   ETAT : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         if RESET_i = '1' then
            ghist <= (others => '0');
            ras <= (others => (others => '0'));
            ras_ptr <= 0;
            dentry <= (others => '0');
            tr_valid <= '0';
         else
            tr_valid <= '0';
            if RECOVERY_i.valid = '1' then
               ghist <= RECOVERY_i.ghist;
               ras_ptr <= to_integer(RECOVERY_i.ras_ptr);
               dentry <= RECOVERY_i.new_pc;
            elsif IN_VALID_i = '1' and OUT_READY_i = '1' then
               ghist <= next_ghist;
               ras <= next_ras;
               ras_ptr <= next_ras_ptr;
               dentry <= next_dentry;
               tr_valid <= c_valid;
               tr_taken <= c_taken;
               tr_key <= c_key;
               tr_fin <= c_fin;
               tr_target <= c_target;
            end if;
         end if;
      end if;
   end process ETAT;

end architecture IN_ORDER;
