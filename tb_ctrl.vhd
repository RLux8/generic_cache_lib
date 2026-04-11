LIBRARY ieee;
USE ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.uniform;
use ieee.math_real.floor;

LIBRARY generic_cache_lib;
USE generic_cache_lib.generic_caches.all;

ENTITY tb_ctrl IS
   PORT( 
      check_stall : IN     boolean;
      clk         : IN     std_logic;
      ld          : IN     std_logic_vector (31 DOWNTO 0);
      res_n       : IN     std_logic;
      stall       : IN     boolean;
      addr        : OUT    std_logic_vector (31 DOWNTO 0);
      byte_ena    : OUT    std_logic_vector (3 DOWNTO 0);
      next_addr   : OUT    std_logic_vector (31 DOWNTO 0);
      rd          : OUT    boolean;
      sd          : OUT    std_logic_vector (31 DOWNTO 0);
      we          : OUT    boolean
   );

-- Declarations

END tb_ctrl ;




ARCHITECTURE behav OF tb_ctrl IS
  signal next_rd: boolean;
  signal next_we: boolean;
  signal next_flush: boolean;
  signal next_addr_int: std_logic_vector(next_addr'range);
  signal mode: boolean;
  signal startup: boolean;
  signal data_mutator: std_logic_vector(sd'range);
  constant INC_PATTERN: boolean := false;
BEGIN
  process(clk, res_n) is
    variable seed1 : positive;
    variable seed2 : positive;
    variable x : real;
    variable y: natural;
  begin
    
    if res_n /= '1' then
      next_addr_int <= (others => '0');
      seed1 := 1;
    seed2 := 1;
    else
      if clk'event and clk = '1' then
        if not (stall or check_stall) then
          next_rd <= true;

          uniform(seed1, seed2, x);
          y := integer(floor(x * 16383.0));
          
          if INC_PATTERN then
            next_addr_int <= std_logic_vector(unsigned(addr) + 1);
          else
            next_addr_int <= std_logic_vector(to_unsigned(y, 32));
          end if;
        end if;
      end if;
    end if;
  end process;

  mutator_reg_p: process(clk, res_n) is
    variable seed1 : positive;
    variable seed2 : positive;
    variable x : real;
    variable y: natural;
  begin

    if res_n /= '1' then
      data_mutator <= (others => '0');
      seed1 := 1;
      seed2 := 2;
    else
      if clk'event and clk = '1' then
        if not (stall or check_stall) then
          uniform(seed1, seed2, x);
          y := integer(floor(x * 2.0**31));
          data_mutator <= std_logic_vector(to_unsigned(y, 32));
        end if;
      end if;
    end if;
  end process mutator_reg_p;


  mode_p: process(clk, res_n) is
    variable ctr: natural;
  begin
    if res_n /= '1' then
      ctr := 0;
      mode <= true;
      startup <= true;
    else
      if clk'event and clk = '1' then
        if not (stall or check_stall) then
          startup <= false;
          if ctr /= 150 then
            ctr := ctr + 1;
          else
            mode <= not mode;
            ctr := 0;
          end if;
        end if;

      end if;
    end if;
  end process mode_p;
  rd <= mode and not startup;
  we <= not mode and addr(1 downto 0) = "00" and not startup;


  process(clk, res_n) is
  begin
    if res_n /= '1' then
      addr <= (others => '0');
    else
      if clk'event and clk = '1' then
        if not (stall or check_stall) then
          addr <= next_addr_int;
        end if;
      end if;
    end if;
  end process;

  data_mut_p: process(all) is
  begin
    if INC_PATTERN then
      sd <= addr;
    else
      for i in sd'range loop
        sd(i) <= addr(i) xor data_mutator(i);
      end loop;
    end if;
  end process data_mut_p;

  bena_reg_p: process(clk, res_n) is
    variable seed1 : positive;
    variable seed2 : positive;
    variable x : real;
    variable y: natural;
  begin

    if res_n /= '1' then
      seed1 := 2;
      seed2 := 1;
    else
      if clk'event and clk = '1' then
        if not (stall or check_stall) then
          uniform(seed1, seed2, x);
          y := integer(floor(x * 16.0));
          byte_ena <= std_logic_vector(to_unsigned(y, 4));
        end if;
      end if;
    end if;
  end process bena_reg_p;  

  --byte_ena <= (others => '1');

  next_addr <= next_addr_int when not (stall or check_stall) else addr;
END ARCHITECTURE behav;

