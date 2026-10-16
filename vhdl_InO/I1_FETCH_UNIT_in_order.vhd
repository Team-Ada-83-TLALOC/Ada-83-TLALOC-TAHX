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

        --------------------------------------------------------------------------------
        -- FETCH_UNIT, architecture IN_ORDER.
        --
        -- Meme contrat fonctionnel que l'architecture RTL commune, mais le tableau
        -- data(512 x 32 octets) est remplace par quatre RAM explicites 512 x 64 bits.
        -- Chaque RAM possede deux lectures : ligne du PC et ligne de la cible BT.
        -- Les reponses de remplissage sont ecrites directement, mot par mot, dans
        -- la banque correspondante. present n'est valide qu'apres le dernier mot.
        --
        -- La table BT est elle aussi materiellement explicite : key, fin et target
        -- sont trois RAM 256 x 32 a deux lectures (adresses physiques), le compteur
        -- une table 256 x 2 en bascules (INO_PRED_TABLE2_2R) ; seul le vecteur
        -- valid (256 bits) masque les entrees apres RESET.
        --
        -- Espace physique InO (INO_PADDR) : le PC est toujours realisable (les
        -- transferts vers une adresse non realisable fautent a l'execution). Toute
        -- adresse memorisee ici (registres, tags, table de blocs, tampon de cible)
        -- passe par CUT et ne garde que PA_BITS bits ; les sorties des RAM de tags et
        -- de la table de blocs sont relues par CUT. Une cible predite non realisable
        -- (speculative) est donc tronquee : le transfert fautera avant qu'aucune
        -- instruction chargee a sa suite ne s'execute.
        --
        -- Les tags sont eux aussi en RAM synchrone (deux instances 512 x 32 a deux
        -- lectures, l'adresse de ligne physique) : U_TAG lit les lignes du PC et de la cible BT, aux memes
        -- adresses et au meme front que les banques de donnees ; U_TAG_NX lit les
        -- deux lignes suivantes pour le prechargement. Seul present (512 bits)
        -- reste en bascules, pour le RESET.
        --------------------------------------------------------------------------------

architecture IN_ORDER of FETCH_UNIT is

   constant LINES : positive := 512;
   constant WORDS : positive := FETCH_BLOCK_SIZE / 8;

   signal present  : std_logic_vector(0 to LINES - 1);

   -- Sorties des RAM de tags. Comme pour les donnees, elles correspondent aux
   -- adresses presentes avant le dernier front.
   signal cur_tag, tgt_tag  : word64_t;
   signal nx1_tag, nx2_tag  : word64_t;
   -- Sorties 32 bits des RAM de tags (adresses physiques), etendues de zeros.
   signal cur_tag32, tgt_tag32, nx1_tag32, nx2_tag32 : std_logic_vector(31 downto 0);
   signal tag_we            : std_logic;
   signal nx1_index         : natural range 0 to LINES - 1;
   signal nx2_index         : natural range 0 to LINES - 1;
   signal ram_nx1_fresh_q   : std_logic;
   signal ram_nx2_fresh_q   : std_logic;
   -- Les sorties de U_TAG (port 0) correspondent au PC courant et sont fraiches.
   signal cur_lookup        : std_logic;

   signal pc       : address_t;
   signal active   : std_logic;

   signal fault_valid : std_logic;
   signal fault_line  : address_t;

   signal filling    : std_logic;
   signal fill_line  : address_t;
   signal fill_fault : std_logic;
   signal req_k, resp_k : natural range 0 to WORDS;

   signal line_base       : address_t;
   signal index           : natural range 0 to LINES - 1;
   signal target_index    : natural range 0 to LINES - 1;
   signal fill_index      : natural range 0 to LINES - 1;
   signal hit, faulty_hit : std_logic;
   signal next1, next2    : address_t;
   signal miss1, miss2    : std_logic;
   signal redirect        : std_logic;
   signal show            : std_logic;

   -- Quatre mots de la ligne courante et quatre mots de la ligne cible BT.
   type words4_t is array(0 to WORDS - 1) of word64_t;
   signal cur_word, tgt_word : words4_t;
   signal bank_we : std_logic_vector(0 to WORDS - 1);

   -- Avec les RAM synchrones, les donnees visibles apres un front correspondent
   -- aux adresses presentes avant ce front. Conserver ces adresses permet de ne
   -- presenter un bloc que lorsque donnees et PC/cible sont bien alignes.
   signal ram_cur_pc_q       : address_t;
   signal ram_tgt_target_q   : address_t;
   signal ram_cur_valid_q    : std_logic;
   signal ram_tgt_valid_q    : std_logic;
   signal ram_cur_fresh_q    : std_logic;
   signal ram_tgt_fresh_q    : std_logic;

   -- Table de blocs : version materielle explicite.
   -- key/fin/target/ctr sont quatre petites RAM 256 x 64.  Le bit valid reste
   -- dans un vecteur de 256 bits afin que RESET puisse invalider toute la table
   -- sans imposer de remise a zero aux RAM.
   constant BT_ENTRIES : positive := 256;
   signal bt_valid : std_logic_vector(0 to BT_ENTRIES - 1);
   signal bt_lookup_idx, bt_train_idx : natural range 0 to BT_ENTRIES - 1;
   signal bt_key_cur, bt_fin_cur, bt_target_cur, bt_ctr_cur : word64_t;
   signal bt_key_train, bt_fin_train, bt_target_train, bt_ctr_train : word64_t;
   signal bt_key_we, bt_fin_we, bt_target_we, bt_ctr_we : std_logic;
   signal bt_ctr_wdata : word64_t;
   -- Sorties 32 bits de la table de blocs, 2 bits pour le compteur.
   signal bt_key_cur32, bt_fin_cur32, bt_target_cur32 : std_logic_vector(31 downto 0);
   signal bt_key_train32, bt_fin_train32, bt_target_train32 : std_logic_vector(31 downto 0);
   signal bt_ctr_cur2, bt_ctr_train2 : std_logic_vector(1 downto 0);
   signal bt_taken_match, bt_nottaken_match : boolean;

   -- Les deux ports de la BT sont synchrones.  Ces registres identifient
   -- exactement la requete dont les quatre sorties RAM sont la reponse.
   signal bt_lookup_valid_q : std_logic;
   signal bt_lookup_pc_q    : address_t;
   signal train_valid_q     : std_logic;
   signal train_taken_q     : std_logic;
   signal train_key_q       : address_t;
   signal train_fin_q       : address_t;
   signal train_target_q    : address_t;
   signal bt_train_idx_q    : natural range 0 to BT_ENTRIES - 1;

   constant TB_ENTRIES : positive := 4;
   type tb_valid_t is array(0 to TB_ENTRIES - 1) of boolean;
   type tb_pc_t    is array(0 to TB_ENTRIES - 1) of address_t;
   type tb_block_t is array(0 to TB_ENTRIES - 1) of fetch_block_t;
   signal tb_valid : tb_valid_t;
   signal tb_pc    : tb_pc_t;
   signal tb_block : tb_block_t;
   signal tb_next  : natural range 0 to TB_ENTRIES - 1;
   signal tb_sel   : natural range 0 to TB_ENTRIES - 1;
   signal tb_has   : boolean;
   signal bt_target : address_t;
   signal bt_load   : boolean;
   signal preload   : std_logic;

   function LINE_OF(a : address_t) return address_t is
   begin
      return a(a'high downto 5) & "00000";
   end function;

   function INDEX_OF(a : address_t) return natural is
   begin
      return to_integer(a(13 downto 5));
   end function;

   function BT_IDX(a : address_t) return natural is
   begin
      return to_integer(a(12 downto 5) xor ("000" & a(4 downto 0)));
   end function;

   function BYTE_OF_WORD(w : word64_t; b : natural) return byte_t is
   begin
      case b is
         when 0 => return w( 7 downto  0);
         when 1 => return w(15 downto  8);
         when 2 => return w(23 downto 16);
         when 3 => return w(31 downto 24);
         when 4 => return w(39 downto 32);
         when 5 => return w(47 downto 40);
         when 6 => return w(55 downto 48);
         when others => return w(63 downto 56);
      end case;
   end function;

   function BYTE_OF_LINE(w : words4_t; p : natural) return byte_t is
   begin
      case p / 8 is
         when 0 => return BYTE_OF_WORD(w(0), p mod 8);
         when 1 => return BYTE_OF_WORD(w(1), p mod 8);
         when 2 => return BYTE_OF_WORD(w(2), p mod 8);
         when others => return BYTE_OF_WORD(w(3), p mod 8);
      end case;
   end function;

begin

   assert LINES = 512 report "FETCH_UNIT(IN_ORDER) : INDEX_OF suppose 512 lignes" severity failure;
   assert WORDS = 4 report "FETCH_UNIT(IN_ORDER) : quatre mots par ligne attendus" severity failure;

   line_base     <= LINE_OF(pc);
   index         <= INDEX_OF(pc);
   fill_index    <= INDEX_OF(fill_line);
   bt_lookup_idx <= BT_IDX(pc);
   bt_train_idx  <= BT_IDX(TRAIN_KEY_i);
   target_index  <= INDEX_OF(bt_target);

   -- Le tag lu au front precedent n'est utilisable que s'il correspond au PC
   -- courant et qu'aucune ecriture n'a eu lieu sur sa case a ce front. Dans ce
   -- cas il est egal au contenu actuel : hit est alors identique a l'ancien hit
   -- calcule sur un tableau asynchrone.
   cur_lookup <= '1' when ram_cur_valid_q = '1' and ram_cur_fresh_q = '1'
                          and ram_cur_pc_q = pc else '0';
   hit        <= '1' when cur_lookup = '1' and present(index) = '1'
                          and CUT(unsigned(cur_tag)) = line_base else '0';
   faulty_hit <= '1' when fault_valid = '1' and fault_line = line_base else '0';
   redirect   <= RECOVERY_i.valid or PREDICT_VALID_i or STOP_i;
   next1      <= CUT(line_base + FETCH_BLOCK_SIZE);
   next2      <= CUT(line_base + 2 * FETCH_BLOCK_SIZE);
   nx1_index  <= INDEX_OF(next1);
   nx2_index  <= INDEX_OF(next2);
   -- miss1/miss2 ne servent qu'avec hit = '1', donc quand nx1_tag/nx2_tag ont ete
   -- lus pour le PC courant. Une sortie non fraiche suspend le prechargement.
   miss1      <= '1' when ram_nx1_fresh_q = '1'
                          and (present(nx1_index) = '0' or CUT(unsigned(nx1_tag)) /= next1)
                          and not (fault_valid = '1' and fault_line = next1) else '0';
   miss2      <= '1' when ram_nx2_fresh_q = '1'
                          and (present(nx2_index) = '0' or CUT(unsigned(nx2_tag)) /= next2)
                          and not (fault_valid = '1' and fault_line = next2) else '0';
   show <= active and (hit or faulty_hit) and not redirect and cur_lookup;
   FLUSH_o <= redirect;

   -- Les quatre RAM de donnees. Un mot de reponse est ecrit directement dans sa banque.
   GEN_BANKS : for k in 0 to WORDS - 1 generate
      bank_we(k) <= '1' when filling = '1' and I_RVALID_i = '1' and resp_k = k else '0';

      U_RAM : entity work.INO_FETCH_RAM64_2R(SYNC)
         generic map (DEPTH_G => LINES)
         port map (
            CLK_i    => CLK_i,
            RADDR0_i => index,
            RDATA0_o => cur_word(k),
            RADDR1_i => target_index,
            RDATA1_o => tgt_word(k),
            WE_i     => bank_we(k),
            WADDR_i  => fill_index,
            WDATA_i  => I_RDATA_i );
   end generate GEN_BANKS;

   -- Le tag est ecrit au front du dernier mot d'un remplissage sans faute, en
   -- meme temps que present(fill_index) passe a '1'.
   tag_we <= '1' when filling = '1' and I_RVALID_i = '1' and resp_k = WORDS - 1
                      and fill_fault = '0' and I_FAULT_i = '0' else '0';

   -- Tags de la ligne du PC et de la ligne cible BT : memes adresses que les
   -- banques, donc meme alignement temporel que cur_word / tgt_word.
   U_TAG : entity work.INO_FETCH_RAM32_2R(SYNC)
      generic map (DEPTH_G => LINES)
      port map (
         CLK_i    => CLK_i,
         RADDR0_i => index,
         RDATA0_o => cur_tag32,
         RADDR1_i => target_index,
         RDATA1_o => tgt_tag32,
         WE_i     => tag_we,
         WADDR_i  => fill_index,
         WDATA_i  => std_logic_vector(TO_PA(fill_line)) );

   -- Replique pour le prechargement des deux lignes suivantes.
   U_TAG_NX : entity work.INO_FETCH_RAM32_2R(SYNC)
      generic map (DEPTH_G => LINES)
      port map (
         CLK_i    => CLK_i,
         RADDR0_i => nx1_index,
         RDATA0_o => nx1_tag32,
         RADDR1_i => nx2_index,
         RDATA1_o => nx2_tag32,
         WE_i     => tag_we,
         WADDR_i  => fill_index,
         WDATA_i  => std_logic_vector(TO_PA(fill_line)) );

   -- Les tags sont relus par CUT : l'extension de zeros donne la meme valeur.
   cur_tag <= x"00000000" & cur_tag32;
   tgt_tag <= x"00000000" & tgt_tag32;
   nx1_tag <= x"00000000" & nx1_tag32;
   nx2_tag <= x"00000000" & nx2_tag32;

   -- Table de blocs : trois RAM explicites 256 x 32 et une table 256 x 2 en
   -- bascules, deux lectures (lookup du PC et apprentissage) et une ecriture
   -- synchrone.
   U_BT_KEY : entity work.INO_FETCH_RAM32_2R(SYNC)
      generic map (DEPTH_G => BT_ENTRIES)
      port map (
         CLK_i => CLK_i,
         RADDR0_i => bt_lookup_idx, RDATA0_o => bt_key_cur32,
         RADDR1_i => bt_train_idx,  RDATA1_o => bt_key_train32,
         WE_i => bt_key_we, WADDR_i => bt_train_idx_q, WDATA_i => std_logic_vector(TO_PA(train_key_q)) );

   U_BT_FIN : entity work.INO_FETCH_RAM32_2R(SYNC)
      generic map (DEPTH_G => BT_ENTRIES)
      port map (
         CLK_i => CLK_i,
         RADDR0_i => bt_lookup_idx, RDATA0_o => bt_fin_cur32,
         RADDR1_i => bt_train_idx,  RDATA1_o => bt_fin_train32,
         WE_i => bt_fin_we, WADDR_i => bt_train_idx_q, WDATA_i => std_logic_vector(TO_PA(train_fin_q)) );

   U_BT_TARGET : entity work.INO_FETCH_RAM32_2R(SYNC)
      generic map (DEPTH_G => BT_ENTRIES)
      port map (
         CLK_i => CLK_i,
         RADDR0_i => bt_lookup_idx, RDATA0_o => bt_target_cur32,
         RADDR1_i => bt_train_idx,  RDATA1_o => bt_target_train32,
         WE_i => bt_target_we, WADDR_i => bt_train_idx_q, WDATA_i => std_logic_vector(TO_PA(train_target_q)) );

   -- Compteur : 2 bits utiles ; table en bascules (la remise a "01" au RESET
   -- est sans effet : bt_valid masque les entrees, et une entree creee ecrit "10").
   U_BT_CTR : entity work.INO_PRED_TABLE2_2R(FF)
      generic map (DEPTH_G => BT_ENTRIES)
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         RADDR0_i => bt_lookup_idx, RDATA0_o => bt_ctr_cur2,
         RADDR1_i => bt_train_idx,  RDATA1_o => bt_ctr_train2,
         WE_i => bt_ctr_we, WADDR_i => bt_train_idx_q, WDATA_i => bt_ctr_wdata(1 downto 0) );

   -- Relues par CUT (adresses) ou par leurs 2 bits faibles (compteur).
   bt_key_cur      <= x"00000000" & bt_key_cur32;
   bt_fin_cur      <= x"00000000" & bt_fin_cur32;
   bt_target_cur   <= x"00000000" & bt_target_cur32;
   bt_key_train    <= x"00000000" & bt_key_train32;
   bt_fin_train    <= x"00000000" & bt_fin_train32;
   bt_target_train <= x"00000000" & bt_target_train32;
   bt_ctr_cur      <= ( 63 downto 2 => '0' ) & bt_ctr_cur2;
   bt_ctr_train    <= ( 63 downto 2 => '0' ) & bt_ctr_train2;

   bt_target <= CUT(unsigned(bt_target_cur));
   bt_load   <= bt_lookup_valid_q = '1' and active = '1'
                and bt_lookup_pc_q = pc
                and bt_valid(BT_IDX(bt_lookup_pc_q)) = '1'
                and CUT(unsigned(bt_key_cur)) = bt_lookup_pc_q
                and unsigned(bt_ctr_cur(1 downto 0)) >= to_unsigned(2, 2)
                and present(INDEX_OF(bt_target)) = '1'
                -- tgt_tag a ete lu pour ram_tgt_target_q, egal a bt_target ci-dessous.
                and CUT(unsigned(tgt_tag)) = LINE_OF(bt_target)
                and ram_tgt_valid_q = '1' and ram_tgt_target_q = bt_target
                and ram_tgt_fresh_q = '1';

   bt_taken_match <= train_valid_q = '1'
                     and bt_valid(bt_train_idx_q) = '1'
                     and CUT(unsigned(bt_key_train)) = train_key_q
                     and CUT(unsigned(bt_fin_train)) = train_fin_q
                     and CUT(unsigned(bt_target_train)) = train_target_q;
   bt_nottaken_match <= train_valid_q = '1'
                        and bt_valid(bt_train_idx_q) = '1'
                        and CUT(unsigned(bt_key_train)) = train_key_q
                        and CUT(unsigned(bt_fin_train)) = train_fin_q;

   -- Signaux d'ecriture de l'apprentissage.  Le contenu des RAM n'a pas besoin
   -- d'etre initialise : bt_valid masque les entrees apres RESET.
   BT_TRAIN_WRITE : process(RESET_i, train_valid_q, train_taken_q,
                            bt_taken_match, bt_nottaken_match, bt_ctr_train)
      variable c : unsigned(1 downto 0);
   begin
      bt_key_we    <= '0';
      bt_fin_we    <= '0';
      bt_target_we <= '0';
      bt_ctr_we    <= '0';
      bt_ctr_wdata <= (others => '0');
      c := unsigned(bt_ctr_train(1 downto 0));

      if RESET_i = '0' and train_valid_q = '1' then
         if train_taken_q = '1' then
            if bt_taken_match then
               if c < to_unsigned(3, 2) then
                  bt_ctr_we <= '1';
                  bt_ctr_wdata(1 downto 0) <= std_logic_vector(c + 1);
               end if;
            else
               bt_key_we    <= '1';
               bt_fin_we    <= '1';
               bt_target_we <= '1';
               bt_ctr_we    <= '1';
               bt_ctr_wdata(1 downto 0) <= "10";
            end if;
         elsif bt_nottaken_match and c > to_unsigned(0, 2) then
            bt_ctr_we <= '1';
            bt_ctr_wdata(1 downto 0) <= std_logic_vector(c - 1);
         end if;
      end if;
   end process BT_TRAIN_WRITE;

   TAMPONS : process(tb_valid, tb_pc, PREDICT_VALID_i, PREDICT_PC_i, RECOVERY_i, bt_target)
      variable found : boolean;
      variable sel   : natural range 0 to TB_ENTRIES - 1;
   begin
      found := false;
      sel := 0;
      tb_has <= false;
      for k in 0 to TB_ENTRIES - 1 loop
         if tb_valid(k) and tb_pc(k) = CUT(PREDICT_PC_i) then
            found := true;
            sel := k;
         end if;
         if tb_valid(k) and tb_pc(k) = bt_target then
            tb_has <= true;
         end if;
      end loop;
      tb_sel <= sel;
      if PREDICT_VALID_i = '1' and RECOVERY_i.valid = '0' and found then
         preload <= '1';
      else
         preload <= '0';
      end if;
   end process TAMPONS;

   PRELOAD_VALID_o <= preload;
   PRELOAD_PC_o    <= tb_pc(tb_sel);
   PRELOAD_BLOCK_o <= tb_block(tb_sel);
   PRELOAD_COUNT_o <= to_unsigned(FETCH_BLOCK_SIZE - to_integer(tb_pc(tb_sel)(4 downto 0)), PRELOAD_COUNT_o'length);

   FETCH_VALID_o <= show;
   FETCH_PC_o    <= pc;
   FETCH_COUNT_o <= to_unsigned(FETCH_BLOCK_SIZE - to_integer(pc(4 downto 0)), FETCH_COUNT_o'length);
   FETCH_FAULT_o <= faulty_hit and not hit;

   BLOC : process(pc, cur_word)
      variable off : natural range 0 to FETCH_BLOCK_SIZE - 1;
   begin
      off := to_integer(pc(4 downto 0));
      for i in 0 to FETCH_BLOCK_SIZE - 1 loop
         if off + i < FETCH_BLOCK_SIZE then
            FETCH_BLOCK_o(i) <= BYTE_OF_LINE(cur_word, off + i);
         else
            FETCH_BLOCK_o(i) <= (others => '0');
         end if;
      end loop;
   end process BLOC;

   I_REQ_o  <= '1' when filling = '1' and req_k < WORDS else '0';
   I_ADDR_o <= fill_line + 8 * req_k;

   CHARGEMENT : process(CLK_i)
      variable ff       : std_logic;
      variable new_line : address_t;
      variable new_idx  : natural range 0 to LINES - 1;
   begin
      if rising_edge(CLK_i) then
         if RESET_i = '1' then
            active <= '0';
            present <= (others => '0');
            tb_valid <= (others => false);
            tb_next <= 0;
            bt_valid <= (others => '0');
            bt_lookup_valid_q <= '0';
            train_valid_q <= '0';
            train_taken_q <= '0';
            bt_train_idx_q <= 0;
            ram_cur_valid_q <= '0';
            ram_tgt_valid_q <= '0';
            ram_cur_fresh_q <= '0';
            ram_tgt_fresh_q <= '0';
            ram_nx1_fresh_q <= '0';
            ram_nx2_fresh_q <= '0';
            fault_valid <= '0';
            filling <= '0';
            fill_fault <= '0';
            req_k <= 0;
            resp_k <= 0;
         else
            -- Alignement des requetes de la BT avec les sorties de ses RAM
            -- synchrones. Les valeurs capturees ici sont celles dont les RAM
            -- fournissent la reponse juste apres ce meme front.
            bt_lookup_pc_q    <= pc;
            bt_lookup_valid_q <= active;
            train_valid_q     <= TRAIN_VALID_i;
            train_taken_q     <= TRAIN_TAKEN_i;
            train_key_q       <= CUT(TRAIN_KEY_i);
            train_fin_q       <= CUT(TRAIN_FIN_i);
            train_target_q    <= CUT(TRAIN_TARGET_i);
            bt_train_idx_q    <= BT_IDX(TRAIN_KEY_i);

            -- Les sorties des quatre banques apres ce front correspondent aux
            -- adresses qui etaient presentes avant le front.
            ram_cur_pc_q     <= pc;
            ram_tgt_target_q <= bt_target;
            ram_cur_valid_q  <= '1';
            ram_tgt_valid_q  <= '1';

            -- Une lecture et une ecriture de la meme case au meme front rendent
            -- l'ancienne valeur dans notre modele synchrone (et le comportement
            -- physique dependrait de la macro). La ligne n'est donc declaree
            -- fraiche qu'apres un front supplementaire sans ecriture sur sa case.
            if filling = '1' and I_RVALID_i = '1' and fill_index = index then
               ram_cur_fresh_q <= '0';
            else
               ram_cur_fresh_q <= '1';
            end if;
            if filling = '1' and I_RVALID_i = '1' and fill_index = target_index then
               ram_tgt_fresh_q <= '0';
            else
               ram_tgt_fresh_q <= '1';
            end if;
            -- Meme regle pour la replique des tags : seule l'ecriture de tag compte.
            if tag_we = '1' and fill_index = nx1_index then
               ram_nx1_fresh_q <= '0';
            else
               ram_nx1_fresh_q <= '1';
            end if;
            if tag_we = '1' and fill_index = nx2_index then
               ram_nx2_fresh_q <= '0';
            else
               ram_nx2_fresh_q <= '1';
            end if;

            -- Remplissage : les banques ecrivent chaque reponse directement.
            if filling = '1' then
               if req_k < WORDS and I_READY_i = '1' then
                  req_k <= req_k + 1;
               end if;
               if I_RVALID_i = '1' then
                  ff := fill_fault or I_FAULT_i;
                  fill_fault <= ff;
                  if resp_k = WORDS - 1 then
                     filling <= '0';
                     resp_k <= 0;
                     if ff = '1' then
                        fault_valid <= '1';
                        fault_line <= fill_line;
                        present(fill_index) <= '0';
                     else
                        -- Le tag est ecrit dans U_TAG/U_TAG_NX par tag_we.
                        present(fill_index) <= '1';
                     end if;
                  else
                     resp_k <= resp_k + 1;
                  end if;
               end if;

            -- Un defaut n'est constate que sur un tag lu pour le PC courant.
            elsif active = '1' and cur_lookup = '1' and hit = '0' and faulty_hit = '0'
                  and redirect = '0' then
               new_line := line_base;
               new_idx := INDEX_OF(new_line);
               filling <= '1';
               fill_line <= new_line;
               fill_fault <= '0';
               req_k <= 0;
               resp_k <= 0;
               -- Les mots arrivent directement dans les banques : rendre l'ancienne
               -- ligne non visible evite un hit sur une ligne partiellement remplacee.
               present(new_idx) <= '0';

            elsif active = '1' and hit = '1' and redirect = '0' and (miss1 = '1' or miss2 = '1') then
               if miss1 = '1' then
                  new_line := next1;
               else
                  new_line := next2;
               end if;
               new_idx := INDEX_OF(new_line);
               filling <= '1';
               fill_line <= new_line;
               fill_fault <= '0';
               req_k <= 0;
               resp_k <= 0;
               present(new_idx) <= '0';
            end if;

            -- Tampon de cible : second port de lecture des quatre banques.
            if bt_load and not tb_has then
               tb_valid(tb_next) <= true;
               tb_pc(tb_next) <= ram_tgt_target_q;
               tb_next <= (tb_next + 1) mod TB_ENTRIES;
               for i in 0 to FETCH_BLOCK_SIZE - 1 loop
                  if to_integer(ram_tgt_target_q(4 downto 0)) + i < FETCH_BLOCK_SIZE then
                     tb_block(tb_next)(i) <= BYTE_OF_LINE(tgt_word, to_integer(ram_tgt_target_q(4 downto 0)) + i);
                  else
                     tb_block(tb_next)(i) <= (others => '0');
                  end if;
               end loop;
            end if;

            -- Le contenu key/fin/target/ctr est ecrit par les quatre RAM ci-dessus.
            -- Seul valid est un etat local remis a zero globalement.
            if train_valid_q = '1' and train_taken_q = '1' and not bt_taken_match then
               bt_valid(bt_train_idx_q) <= '1';
            end if;

            -- PC : priorites identiques a RTL.
            if RECOVERY_i.valid = '1' then
               pc <= CUT(RECOVERY_i.new_pc);
               active <= '1';

            elsif PREDICT_VALID_i = '1' and preload = '1' then
               pc <= CUT(LINE_OF(PREDICT_PC_i) + FETCH_BLOCK_SIZE);
               active <= '1';

            elsif PREDICT_VALID_i = '1' then
               pc <= CUT(PREDICT_PC_i);
               active <= '1';

            elsif STOP_i = '1' then
               active <= '0';

            elsif show = '1' and FETCH_READY_i = '1' then
               pc <= CUT(line_base + FETCH_BLOCK_SIZE);
            end if;

         end if;
      end if;
   end process CHARGEMENT;

end architecture IN_ORDER;
