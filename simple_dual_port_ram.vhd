LIBRARY ieee;
USE ieee.numeric_std.all;
USE ieee.std_logic_1164.all;

ENTITY simple_dual_port_ram IS
  generic (
    ADDR_WIDTH: positive;
    DATA_WIDTH: positive
  );
  port (
    clk: in std_logic;
    raddr: in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    waddr: in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    wdata: in  std_logic_vector(DATA_WIDTH - 1 downto 0);
    we:    in  std_logic;
    rdata: out std_logic_vector(DATA_WIDTH - 1 downto 0)
  );
END ENTITY simple_dual_port_ram;


ARCHITECTURE behav OF simple_dual_port_ram IS
  type ram_type is array (0 to 2** ADDR_WIDTH - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal ram: ram_type := (others => (others => '0'));
  
  attribute rw_addr_collision: string;
  attribute rw_addr_collision of ram: signal is "yes";
  
  signal raddr_reg: std_logic_vector(ADDR_WIDTH - 1 downto 0); 
BEGIN
  ram_read: rdata <= ram(to_integer(unsigned(raddr_reg)));
  
  ram_write_p: process (clk) is
  begin
    if clk'event and clk = '1' then
      if we = '1' then
        ram(to_integer(unsigned(waddr))) <= wdata;  
      end if;
      raddr_reg <= raddr;
    end if;  
  end process ram_write_p;
END ARCHITECTURE behav;

