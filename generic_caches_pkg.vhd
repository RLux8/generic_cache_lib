LIBRARY ieee;
USE ieee.std_logic_1164.all;
use ieee.math_real.all;
USE ieee.numeric_std.all;


PACKAGE generic_caches IS
    constant DEBUG_MODE: boolean := true;

    type cache_T is (DIMA_WRBA, DIMA_WRTH);
    type arbitration_mode_T is (ROUND_ROBIN);

    constant BYTE_SIZE: positive := 8;
    subtype byte_T is std_logic_vector(BYTE_SIZE - 1 downto 0);


    pure function maxOf2(a: integer; b: integer) return integer;
    pure function minOf2(a: integer; b: integer) return integer;
    pure function isAllStd(a: std_logic_vector; val: std_logic) return boolean;
    pure function isAllBool(a: boolean_vector; val: boolean) return boolean;
END generic_caches;
