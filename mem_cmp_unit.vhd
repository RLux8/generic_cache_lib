LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY generic_cache_lib;
USE generic_cache_lib.generic_caches.all;

ENTITY mem_cmp_unit IS
   PORT( 
      addr            : IN     std_logic_vector (31 DOWNTO 0);
      byte_ena        : IN     std_logic_vector (3 DOWNTO 0);
      c_flush_active  : IN     boolean;
      clk             : IN     std_logic;
      ld              : IN     std_logic_vector (31 DOWNTO 0);
      next_addr       : IN     std_logic_vector (31 DOWNTO 0);
      p_flush_active  : IN     boolean;
      rd              : IN     boolean;
      res_n           : IN     std_logic;
      sd              : IN     std_logic_vector (31 DOWNTO 0);
      shadow_rdata    : IN     std_logic_vector (255 DOWNTO 0);
      stall           : IN     boolean;
      we              : IN     boolean;
      check_stall     : OUT    boolean;
      flush           : OUT    boolean;
      flush_end       : OUT    std_logic_vector (31 DOWNTO 0);
      flush_start     : OUT    std_logic_vector (31 DOWNTO 0);
      shadow_byte_ena : OUT    std_logic_vector (31 DOWNTO 0);
      shadow_check    : OUT    boolean;
      shadow_raddr    : OUT    std_logic_vector (31 DOWNTO 0);
      shadow_waddr    : OUT    std_logic_vector (31 DOWNTO 0);
      shadow_wdata    : OUT    std_logic_vector (255 DOWNTO 0);
      shadow_we       : OUT    boolean
   );

-- Declarations

END mem_cmp_unit ;

--
library ieee;
use ieee.numeric_std.all;
use IEEE.math_real.all;


ARCHITECTURE behav OF mem_cmp_unit IS
  constant BUS_WIDTH: natural := 256;
  constant DATA_WIDTH: natural := 32;
   constant BYTE_SIZE: positive := 8;
    constant BUS_WIDTH_LOG: natural := integer(ceil(log2(real(BUS_WIDTH/BYTE_SIZE))));
    constant ZERO_BUS_ADDR: std_logic_vector(BUS_WIDTH_LOG - 1 downto 0) := (others => '0');
    subtype byte_T is std_logic_vector(BYTE_SIZE - 1 downto 0);
    constant BYTES_PER_WORD: natural := DATA_WIDTH / BYTE_SIZE;
    constant BYTES_PER_WORD_LOG: natural := integer(ceil(log2(real(BYTES_PER_WORD))));
    constant ADDR_WIDTH_WORD: natural := integer(ceil(log2(real(DATA_WIDTH/BYTE_SIZE))));
    constant WORDS_PER_BUS: positive := BUS_WIDTH / DATA_WIDTH;
    constant WORDS_PER_BUS_LOG: natural := integer(ceil(log2(real(WORDS_PER_BUS))));

    subtype WORD_IN_BUS_WORD is natural range ADDR_WIDTH_WORD + WORDS_PER_BUS_LOG - 1 downto ADDR_WIDTH_WORD;
    subtype BYTE_IN_BUS_WORD is natural range ADDR_WIDTH_WORD + WORDS_PER_BUS_LOG - 1 downto 0;

    type check_state_T is (IDLE, INIT_FLUSHING, FLUSHING, FLUSH_DELAY, CHECKING);
    signal check_state: check_state_T;

    signal start_check: boolean;
    signal check_done: boolean;
    signal check_start_ctr: natural;

    constant FLUSH_CHECK_DELAY: positive := 30;

    constant TOTAL_CYCLES: positive := 500;

    signal cycle_duration: positive;
    signal total_bytes_written: natural;
    signal total_bytes_read: natural;
BEGIN
    shadow_we <= we;
    shadow_access_conv_p: process(all) is
        variable which_word: natural;
    begin
        shadow_byte_ena <= (others => '0');
        shadow_wdata <= (others => '0');
        shadow_waddr <= addr(addr'left downto BUS_WIDTH_LOG) & ZERO_BUS_ADDR;


        which_word := to_integer(unsigned(addr(WORD_IN_BUS_WORD)));
        if we then
            shadow_byte_ena((which_word + 1) * BYTES_PER_WORD - 1 downto which_word * BYTES_PER_WORD) <= byte_ena;
            shadow_wdata(((which_word + 1) * BYTES_PER_WORD) * BYTE_SIZE - 1 downto which_word * BYTES_PER_WORD * BYTE_SIZE) <= sd;
        end if;
    end process shadow_access_conv_p;


    check_state_p: process(clk, res_n) is
        variable flush_delay_ctr: natural range 0 to FLUSH_CHECK_DELAY;
    begin
        if res_n /= '1' then
            check_state <= IDLE;
            flush_delay_ctr := 0;
        else
            if (clk'event and clk = '1') then  
                case check_state is
                    when IDLE => 
                        if start_check and not stall then
                            check_state <= INIT_FLUSHING;
                        end if;
                  when INIT_FLUSHING => 
                     check_state <= FLUSHING;
                    when FLUSHING => 
                        if not c_flush_active then
                            check_state <= FLUSH_DELAY;
                        end if;
                    when FLUSH_DELAY =>
                        if flush_delay_ctr /= FLUSH_CHECK_DELAY then
                            flush_delay_ctr := flush_delay_ctr + 1;
                        else
                            check_state <= CHECKING;
                            flush_delay_ctr := 0;
                        end if;
                    when CHECKING => 
                        check_state <= IDLE;
                end case;
            end if;
        end if;
    end process check_state_p;

    flush_start <= (others => '0');
    flush_end <= (others => '1');

    check_ouput_p: process(all) is
    begin
        shadow_check <= false;
        flush <= false;
        check_stall <= false;


        case check_state is
            when IDLE => 
                if start_check and not stall then
                    check_stall <= true;
                end if;
            when INIT_FLUSHING => 
               check_stall <= true;
               flush <= true;
            when FLUSHING | FLUSH_DELAY => 
                check_stall <= true;
            when CHECKING => 
                shadow_check <= true;
                check_stall <= true;

        end case;
    end process check_ouput_p;

    shadow_raddr <= addr(addr'left downto BUS_WIDTH_LOG) & ZERO_BUS_ADDR;
    rdata_check_p: process(clk, res_n) is
        variable shadow_ld: std_logic_vector(ld'range);
        variable which_word: natural;
    begin
        if res_n /= '1' then
        else
            if (clk'event and clk = '0') then  
                if not stall and rd then
                    which_word := to_integer(unsigned(addr(WORD_IN_BUS_WORD)));
                    shadow_ld := shadow_rdata(((which_word + 1) * BYTES_PER_WORD) * BYTE_SIZE - 1 downto which_word * BYTES_PER_WORD * BYTE_SIZE);
                    assert ld = shadow_ld report "cache ld and show ld differ at " & to_hex_string(addr) & " : " &  to_hex_string(ld) & "(ld) vs (sh)" & to_hex_string(shadow_ld) severity failure;
                end if;
            end if;
        end if;
    end process rdata_check_p;

    cycle_dur_reg_p: process(clk, res_n) is
        variable seed1 : positive;
        variable seed2 : positive;
        variable x : real;
        variable y: natural;
    begin

        if res_n /= '1' then
            seed1 := 3;
            seed2 := 1;
            cycle_duration <= 1000;
        else
            if clk'event and clk = '1' then
                if start_check then
                    uniform(seed1, seed2, x);
                    cycle_duration <= integer(floor(x * 8192.0)) + 200;
                end if;
            end if;
        end if;
    end process cycle_dur_reg_p;  

    stats_p: process(clk, res_n) is
        variable set_bits: natural;
    begin
        if res_n /= '1' then
            total_bytes_written <= 0;
            total_bytes_read <= 0;
        else
            if (clk'event and clk = '1') then  
                if not stall then
                    if rd then
                        total_bytes_read <= total_bytes_read + 4;
                    end if;
                    
                    if we then
                        set_bits := 0;
                        for i in byte_ena'range loop
                            if byte_ena(i) = '1' then
                                set_bits := set_bits + 1;
                            end if;
                        end loop;

                        total_bytes_written <= total_bytes_written + set_bits;
                    end if;
                end if;
            end if;
        end if;
    end process stats_p;

    check_start_p: process(clk, res_n) is
      variable cycle_ctr: natural;
    begin
        if res_n /= '1' then
            check_start_ctr <= 0;
            cycle_ctr := 0;
            start_check <= false;
        else
            if (clk'event and clk = '1') then  
                start_check <= false;
                if check_start_ctr < cycle_duration then
                    check_start_ctr <= check_start_ctr + 1;
                else
                    if not check_stall then
                        start_check <= true;
                    else
                        check_start_ctr <= 0;
                        if cycle_ctr /= TOTAL_CYCLES then
                           cycle_ctr := cycle_ctr + 1;
                        else
                           report "test done: read " & integer'image(total_bytes_read) & " and wrote " & integer'image(total_bytes_written) & "bytes." severity failure;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process check_start_p;

END ARCHITECTURE behav;

