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
use work.INO_PADDR.all;

architecture IN_ORDER of BRANCH_PREDICT is

   -- Taille de la table gshare : 2 ** GSHARE_BITS compteurs (9 : 512, en
   -- bascules ; 16 : 64 K, la table de l'etude de limites). 9 depuis le 26 octobre :
   -- avec le traitement par groupes (etude IPC x f), la table de 1 K rendait
   -- ino_decode_predict trop dense pour le routage ; 512 compteurs : surface de la
   -- macro -23 %, cycles +0,11 % sur les 8 bancs (G8 : -35 %, +0,23 %). Doit valoir
   -- RETIRE_PC_BITS de I5a_INO_FRONT_PA.vhd (bits du pc transmis au retrait).
   -- L'indice est forme des GSHARE_BITS bits faibles de pc xor ghist ;
   -- l'historique garde ses ghist_t'length bits. Le changer ne touche que la
   -- performance (variantes VARIANTES/G*.txt des bancs).
   constant GSHARE_BITS : positive := 9;
   constant GSHARE : positive := 2 ** GSHARE_BITS;
   constant OP_CALLI : opcode_t := x"33";

   -- Pile des retours propre a l'InO : RAS_N entrees (RAS_DEPTH, partage avec l'OoO,
   -- vaut 32). Le pointeur transporte dans pred.ras_ptr reste un ras_ptr_t modulo
   -- 2**ras_ptr_t'length ; RAS_N doit diviser ce modulo pour que la reprise
   -- (pointeur reduit modulo RAS_N) soit exacte.
   constant RAS_N : positive := 8;
   type ras_array_t is array(0 to RAS_N - 1) of address_t;
   type state_t is (IDLE, EVAL, OUTPUT);

   type pred_work_t is record
      g           : ghist_t;
      p           : natural range 0 to RAS_N - 1;
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
   signal ras_ptr : natural range 0 to RAS_N - 1 := 0;
   signal dentry : address_t := (others => '0');

   signal state_q : state_t := IDLE;
   signal work_q, step_work : pred_work_t;
   signal slot_q : natural range 0 to DECODE_WIDTH - 1 := 0;
   -- pragma translate_off
   -- Observation (N3_INO_PLATEFORME) : etat de l'automate, state_t'pos.
   signal obs_pred_s : natural := 0;
   -- pragma translate_on
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

   -- Espace physique InO (INO_PADDR) : toute adresse memorisee (bloc en cours, pile
   -- des retours, entree attendue, apprentissage) ne garde que PA_BITS bits.
   function CUT_BLOCK(b : decoded_block_t) return decoded_block_t is
      variable r : decoded_block_t := b;
   begin
      for k in r'range loop
         r(k).pc := CUT(b(k).pc);
         r(k).pred.target := CUT(b(k).pred.target);
      end loop;
      return r;
   end function;

   -- Toutes les adresses de l'etat de travail. La synthese ne propage les zeros de
   -- CUT qu'a travers un registre : il faut donc couper a chaque ecriture de
   -- registre, y compris dans les boucles ras <-> work_q.rs et dentry <-> work_q.e.
   function CUT_RAS(r : ras_array_t) return ras_array_t is
      variable x : ras_array_t;
   begin
      for k in r'range loop
         x(k) := CUT(r(k));
      end loop;
      return x;
   end function;

   function CUT_WORK(w : pred_work_t) return pred_work_t is
      variable x : pred_work_t := w;
   begin
      x.rs          := CUT_RAS(w.rs);
      x.blk         := CUT_BLOCK(w.blk);
      x.redirect_pc := CUT(w.redirect_pc);
      x.e           := CUT(w.e);
      x.ck          := CUT(w.ck);
      x.cf          := CUT(w.cf);
      x.cg          := CUT(w.cg);
      return x;
   end function;

   function INDEX(pc : address_t; h : ghist_t) return natural is
   begin
      return to_integer(unsigned(std_logic_vector(pc(GSHARE_BITS - 1 downto 0))
                                 xor h(GSHARE_BITS - 1 downto 0)));
   end function;

begin

   assert ( 2 ** ras_ptr_t'length ) mod RAS_N = 0
      report "BRANCH_PREDICT(IN_ORDER) : RAS_N doit diviser 2**ras_ptr_t'length" severity failure;

   assert GSHARE_BITS <= ghist_t'length
      report "BRANCH_PREDICT(IN_ORDER) : GSHARE_BITS ne peut depasser ghist_t'length" severity failure;

   assert DECODE_WIDTH = 4
      report "BRANCH_PREDICT(IN_ORDER) : DECODE_WIDTH doit valoir 4"
      severity failure;

   -- pragma translate_off
   obs_pred_s <= state_t'pos(state_q);
   -- pragma translate_on
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
   -- presentee avant le front qui accepte le bloc. En EVAL, l'etat obtenu pour les
   -- cases traitees dans le cycle permet de presenter combinatoirement l'adresse du
   -- branchement conditionnel suivant (step_next_slot).
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
   -- Traitement combinatoire d'un groupe de cases (etude IPC x f, 25 octobre) : la
   -- case slot_q, dont le compteur gshare a ete lu au cycle precedent, puis, dans le
   -- meme cycle, les cases suivantes tant qu'elles n'ont pas besoin d'un compteur
   -- (tout sauf un branchement conditionnel). Le groupe s'arrete sur un transfert
   -- pris (fin du bloc), ou avant le branchement conditionnel suivant, dont le
   -- compteur est lu pour le cycle suivant (step_next_slot). Chaque case suit la
   -- logique de l'ancien etage SLOTi ; seules changent les cases traitees par cycle.
   -- Un bloc sans branchement conditionnel passe ainsi IDLE, EVAL, OUTPUT (3 cycles
   -- au lieu de 2 + n), et la famine du frontal, surtout faite de cycles EVAL, baisse.
   --------------------------------------------------------------------------------

   STEP : process(all)
      variable v : pred_work_t;
      variable taken : boolean;
      variable target, fin : address_t;
      variable op : opcode_t;
      variable pnew : natural range 0 to RAS_N - 1;
      variable fini, arret : boolean;
   begin
      v := work_q;
      step_done <= '0';
      step_next_slot <= slot_q;
      fini := false;
      arret := false;

      for i in 0 to DECODE_WIDTH - 1 loop
         if not fini and not arret and i >= slot_q then
            if i >= v.n then
               fini := true;
            elsif i /= slot_q and IS_BRANCH_COND(v.blk(i).canon.op) then
               arret := true;
               step_next_slot <= i;
            else
               op := v.blk(i).canon.op;
               target := CUT(v.blk(i).pc + v.blk(i).canon.len + unsigned(resize(v.blk(i).canon.val, 64)));
               fin := CUT(v.blk(i).pc + v.blk(i).canon.len - 1);

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
                  v.rs(v.p) := CUT(v.blk(i).pc + v.blk(i).canon.len);
                  if v.p = RAS_N - 1 then pnew := 0; else pnew := v.p + 1; end if;
                  v.p := pnew;
               elsif op = OP_RTD_0 or op = OP_RTD_N then
                  if v.p = 0 then pnew := RAS_N - 1; else pnew := v.p - 1; end if;
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
                  fini := true;
               end if;
            end if;
         end if;
      end loop;

      if not arret then
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

   U_GSHARE : entity work.INO_PRED_TABLE2_2R(FF)
      generic map (DEPTH_G => GSHARE)
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
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
               ras_ptr <= to_integer(RECOVERY_i.ras_ptr) mod RAS_N;
               dentry <= CUT(RECOVERY_i.new_pc);
               state_q <= IDLE;
               slot_q <= 0;
            else
               case state_q is
                  when IDLE =>
                     if IN_VALID_i = '1' then
                        v.g := ghist;
                        v.p := ras_ptr;
                        v.rs := ras;
                        v.blk := CUT_BLOCK(IN_BLOCK_i);
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
                        work_q <= CUT_WORK(v);
                        slot_q <= 0;
                        if n0 = 0 then state_q <= OUTPUT; else state_q <= EVAL; end if;
                     end if;

                  when EVAL =>
                     work_q <= CUT_WORK(step_work);
                     if step_done = '1' then
                        state_q <= OUTPUT;
                     else
                        slot_q <= step_next_slot;
                     end if;

                  when OUTPUT =>
                     if OUT_READY_i = '1' then
                        ghist <= work_q.g;
                        ras <= CUT_RAS(work_q.rs);
                        ras_ptr <= work_q.p;
                        dentry <= CUT(work_q.e);
                        tr_valid <= work_q.cv;
                        tr_taken <= work_q.ct;
                        tr_key <= CUT(work_q.ck);
                        tr_fin <= CUT(work_q.cf);
                        tr_target <= CUT(work_q.cg);
                        state_q <= IDLE;
                     end if;
               end case;
            end if;
         end if;
      end if;
   end process ETAT;

end architecture IN_ORDER;
