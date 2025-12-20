--
-- VHDL Package Body better_generic_cache_lib.generic_caches
--
-- Created:
--          by - rbnlux.ckoehler (pc023)
--          at - 13:09:03 12/19/24
--
-- using Mentor Graphics HDL Designer(TM) 2022.3 Built on 14 Jul 2022 at 13:56:12
--
PACKAGE BODY generic_caches IS
    pure function isAllStd(a: std_logic_vector; val: std_logic) return boolean is
    begin
        for i in a'range loop
            if a(i) /= val then
                return false;
            end if;
        end loop;
        return true;
    end function;

    pure function isAllBool(a: boolean_vector; val: boolean) return boolean is
    begin
        for i in a'range loop
            if a(i) /= val then
                return false;
            end if;
        end loop;
        return true;
    end function;

    pure function minOf2(a: integer; b: integer) return integer is
    begin
        if a > b then
            return b;
        else
            return a;
        end if;
    end function;

    pure function maxOf2(a: integer; b: integer) return integer is
    begin
        if a < b then
            return b;
        else
            return a;
        end if;
    end function;
END generic_caches;
