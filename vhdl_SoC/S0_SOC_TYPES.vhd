library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;

        --------------------------------------------------------------------------------
        -- SOC_TYPES : types et carte d'adresses du SoC autour de TAHX_1
        --   (ARCHI_SOC_TAHX.md § 2 et § 3).
        --
        -- Adresses physiques de 32 bits (PA_BITS d'INO_PADDR) ; les bus I_* et D_* du
        -- coeur les portent dans address_t (64 bits), bits 63..32 a zero.
        --
        --   0x0000_0000 - 0x0FFF_FFFF  xSPI A, CS0 (CS1 si BOOT_SEL = 1)
        --   0x1000_0000 - 0x1FFF_FFFF  xSPI A, CS1 (CS0 si BOOT_SEL = 1)
        --   0x2000_0000 - 0x2FFF_FFFF  xSPI B, CS0
        --   0x3000_0000 - 0x3FFF_FFFF  xSPI B, CS1
        --   0xF000_0000 - 0xF00F_FFFF  registres (port R_*, avant le cache de donnees ;
        --                              jamais sur I_* ni D_*)
        --   reste                      faute d'acces
        --------------------------------------------------------------------------------

package SOC_TYPES is

   constant SOC_PA_BITS    : positive := 32;
   constant SOC_LINE_WORDS : positive := 4;                     -- mots de 64 bits par ligne
   constant SOC_PORTS      : positive := 2;                     -- xSPI A (0), B (1)

   subtype soc_pa_t     is unsigned( SOC_PA_BITS - 1 downto 0 );
   type soc_pa_array_t   is array( natural range <> ) of soc_pa_t;
   type soc_word_array_t is array( natural range <> ) of word64_t;

   -- Cible d'une adresse sur les bus I_* et D_* (matrice)
   type soc_target_t is record
      mapped : std_logic;                                       -- dans une fenetre xSPI
      port_b : std_logic;                                       -- 0 : port A, 1 : port B
      cs     : std_logic;                                       -- selection 0 ou 1 du port
   end record;

   function SOC_DECODE( addr : address_t; boot_sel : std_logic ) return soc_target_t;

end package SOC_TYPES;

package body SOC_TYPES is

   function SOC_DECODE( addr : address_t; boot_sel : std_logic ) return soc_target_t is
      variable t : soc_target_t := ( mapped => '0', port_b => '0', cs => '0' );
   begin
      if addr( 63 downto SOC_PA_BITS ) = 0 and addr( 31 downto 30 ) = "00" then
         t.mapped := '1';
         t.port_b := addr( 29 );
         if addr( 29 ) = '0' then
            t.cs := addr( 28 ) xor boot_sel;                    -- echange des fenetres du port A
         else
            t.cs := addr( 28 );
         end if;
      end if;
      return t;
   end function;

end package body SOC_TYPES;
