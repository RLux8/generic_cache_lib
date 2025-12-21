--
-- VHDL Package Header better_generic_cache_lib.generic_caches
--
-- Created:
--          by - rbnlux.ckoehler (pc023)
--          at - 10:34:46 12/19/24
--
-- using Mentor Graphics HDL Designer(TM) 2022.3 Built on 14 Jul 2022 at 13:56:12
--
LIBRARY ieee;
USE ieee.std_logic_1164.all;
use ieee.math_real.all;
USE ieee.numeric_std.all;


PACKAGE generic_caches IS
    constant DEBUG_MODE: boolean := true;

    type cache_T is (DIMA_WRBA, DIMA_WRTH);
    type arbitration_mode_T is (ROUND_ROBIN);

    type ctrl_mode_T is (nop, flush, inval);

    constant ADDR_WIDTH: positive := 64;
    constant BUS_WIDTH: positive := 256;
    constant BYTE_SIZE: positive := 8;

    constant BYTES_PER_BUS_WORD : natural := BUS_WIDTH / BYTE_SIZE;
    constant BYTES_PER_BUS_WORD_LOG : natural := integer(ceil(log2(real(BYTES_PER_BUS_WORD))));

    subtype byte_T is std_logic_vector(BYTE_SIZE - 1 downto 0);
    subtype addr_T is std_logic_vector(ADDR_WIDTH - 1 downto 0);
    subtype bena_T is std_logic_vector(BYTES_PER_BUS_WORD - 1 downto 0);
    subtype bus_T is std_logic_vector(BUS_WIDTH - 1 downto 0);

    type addr_vec_T is array(natural range <>) of addr_T;
    type bus_vec_T is array(natural range <>) of bus_T;
    type bena_vec_T is array(natural range <>) of bena_T;

    pure function maxOf2(a: integer; b: integer) return integer;
    pure function minOf2(a: integer; b: integer) return integer;
    pure function isAllStd(a: std_logic_vector; val: std_logic) return boolean;
    pure function isAllBool(a: boolean_vector; val: boolean) return boolean;
END generic_caches;
