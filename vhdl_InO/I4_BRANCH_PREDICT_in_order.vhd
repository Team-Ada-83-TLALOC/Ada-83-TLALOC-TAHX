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

architecture IN_ORDER of BRANCH_PREDICT is

   constant GSHARE : positive := 2 ** ghist_t'length;
   constant OP_CALLI : opcode_t := x"33";

   type ras_array_t is array(0 to RAS_DEPTH - 1) of address_t;
   type state_t is (IDLE, EVAL, OUTPUT);

   type pred_work_t is record
      g           : ghist_t;
      p           : natural range 0 to RAS_DEPTH - 1;
      rs          : ras_array_t;
      blk         : decoded_block_t;
      n           : natural range 0 to DECODE_WIDTH;
      redirect    : std_logic;
      redirect_pc : address_t;
      e           : address_t;
      cv, ct      : std_logic;
      ck, cf, cg  : address_t;
   end record;

   signal ghist : ghist_t := (others => '0');
   signal ras : ras_array_t := (others => (others => '0'));
   signal ras_ptr : natural range 0 to RAS_DEPTH - 1 := 0;
   signal dentry : address_t := (others => '0');

   signal state_q : state_t := IDLE;
   signal work_q, step_work : pred_work_t;
   signal slot_q : natural range 0 to DECODE_WIDTH - 1 := 0;
   signal step_done : std_logic;
   signal step_next_slot : natural range 0 to DECODE_WIDTH - 1;

   signal pred_addr : natural range 0 to GSHARE - 1 := 0;
   signal pred_ctr : std_logic_vector(1 downto 0);

   signal train_read_addr : natural range 0 to GSHARE - 1 := 0;
   signal train_ctr : std_logic_vector(1 downto 0);
   signal train_req_valid_q : std_logic := '0';
   signal train_req_idx_q : natural range 0 to GSHARE - 1 := 0;
   signal train_req_taken_q : std_logic := '0';
   signal train_we : std_logic;
   signal train_waddr : natural range 0 to GSHARE - 1;
   signal train_wdata : std_logic_vector(1 downto 0);
   signal last_we_q : std_logic := '0';
   signal last_waddr_q : natural range 0 to GSHARE - 1 := 0;
   signal last_wdata_q : std_logic_vector(1 downto 0) := "01";

   signal tr_valid, tr_taken : std_logic := '0';
   signal tr_key, tr_fin, tr_target : address_t := (others => '0');

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

begin

   assert DECODE_WIDTH = 4
      report "BRANCH_PREDICT(IN_ORDER) : DECODE_WIDTH doit valoir 4"
      severity failure;

   IN_READY_o <= '1' when state_q = IDLE and RECOVERY_i.valid = '0' else '0';
   OUT_VALID_o <= '1' when state_q = OUTPUT else '0';
   OUT_BLOCK_o <= work_q.blk;
   OUT_COUNT_o <= to_unsigned(work_q.n, OUT_COUNT_o'length);

   PREDICT_VALID_o <= '1' when state_q = OUTPUT and OUT_READY_i = '1' and work_q.redirect = '1' else '0';
   PREDICT_PC_o <= work_q.redirect_pc;

   TRAIN_VALID_o <= tr_valid;
   TRAIN_TAKEN_o <= tr_taken;
   TRAIN_KEY_o <= tr_key;
   TRAIN_FIN_o <= tr_fin;
   TRAIN_TARGET_o <= tr_target;

   --------------------------------------------------------------------------------
   -- Une lecture de prediction synchrone. En IDLE, l'adresse de la case 0 est
   -- presentee avant le front qui accepte le bloc. En EVAL, l'etat obtenu pour la
   -- case courante permet de presenter combinatoirement l'adresse de la suivante :
   -- apres l'amorcage, une case est donc traitee par cycle.
   --------------------------------------------------------------------------------

   PRED_ADDR_P : process(all)
   begin
      pred_addr <= 0;
      if state_q = IDLE then
         if IN_VALID_i = '1' and to_integer(IN_COUNT_i) /= 0 then
            pred_addr <= INDEX(IN_BLOCK_i(0).pc, ghist);
         end if;
      elsif state_q = EVAL then
         if step_done = '0' then
            pred_addr <= INDEX(step_work.blk(step_next_slot).pc, step_work.g);
         end if;
      end if;
   end process PRED_ADDR_P;

   --------------------------------------------------------------------------------
   -- Traitement combinatoire d'une seule case, a partir du compteur lu au cycle
   -- precedent. C'est exactement la logique de l'ancien etage SLOTi, mais partagee
   -- entre les quatre cases.
   --------------------------------------------------------------------------------

   STEP : process(all)
      variable v : pred_work_t;
      variable i : natural range 0 to DECODE_WIDTH - 1;
      variable taken : boolean;
      variable target, fin : address_t;
      variable op : opcode_t;
      variable pnew : natural range 0 to RAS_DEPTH - 1;
   begin
      v := work_q;
      i := slot_q;
      step_done <= '0';
      step_next_slot <= slot_q;

      if i < v.n then
         op := v.blk(i).canon.op;
         target := v.blk(i).pc + v.blk(i).canon.len + unsigned(resize(v.blk(i).canon.val, 64));
         fin := v.blk(i).pc + v.blk(i).canon.len - 1;

         if v.e(63 downto 5) /= fin(63 downto 5) then
            v.e := fin(63 downto 5) & "00000";
         end if;

         v.blk(i).pred := NO_PREDICTION;
         v.blk(i).pred.ghist := v.g;
         v.blk(i).pred.ras_ptr := to_unsigned(v.p, ras_ptr_t'length);
         taken := false;

         if IS_BRANCH_COND(op) then
            taken := unsigned(pred_ctr) >= 2;
            if not taken and v.cv = '0' then
               v.cv := '1';
               v.ct := '0';
               v.ck := v.e;
               v.cf := fin;
            end if;
            v.blk(i).pred.target := target;
            if taken then
               v.g := v.g(v.g'high - 1 downto 0) & '1';
            else
               v.g := v.g(v.g'high - 1 downto 0) & '0';
            end if;
         elsif IS_BRA(op) then
            taken := true;
            v.blk(i).pred.target := target;
         elsif op = OP_CALL or op = OP_CALLI then
            if op = OP_CALL then
               taken := true;
               v.blk(i).pred.target := target;
            end if;
            v.rs(v.p) := v.blk(i).pc + v.blk(i).canon.len;
            if v.p = RAS_DEPTH - 1 then pnew := 0; else pnew := v.p + 1; end if;
            v.p := pnew;
         elsif op = OP_RTD_0 or op = OP_RTD_N then
            if v.p = 0 then pnew := RAS_DEPTH - 1; else pnew := v.p - 1; end if;
            v.p := pnew;
            taken := true;
            v.blk(i).pred.target := v.rs(pnew);
         end if;

         if taken then
            v.blk(i).pred.taken := '1';
            v.n := i + 1;
            v.redirect := '1';
            v.redirect_pc := v.blk(i).pred.target;
            v.cv := '1';
            v.ct := '1';
            v.ck := v.e;
            v.cf := fin;
            v.cg := v.blk(i).pred.target;
            v.e := v.blk(i).pred.target;
            step_done <= '1';
         elsif i + 1 >= v.n then
            step_done <= '1';
         else
            step_next_slot <= i + 1;
         end if;
      else
         step_done <= '1';
      end if;

      step_work <= v;
   end process STEP;

   --------------------------------------------------------------------------------
   -- Apprentissage gshare. Le port 1 lit la branche retiree au front N ; au front
   -- N+1 son compteur est disponible et la mise a jour est ecrite. Le bypass du
   -- dernier write corrige le cas de deux retraits consecutifs au meme indice avec
   -- une RAM read-before-write.
   --------------------------------------------------------------------------------

   train_read_addr <= INDEX(RETIRE_i(0).pc, RETIRE_i(0).ghist)
      when RETIRE_i(0).valid = '1' else 0;

   train_we <= train_req_valid_q when RESET_i = '0' else '0';
   train_waddr <= train_req_idx_q;

   TRAIN_DATA : process(all)
      variable base : unsigned(1 downto 0);
   begin
      base := unsigned(train_ctr);
      if last_we_q = '1' and last_waddr_q = train_req_idx_q then
         base := unsigned(last_wdata_q);
      end if;

      if train_req_taken_q = '1' then
         if base < 3 then base := base + 1; end if;
      elsif base > 0 then
         base := base - 1;
      end if;
      train_wdata <= std_logic_vector(base);
   end process TRAIN_DATA;

   U_GSHARE : entity work.INO_PRED_RAM2_2R(SYNC)
      generic map (DEPTH_G => GSHARE)
      port map (
         CLK_i => CLK_i,
         RADDR0_i => pred_addr,       RDATA0_o => pred_ctr,
         RADDR1_i => train_read_addr, RDATA1_o => train_ctr,
         WE_i => train_we, WADDR_i => train_waddr, WDATA_i => train_wdata );

   --------------------------------------------------------------------------------
   -- Etat. Une reprise annule un bloc en cours : il appartient potentiellement au
   -- mauvais chemin. L'etat speculatif n'est valide qu'au transfert de la sortie.
   --------------------------------------------------------------------------------

   ETAT : process(CLK_i)
      variable v : pred_work_t;
      variable n0 : natural;
   begin
      if rising_edge(CLK_i) then
         if RESET_i = '1' then
            ghist <= (others => '0');
            ras <= (others => (others => '0'));
            ras_ptr <= 0;
            dentry <= (others => '0');
            state_q <= IDLE;
            slot_q <= 0;
            tr_valid <= '0';
            train_req_valid_q <= '0';
            last_we_q <= '0';
         else
            tr_valid <= '0';

            -- Pipeline d'apprentissage, independant du moteur de prediction.
            train_req_valid_q <= RETIRE_i(0).valid and RETIRE_i(0).is_control and RETIRE_i(0).conditional;
            train_req_idx_q <= train_read_addr;
            train_req_taken_q <= RETIRE_i(0).taken;
            last_we_q <= train_we;
            if train_we = '1' then
               last_waddr_q <= train_waddr;
               last_wdata_q <= train_wdata;
            end if;

            if RECOVERY_i.valid = '1' then
               ghist <= RECOVERY_i.ghist;
               ras_ptr <= to_integer(RECOVERY_i.ras_ptr);
               dentry <= RECOVERY_i.new_pc;
               state_q <= IDLE;
               slot_q <= 0;
            else
               case state_q is
                  when IDLE =>
                     if IN_VALID_i = '1' then
                        v.g := ghist;
                        v.p := ras_ptr;
                        v.rs := ras;
                        v.blk := IN_BLOCK_i;
                        n0 := to_integer(IN_COUNT_i);
                        if n0 > DECODE_WIDTH then v.n := DECODE_WIDTH; else v.n := n0; end if;
                        v.redirect := '0';
                        v.redirect_pc := (others => '0');
                        v.e := dentry;
                        v.cv := '0';
                        v.ct := '0';
                        v.ck := (others => '0');
                        v.cf := (others => '0');
                        v.cg := (others => '0');
                        work_q <= v;
                        slot_q <= 0;
                        if n0 = 0 then state_q <= OUTPUT; else state_q <= EVAL; end if;
                     end if;

                  when EVAL =>
                     work_q <= step_work;
                     if step_done = '1' then
                        state_q <= OUTPUT;
                     else
                        slot_q <= step_next_slot;
                     end if;

                  when OUTPUT =>
                     if OUT_READY_i = '1' then
                        ghist <= work_q.g;
                        ras <= work_q.rs;
                        ras_ptr <= work_q.p;
                        dentry <= work_q.e;
                        tr_valid <= work_q.cv;
                        tr_taken <= work_q.ct;
                        tr_key <= work_q.ck;
                        tr_fin <= work_q.cf;
                        tr_target <= work_q.cg;
                        state_q <= IDLE;
                     end if;
               end case;
            end if;
         end if;
      end if;
   end process ETAT;

end architecture IN_ORDER;
