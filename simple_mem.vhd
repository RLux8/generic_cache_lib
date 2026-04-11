--
-- VHDL Architecture generic_cache_lib.simple_mem.behav
--
-- Created:
--          by - surfer.UNKNOWN (SURFER-A0000001)
--          at - 19:44:08 14.12.2024
--
-- using Mentor Graphics HDL Designer(TM) 2021.1 Built on 14 Jan 2021 at 15:11:42
--
LIBRARY ieee;
USE ieee.std_logic_1164.all;
use IEEE.math_real.all;
use ieee.numeric_std.all;

LIBRARY generic_cache_lib;
USE generic_cache_lib.generic_caches.all;

ENTITY simple_mem IS
  PORT(
    clk, res_n       : IN std_logic;

    dc_rreq            : IN boolean := false;
    dc_rack            : OUT boolean;
    dc_raddr           : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    dc_rdata           : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);

    ac_rreq            : IN boolean := false;
    ac_rack            : OUT boolean;
    ac_raddr           : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    ac_rdata           : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);

    ic_rreq            : IN boolean := false;
    ic_rack            : OUT boolean;
    ic_raddr           : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    ic_rdata           : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);


    dc_wreq            : IN boolean := false;
    dc_wack            : OUT boolean;
    dc_waddr           : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    dc_wdata           : IN std_logic_vector(BUS_WIDTH - 1 downto 0) := (others => '0');
    dc_wbyte_ena       : IN std_logic_vector(BUS_WIDTH/8 - 1 downto 0) := (others => '0');

    ac_wreq            : IN boolean := false;
    ac_wack            : OUT boolean;
    ac_waddr           : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    ac_wdata           : IN std_logic_vector(BUS_WIDTH - 1 downto 0) := (others => '0');
    ac_wbyte_ena       : IN std_logic_vector(BUS_WIDTH/8 - 1 downto 0) := (others => '0');



    shadow_check       : IN boolean := false;


    shadow_byte_ena1    : IN std_logic_vector(BUS_WIDTH/8 - 1 downto 0) := (others => '0');
    shadow_we1          : IN boolean := false;
    shadow_wdata1       : IN std_logic_vector(BUS_WIDTH - 1 downto 0) := (others => '0');
    shadow_waddr1       : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    shadow_raddr1       : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    shadow_rdata1       : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);

    shadow_byte_ena2    : IN std_logic_vector(BUS_WIDTH/8 - 1 downto 0) := (others => '0');
    shadow_we2          : IN boolean := false;
    shadow_wdata2       : IN std_logic_vector(BUS_WIDTH - 1 downto 0) := (others => '0');
    shadow_waddr2       : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    shadow_raddr2       : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    shadow_rdata2       : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);

    shadow_byte_ena3    : IN std_logic_vector(BUS_WIDTH/8 - 1 downto 0) := (others => '0');
    shadow_we3          : IN boolean := false;
    shadow_wdata3       : IN std_logic_vector(BUS_WIDTH - 1 downto 0) := (others => '0');
    shadow_waddr3       : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    shadow_raddr3       : IN std_logic_vector(32 - 1 downto 0) := (others => '0');
    shadow_rdata3       : OUT std_logic_vector(BUS_WIDTH - 1 downto 0)
  );
END ENTITY simple_mem;


ARCHITECTURE behav OF simple_mem IS
constant BYTE_SIZE: natural := 8;
  constant BUS_WIDTH_LOG: natural := integer(ceil(log2(real(BUS_WIDTH/BYTE_SIZE))));
  subtype word_T is std_logic_vector(31 downto 0);
  constant BYTE_ADDR_WIDTH : positive := 14; -- was 14
  constant MAX_ACCESS_DELAY: real := 10.0;
  constant RND_ACCESS_TIME: boolean := true;
  constant ADDR_WIDTH: positive := BYTE_ADDR_WIDTH - integer(ceil(log2(real(BUS_WIDTH/8))));
  
  type requeststateT is (IDLE, HANDLINGICREQ, HANDLINGDCWREQ, HANDLINGDCRREQ, HANDLINGACRREQ, HANDLINGACWREQ);

  signal request_current_state: requeststateT;
  signal request_next_state: requeststateT;

  
  pure function conv_addr (addr: in  word_T) return std_logic_vector is
    variable result: std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
  begin
    result := addr(BYTE_ADDR_WIDTH - 1 downto BYTE_ADDR_WIDTH - ADDR_WIDTH);
    return result;
  end function conv_addr;
  

  subtype BUS_WORD_IX_IN_ADDR is natural range BYTE_ADDR_WIDTH - 1 downto BUS_WIDTH_LOG;

  
  -- internal ram signals
  signal addr: std_logic_vector(ADDR_WIDTH - 1 downto 0);
  signal we: std_logic;
  signal byte_ena: std_logic_vector(BUS_WIDTH/8 - 1 downto 0);
  signal wdata, rdata: std_logic_vector(BUS_WIDTH - 1 downto 0);
  signal ic_rack_int, dc_rack_int, ac_rack_int, dc_wack_int, ac_wack_int: boolean;
  signal wack_reg: boolean;


  subtype bword_T is std_logic_vector(BUS_WIDTH - 1 downto 0);
  type memory_T is array(2 ** ADDR_WIDTH - 1 downto 0) of bword_T;
  signal memory: memory_T := (others => (others => '0'));
  signal shadow_memory: memory_T := (others => (others => '0'));
  signal req_delay_clks: natural;
  signal req_wait_ctr: natural;
  signal next_req_wait_ctr: natural;
  signal tick_reg_delay: boolean;

BEGIN
  
  -- internal ram controller
  

  
  -- request handling fsm state memory
  request_fsm_state: process(clk, res_n) is
  begin
    if res_n = '0' then
      request_current_state <= IDLE;
      req_wait_ctr <= 0;
    else
      if clk'event and clk = '1' then
        request_current_state <= request_next_state;
        req_wait_ctr <= next_req_wait_ctr;
      end if;
    end if; 
  end process request_fsm_state;

  rdc: if RND_ACCESS_TIME generate
  begin
    req_delay_reg_p: process(clk, res_n) is
      variable seed1 : positive;
      variable seed2 : positive;
      variable x : real;
      variable y: natural;
    begin

      if res_n /= '1' then
        seed1 := 2;
        seed2 := 1;
        req_delay_clks <= 10;
      else
        if clk'event and clk = '1' then
          if tick_reg_delay then
            uniform(seed1, seed2, x);
            req_delay_clks <= integer(floor(x * MAX_ACCESS_DELAY));
          end if;
        end if;
      end if;
    end process req_delay_reg_p;  
  end generate;


  -- request handling transition decision
  request_fsm_transitions: process(all) is
  begin
    request_next_state <= request_current_state;
    next_req_wait_ctr <= req_wait_ctr;
    
    case request_current_state is
      when IDLE => 
        if ic_rreq then
          request_next_state <= HANDLINGICREQ;
          next_req_wait_ctr <= 0;
        elsif dc_rreq then
          request_next_state <= HANDLINGDCRREQ;
          next_req_wait_ctr <= 0;
        elsif dc_wreq then
          request_next_state <= HANDLINGDCWREQ;
          next_req_wait_ctr <= 0;
        elsif ac_rreq then
          request_next_state <= HANDLINGACRREQ;
          next_req_wait_ctr <= 0;
        elsif ac_wreq then
          request_next_state <= HANDLINGACWREQ;
          next_req_wait_ctr <= 0;
        end if;

      when HANDLINGICREQ => 
        next_req_wait_ctr <= req_wait_ctr + 1;
        if not ic_rreq then
          request_next_state <= IDLE;
        end if;

      when HANDLINGDCRREQ => 
        next_req_wait_ctr <= req_wait_ctr + 1;
        if not dc_rreq then
          request_next_state <= IDLE;
        end if;
      
      when HANDLINGDCWREQ => 
        next_req_wait_ctr <= req_wait_ctr + 1;
        if not dc_wreq then
          request_next_state <= IDLE;
        end if;
      
      when HANDLINGACRREQ => 
        next_req_wait_ctr <= req_wait_ctr + 1;
        if not ac_rreq then
          request_next_state <= IDLE;
        end if;

      when HANDLINGACWREQ => 
        next_req_wait_ctr <= req_wait_ctr + 1;
        if not ac_wreq then
          request_next_state <= IDLE;
        end if;
    end case;
  end process  request_fsm_transitions;
  
  
  ic_rdata <= rdata;
  dc_rdata <= rdata;
  ac_rdata <= rdata;
  we       <= '1' when request_next_state = HANDLINGACWREQ or request_next_state = HANDLINGDCWREQ else '0';
  byte_ena <= ac_wbyte_ena when request_next_state = HANDLINGACWREQ else 
              dc_wbyte_ena when request_next_state = HANDLINGDCWREQ else
              (others => '0');
                
  wdata    <= dc_wdata when request_next_state = HANDLINGDCWREQ else 
              ac_wdata;

  -- request handling acknoledge and address signal control
  request_fsm_outputs: process(all) is
  begin
    ic_rack_int     <= false;
    dc_rack_int     <= false;
    ac_rack_int     <= false;
    dc_wack_int     <= false;
    ac_wack_int     <= false;
    addr <= (others => '0');
    tick_reg_delay  <= false;

    case request_current_state is
      when IDLE => 
        if ic_rreq then
          addr       <= ic_raddr(BUS_WORD_IX_IN_ADDR);
          ic_rack_int     <= true;
          tick_reg_delay <= true;
        elsif dc_rreq then
          addr       <= dc_raddr(BUS_WORD_IX_IN_ADDR);
          dc_rack_int     <= true;
          tick_reg_delay <= true;
        elsif dc_wreq then
          addr       <= dc_waddr(BUS_WORD_IX_IN_ADDR);
          dc_wack_int     <= true;
          tick_reg_delay <= true;
        elsif ac_rreq then
          addr       <= ac_raddr(BUS_WORD_IX_IN_ADDR);
          ac_rack_int     <= true;
          tick_reg_delay <= true;
        elsif ac_wreq then
          addr       <= ac_waddr(BUS_WORD_IX_IN_ADDR);
          ac_wack_int     <= true;
          tick_reg_delay <= true;

        end if;

      when HANDLINGICREQ => 
        addr       <= ic_raddr(BUS_WORD_IX_IN_ADDR);
        ic_rack_int     <= ic_rreq and (req_delay_clks <= req_wait_ctr or not RND_ACCESS_TIME);
      when HANDLINGDCRREQ => 
        addr       <= dc_raddr(BUS_WORD_IX_IN_ADDR);
        dc_rack_int     <= dc_rreq and (req_delay_clks <= req_wait_ctr or not RND_ACCESS_TIME);
      when HANDLINGDCWREQ => 
        addr       <= dc_waddr(BUS_WORD_IX_IN_ADDR);
        dc_wack_int     <= dc_wreq and (req_delay_clks <= req_wait_ctr or not RND_ACCESS_TIME);
      when HANDLINGACRREQ => 
        addr       <= ac_raddr(BUS_WORD_IX_IN_ADDR);
        ac_rack_int     <= ac_rreq and (req_delay_clks <= req_wait_ctr or not RND_ACCESS_TIME);
      when HANDLINGACWREQ => 
        addr       <= ac_waddr(BUS_WORD_IX_IN_ADDR);
        ac_wack_int     <= ac_wreq and (req_delay_clks <= req_wait_ctr or not RND_ACCESS_TIME);
    end case;
  end process request_fsm_outputs;



  
    
  -- process for 1 clock cycle delay between req and ack to sync with block ram
  process (clk, res_n) is
  begin
    if res_n = '0' then
      ic_rack <= false;
      dc_rack <= false;
      ac_rack <= false;
      dc_wack <= false;
    else
      if clk'event and clk = '1' then
        ic_rack <= ic_rack_int;
        dc_rack <= dc_rack_int;
        ac_rack <= ac_rack_int;
        dc_wack <= dc_wack_int;
        ac_wack <= ac_wack_int;
        wack_reg <= dc_wack_int or ac_wack_int;
      end if;
    end if; 
  end process;
  


  mem_p: process(clk, res_n) is
    variable mem_line: bword_T;
    variable this_byte: std_logic_vector(7 downto 0);
  begin
    if res_n /= '1' then
      for i in memory'range loop
        mem_line :=  std_logic_vector(to_unsigned(i*8 + 7, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 6, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 5, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 4, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 3, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 2, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 1, 32)) & 
                     std_logic_vector(to_unsigned(i*8 + 0, 32));  
        memory(i) <= mem_line;              
        shadow_memory(i) <= mem_line;
      end loop;
    else
      if clk'event and clk = '1' then
          if we = '1' then
              for b in BUS_WIDTH/8 - 1 downto 0 loop
                  if byte_ena(b) = '1' then
                      this_byte := wdata((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b);
                      memory(to_integer(unsigned(addr)))((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b) <= this_byte;
                  end if;
              end loop;
          end if;

          if shadow_we1 then
              for b in BUS_WIDTH/8 - 1 downto 0 loop
                  if shadow_byte_ena1(b) = '1' then
                      shadow_memory(to_integer(unsigned(shadow_waddr1(shadow_waddr1'left downto BUS_WIDTH_LOG))))((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b) <= shadow_wdata1((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b);
                  end if;
              end loop;
          end if;

          if shadow_we2 then
              for b in BUS_WIDTH/8 - 1 downto 0 loop
                  if shadow_byte_ena2(b) = '1' then
                      shadow_memory(to_integer(unsigned(shadow_waddr2(shadow_waddr1'left downto BUS_WIDTH_LOG))))((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b) <= shadow_wdata2((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b);
                  end if;
              end loop;
          end if;

          if shadow_we3 then
              for b in BUS_WIDTH/8 - 1 downto 0 loop
                  if shadow_byte_ena3(b) = '1' then
                      shadow_memory(to_integer(unsigned(shadow_waddr3(shadow_waddr1'left downto BUS_WIDTH_LOG))))((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b) <= shadow_wdata3((b + 1) * BYTE_SIZE - 1 downto BYTE_SIZE * b);
                  end if;
              end loop;
          end if;
  
          rdata <= memory(to_integer(unsigned(addr)));
      end if;
    end if;
  end process mem_p;

  check_p: process(all) is
    variable xored: std_logic_vector(wdata'range);
  begin
    if shadow_check then
      for i in memory'range loop
        for b in xored'range loop
          xored(b) := shadow_memory(i)(b) xor memory(i)(b);
        end loop;
        assert memory(i) = shadow_memory(i) report "memory contents differ at bus word ix " & integer'image(i) & " mem " & to_hex_string(memory(i)) & "(mem) <-> (smem)" & to_hex_string(shadow_memory(i)) & "!: " & to_hex_string(xored) severity failure;
      end loop;
    end if;
  end process;

  shadow_rdata1 <= shadow_memory(to_integer(unsigned(shadow_raddr1(BUS_WORD_IX_IN_ADDR))));
  shadow_rdata2 <= shadow_memory(to_integer(unsigned(shadow_raddr2(BUS_WORD_IX_IN_ADDR))));
  shadow_rdata3 <= shadow_memory(to_integer(unsigned(shadow_raddr3(BUS_WORD_IX_IN_ADDR))));
	
END ARCHITECTURE behav;



