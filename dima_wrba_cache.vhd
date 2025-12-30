LIBRARY ieee;
USE ieee.std_logic_1164.all;
use IEEE.math_real.all;
use ieee.numeric_std.all;

LIBRARY generic_cache_lib;
USE generic_cache_lib.generic_caches.all;

ENTITY dima_wrba_cache IS
    GENERIC(
        ADDR_WIDTH: positive := 32;
        DATA_WIDTH: positive := 32;

        WORDS_IN_LINE: positive := 8;
        LINES: positive := 8;
        BUS_WIDTH: positive := 256;

        BACKGROUND_FLUSHES: boolean := false;
        REPORT_IF_MISUSE: boolean := true
    );
    PORT(
        clk, res_n              : IN std_logic;

        -- pipeline interface
        addr                    : IN std_logic_vector(ADDR_WIDTH - 1 downto 0);
        next_addr               : IN std_logic_vector(ADDR_WIDTH - 1 downto 0);
        byte_ena                : IN std_logic_vector(DATA_WIDTH/8 - 1 downto 0) := (others => '1');
        we                      : IN boolean := false;
        rd                      : IN boolean := true;

        sd                      : IN std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
        ld                      : OUT std_logic_vector(DATA_WIDTH - 1 downto 0);
        stall                   : OUT boolean;
        

        -- management interface
        mgm_flush               : IN boolean;
        mgm_inval               : IN boolean;
        mgm_start               : IN std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
        mgm_end                 : IN std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '1');
        mgm_active              : OUT boolean;

        iffault                 : OUT boolean;


        -- memory interface
        rreq                    : OUT boolean;
        rack                    : IN boolean;
        raddr                   : OUT std_logic_vector(ADDR_WIDTH - 1 downto 0);
        rdata                   : IN std_logic_vector(BUS_WIDTH - 1 downto 0);


        wreq                    : OUT boolean;
        wack                    : IN boolean := false;
        waddr                   : OUT std_logic_vector(ADDR_WIDTH - 1 downto 0);
        wdata                   : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);
        wbyte_ena               : OUT std_logic_vector(BUS_WIDTH/8 - 1 downto 0)

    );
END ENTITY dima_wrba_cache;

--
ARCHITECTURE behav OF dima_wrba_cache IS
    constant BYTES_PER_WORD: natural := DATA_WIDTH / BYTE_SIZE;
    constant BYTES_PER_WORD_LOG: natural := integer(ceil(log2(real(BYTES_PER_WORD))));
    constant LINES_LOG: natural := integer(ceil(log2(real(LINES))));
    constant WORDS_IN_LINE_LOG: natural := integer(ceil(log2(real(WORDS_IN_LINE))));
    constant BYTES_IN_LINE: natural := BYTES_PER_WORD * WORDS_IN_LINE;
    constant BYTES_IN_LINE_LOG: natural := BYTES_PER_WORD_LOG + WORDS_IN_LINE_LOG;   
    constant ADDR_WIDTH_WORD: natural := integer(ceil(log2(real(DATA_WIDTH/BYTE_SIZE))));
    constant TAG_WIDTH: natural := ADDR_WIDTH - LINES_LOG - WORDS_IN_LINE_LOG - ADDR_WIDTH_WORD;
    constant BUS_WORDS_PER_LINE: natural := (WORDS_IN_LINE * DATA_WIDTH) / BUS_WIDTH; -- if this is zero, BUS_WIDTH > LINE_WIDTH*DATA_WIDTH (in bits)
    constant Q_LOG: integer := maxOf2(integer(ceil(log2(real(BUS_WIDTH) / real(WORDS_IN_LINE * DATA_WIDTH)))), 0);  
    constant WORDS_PER_BUS: positive := BUS_WIDTH / DATA_WIDTH;
    constant WORDS_PER_BUS_LOG: natural := integer(ceil(log2(real(WORDS_PER_BUS))));
    constant BYTES_PER_BUS_WORD: natural := BUS_WIDTH / BYTE_SIZE;
    constant BYTES_PER_BUS_WORD_LOG: natural := integer(ceil(log2(real(BYTES_PER_BUS_WORD))));

    constant ZERO_BYTE_ADDR: std_logic_vector(ADDR_WIDTH_WORD - 1 downto 0) := (others => '0');
    constant ZERO_BUS_ADDR: std_logic_vector(WORDS_PER_BUS_LOG - 1 downto 0)  := (others => '0');

    
    subtype word_T is std_logic_vector(DATA_WIDTH - 1 downto 0);
    type bus_word_T is array(WORDS_PER_BUS - 1 downto 0) of word_T;

    -- cache line memory in/out signals
    type row_selected_bytes_T is array(BYTES_IN_LINE - 1 downto 0) of byte_T;
    constant NULL_ROW_SEL_BYTES: row_selected_bytes_T := (others => (others => '0'));

    constant USE_EXPLICIT_MEMORY_UNITS: boolean := true;


    -- === The following ranges are used to extract the relevant bits of the address for various tasks ====
    -- bits in address which make up the tag
    subtype TAG_RANGE is natural range ADDR_WIDTH - 1 downto WORDS_IN_LINE_LOG + ADDR_WIDTH_WORD + LINES_LOG;
    -- bits in address which make up which line the data should be located in
    subtype LINE_RANGE is natural range WORDS_IN_LINE_LOG + ADDR_WIDTH_WORD + LINES_LOG - 1 downto WORDS_IN_LINE_LOG + ADDR_WIDTH_WORD;
    -- bits in address which determine which data word in the cache line gets selected
    subtype WORD_RANGE is natural range WORDS_IN_LINE_LOG + ADDR_WIDTH_WORD - 1 downto ADDR_WIDTH_WORD;
    -- bits in address which remain from the address when we access the memory to select the right bus word
    subtype BUS_WORD_RANGE is natural range ADDR_WIDTH - 1 downto ADDR_WIDTH_WORD + WORDS_PER_BUS_LOG ;
    -- bits in address which tell us which word in the current bus word we want to access
    subtype WORD_IN_BUS_WORD is natural range ADDR_WIDTH_WORD + WORDS_PER_BUS_LOG - 1 downto ADDR_WIDTH_WORD;
    -- bits in address which tell us which byte in the current bus word we want to access
    subtype BYTE_IN_BUS_WORD is natural range ADDR_WIDTH_WORD + WORDS_PER_BUS_LOG - 1 downto 0;
    -- bits in address which tell us which byte in the word we want to access;
    subtype BYTE_IN_WORD is natural range ADDR_WIDTH_WORD - 1 downto 0;
    -- bits in address which tell us which byte in the line we want to access;
    subtype BYTE_IN_LINE is natural range WORDS_IN_LINE_LOG + ADDR_WIDTH_WORD - 1 downto 0;
    -- bits in address which tell us which word in the line we want to access;
    subtype WORD_IN_LINE is natural range WORDS_IN_LINE_LOG - 1 + ADDR_WIDTH_WORD downto ADDR_WIDTH_WORD;
    


    -- mgmt data contains VDDDDDTTTTTTTTT (valid dirty tag)
    subtype DIRTYS_IN_MGMT_RANGE is natural range BYTES_IN_LINE + TAG_WIDTH - 1 downto TAG_WIDTH;
    constant VALID_IN_MGMT: natural := TAG_WIDTH;
    subtype TAG_IN_MGMT is natural range TAG_WIDTH - 1 downto 0;


    -- ==== CORE ==== 
    type core_access_T is (FLUSHU, PIPELINE, FILLU);
    subtype mgmt_vector_T is std_logic_vector(TAG_WIDTH downto 0);
    subtype dirty_bits_T is std_logic_vector(BYTES_IN_LINE - 1 downto 0);
    type core_memory_T is array(LINES - 1 downto 0) of row_selected_bytes_T;
    type core_mgmt_memory_T is array(LINES - 1 downto 0) of mgmt_vector_T;
    type core_dirties_memory_T is array(LINES - 1 downto 0) of dirty_bits_T;

    subtype line_addr_log_T is std_logic_vector(LINES_LOG - 1 downto 0);
    subtype line_bes_T is std_logic_vector(BYTES_IN_LINE - 1 downto 0);

    type core_in_signals_T is record
        rd_addr: line_addr_log_T;
        wr_addr: line_addr_log_T;

        mgmt_addr: line_addr_log_T;
        mgmt_data: mgmt_vector_T;
        mgmt_wr: std_logic;


        dirties: dirty_bits_T;
        dirties_wr: std_logic;

        line_wdata: row_selected_bytes_T;
        line_bens: line_bes_T;
    end record core_in_signals_T;
    constant ZERO_CORE_IN: core_in_signals_T := (wr_addr => (others => '0'), rd_addr => (others => '0'), mgmt_data => (others => '0'), mgmt_addr => (others => '0'), dirties => (others => '0'), mgmt_wr => '0', dirties_wr => '0', line_wdata => NULL_ROW_SEL_BYTES, line_bens => (others => '0'));


    signal core_access: core_access_T;
    signal core_memory: core_memory_T := (others => NULL_ROW_SEL_BYTES);
    signal core_mgmt_memory: core_mgmt_memory_T := (others => (others => '0'));
    signal core_dirties_memory: core_dirties_memory_T := (others => (others => '0'));


    signal core_in_signals: core_in_signals_T;

    attribute keep_core_in : string;
    attribute keep_core_in of core_in_signals : signal is "true";
    signal core_rdata: row_selected_bytes_T;
    signal core_wdata: row_selected_bytes_T;
    signal core_rmgmt: mgmt_vector_T;
    signal core_rdirties: dirty_bits_T;

    -- the tag of the currently selected cache line
    signal line_tag_selected: std_logic_vector(TAG_WIDTH - 1 downto 0);
    signal line_valid: std_logic;
    signal line_is_dirty: boolean;
    signal last_core_rd_addr: line_addr_log_T;
    signal last_core_mgmt_addr: line_addr_log_T;
    signal line_hit: boolean;
    signal stall_int: boolean;

    signal pipe_core_in: core_in_signals_T;
    signal mgm_core_in: core_in_signals_T;
    signal fill_core_in: core_in_signals_T;

    -- subunit activation signals
    signal start_fill: boolean;
    signal start_mgm_op: boolean;
    signal start_writeback: boolean;
    signal req_writeback: boolean;

    -- subunit status signals
    signal mgm_busy: boolean;
    signal fill_busy: boolean;
    signal mgm_stall: boolean;
    signal writeback_busy: boolean;
    signal writeback_busy_q: boolean;

    -- ==== PIPELINE ====
    signal pipe_line: std_logic_vector(LINES_LOG - 1 downto 0);

    -- ==== FILL ==== 
    type fill_state_T is (IDLE, LOADING);
    signal fill_state: fill_state_T;
    -- which bus word we are currently filling into the selected line
    signal line_fill_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;
    signal next_line_fill_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;
    signal used_line_fill_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;
    signal last_used_line_fill_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1; 


    -- ==== WRITEBACK ==== 
    type writeback_state_T is (IDLE, WRITING);
    signal writeback_state: writeback_state_T;

    signal save_core_data: boolean;
    signal saved_core_rdata: row_selected_bytes_T;
    signal saved_core_mgmt: mgmt_vector_T;
    signal saved_core_dirties: dirty_bits_T;
    signal used_core_rdata: row_selected_bytes_T;
    signal used_core_mgmt: mgmt_vector_T;
    signal used_core_rdirties: dirty_bits_T;
    signal used_line_is_dirty: boolean;
    signal wbyte_ena_int: std_logic_vector(wbyte_ena'range);
    signal bus_word_dirty: boolean;
    signal writeback_line: std_logic_vector(LINES_LOG - 1 downto 0);
    signal saved_writeback_line: std_logic_vector(writeback_line'range);
    signal save_wb_line: boolean;

    signal line_writeback_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;
    signal last_line_writeback_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;
    signal used_line_writeback_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;
    signal next_line_writeback_ctr: natural range 0 to BUS_WORDS_PER_LINE + 1;

    -- ==== FLUSH ==== 
    type mgm_state_T is (RESET, IDLE, WAIT_STORE, WAITS, ITERATING, RESTORE_PIPE_ADDR, DONE);
    signal line_in_mgm_range: boolean;
    signal mgm_state: mgm_state_T;
    signal mgm_line_ix: line_addr_log_T;
    signal next_mgm_line_ix: line_addr_log_T;
    signal mgmt_wait_release: boolean;
    signal start_end_same_tag: boolean;
    signal mgm_line: std_logic_vector(LINES_LOG - 1 downto 0);
    signal in_locked_range: boolean;
    signal probe_line: line_addr_log_T;
    signal probed_mgmt: mgmt_vector_T;

    signal if_misuse_stall: boolean;


    component simple_dual_port_ram is
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
    end component simple_dual_port_ram;
BEGIN

--     ██████╗ ██████╗  ██████╗ ███████╗    
--     ██╔════╝██╔═══██╗██╔══██╗██╔════╝    
--     ██║     ██║   ██║██████╔╝█████╗      
--     ██║     ██║   ██║██╔══██╗██╔══╝      
--     ╚██████╗╚██████╔╝██║  ██║███████╗    
--      ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝    
                                     

    
    icore_mem_units: if USE_EXPLICIT_MEMORY_UNITS generate
        imgmt_mem: simple_dual_port_ram
            GENERIC MAP(
                ADDR_WIDTH => LINES_LOG,
                DATA_WIDTH => mgmt_vector_T'length
            ) 
            PORT MAP(
                clk => clk,

                we => core_in_signals.mgmt_wr,
                waddr => core_in_signals.mgmt_addr,
                wdata => core_in_signals.mgmt_data,

                raddr => core_in_signals.mgmt_addr,
                rdata => core_rmgmt
            );



        idirties_mem: simple_dual_port_ram
            GENERIC MAP(
                ADDR_WIDTH => LINES_LOG,
                DATA_WIDTH => BYTES_IN_LINE
            ) 
            PORT MAP(
                clk => clk,
                
                we => core_in_signals.dirties_wr,
                waddr => core_in_signals.wr_addr,
                wdata => core_in_signals.dirties,

                raddr => core_in_signals.rd_addr,
                rdata => core_rdirties
            );

        idata_mem: for byi in core_wdata'range generate 
        begin
            ibyte_mem: simple_dual_port_ram
            GENERIC MAP(
                ADDR_WIDTH => LINES_LOG,
                DATA_WIDTH => byte_T'length
            ) 
            PORT MAP(
                clk => clk,
                
                we => core_in_signals.line_bens(byi),
                waddr => core_in_signals.wr_addr,
                wdata => core_in_signals.line_wdata(byi),

                raddr => core_in_signals.rd_addr,
                rdata => core_rdata(byi)
            );
        end generate;


        core_memory_bena_p: process(all) is
        begin
            core_wdata <= core_rdata;
            for i in core_in_signals.line_bens'range loop
                core_wdata(i) <= core_in_signals.line_wdata(i);
            end loop;
        end process core_memory_bena_p;
    else generate
        core_memory_p: process(clk, res_n) is
        begin
            if clk'event and clk = '1' then
                last_core_rd_addr <= core_in_signals.rd_addr;
                last_core_mgmt_addr <= core_in_signals.mgmt_addr;

                -- mgmt data is special as in it can only be either read or written via the core in signals
                if core_in_signals.mgmt_wr = '1' then
                    core_mgmt_memory(to_integer(unsigned(core_in_signals.mgmt_addr))) <= core_in_signals.mgmt_data;
                end if;

                if core_in_signals.dirties_wr = '1' then
                    core_dirties_memory(to_integer(unsigned(core_in_signals.wr_addr))) <= core_in_signals.dirties;
                end if;

                --probe

                if not isAllStd(core_in_signals.line_bens, '0') then
                    core_memory(to_integer(unsigned(core_in_signals.wr_addr))) <= core_wdata;
                end if;
            end if;
        end process core_memory_p;
        core_rmgmt <= core_mgmt_memory(to_integer(unsigned(last_core_mgmt_addr)));
        core_rdata <= core_memory(to_integer(unsigned(last_core_rd_addr)));
        core_rdirties <= core_dirties_memory(to_integer(unsigned(last_core_rd_addr)));


        core_memory_bena_p: process(all) is
        begin
            core_wdata <= core_rdata;
            for i in core_in_signals.line_bens'range loop
                if core_in_signals.line_bens(i) = '1' then
                    core_wdata(i) <= core_in_signals.line_wdata(i);
                end if;
            end loop;
        end process core_memory_bena_p;
    end generate;
    

    line_tag_selected <= core_rmgmt(TAG_WIDTH - 1 downto 0);
    line_valid <= core_rmgmt(VALID_IN_MGMT);
    line_hit <= line_tag_selected = addr(TAG_RANGE) and line_valid = '1';

    line_is_dirty_p: process(all) is
    begin
        line_is_dirty <= false;
        for i in core_rdirties'range loop
            if core_rdirties(i) then
                line_is_dirty <= true;
                exit;
            end if;
        end loop;
    end process;

    core_control_p: process(all) is
        variable internal_stall: boolean;
    begin
        core_access         <= PIPELINE;
        start_writeback     <= false;
        start_fill          <= false;
        start_mgm_op        <= false;
        internal_stall      := false;
		writeback_line		<= (others => '0');
        stall_int           <= false;
        

        if fill_busy then
            core_access <= FILLU;
            writeback_line <= pipe_line;
        elsif (((mgm_flush or mgm_inval) and not mgmt_wait_release) or mgm_busy) then 
            core_access <= FLUSHU;
            start_mgm_op <= true;
            internal_stall := not mgmt_wait_release;
            writeback_line <= mgm_line;
            if req_writeback then
                start_writeback <= true;
            end if;
        elsif not line_hit and (rd or we) then 
            internal_stall := true;

            if line_is_dirty and line_valid = '1' then
                start_writeback <= true;
            end if;

            writeback_line <= pipe_line;
            core_access <= FILLU;
            start_fill <= true;
        end if;

        stall_int <= (mgm_busy or mgm_stall or fill_busy or writeback_busy_q) or internal_stall or if_misuse_stall;
    end process core_control_p;
    stall <= stall_int;


    core_in_signals <= pipe_core_in when core_access = PIPELINE else
                       mgm_core_in when core_access = FLUSHU else
                       fill_core_in when core_access = FILLU else
                       ZERO_CORE_IN;



--    ██████╗ ██╗██████╗ ███████╗██╗     ██╗███╗   ██╗███████╗
--    ██╔══██╗██║██╔══██╗██╔════╝██║     ██║████╗  ██║██╔════╝
--    ██████╔╝██║██████╔╝█████╗  ██║     ██║██╔██╗ ██║█████╗  
--    ██╔═══╝ ██║██╔═══╝ ██╔══╝  ██║     ██║██║╚██╗██║██╔══╝  
--    ██║     ██║██║     ███████╗███████╗██║██║ ╚████║███████╗
--    ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝╚═╝╚═╝  ╚═══╝╚══════╝
                                                        


    pipeline_access_p: process(all) is
        variable dirty_bits: dirty_bits_T;
        variable tmp: byte_T;
    begin
        pipe_core_in <= ZERO_CORE_IN;

        pipe_core_in.rd_addr    <= next_addr(LINE_RANGE);
        pipe_core_in.mgmt_addr  <= next_addr(LINE_RANGE);
        pipe_core_in.wr_addr    <= addr(LINE_RANGE);
        pipe_core_in.line_bens  <= (others => '0');

        --update dirty bits, activate byte enables
        dirty_bits := core_rdirties;

        pipe_core_in.mgmt_data <= core_rmgmt;   
        if we and line_hit then
            for b in BYTES_PER_WORD - 1 downto 0 loop
                if byte_ena(b) = '1' then
                    pipe_core_in.dirties_wr <= '1';
                end if;
                dirty_bits(to_integer(unsigned(addr(WORD_IN_LINE))) * BYTES_PER_WORD + b) := dirty_bits(to_integer(unsigned(addr(WORD_IN_LINE))) * BYTES_PER_WORD + b) or byte_ena(b);
                pipe_core_in.line_bens(to_integer(unsigned(addr(WORD_IN_LINE))) * BYTES_PER_WORD + b) <= byte_ena(b);
            end loop;

        end if;
        pipe_core_in.dirties <= dirty_bits;

        -- apply sd data to core
        for w in WORDS_IN_LINE - 1 downto 0 loop
            for b in BYTES_PER_WORD - 1 downto 0 loop
                pipe_core_in.line_wdata(w * BYTES_PER_WORD + b) <= sd((b+1) * BYTE_SIZE - 1 downto b * BYTE_SIZE);
            end loop;
        end loop;


        -- extract data from core
        for b in BYTES_PER_WORD - 1 downto 0 loop
            tmp := core_rdata(to_integer(unsigned(addr(WORD_RANGE))) * BYTES_PER_WORD + b);

            for bit_i in BYTE_SIZE - 1 downto 0 loop
                ld(b * BYTE_SIZE + bit_i) <= tmp(bit_i);
            end loop;
        end loop;
    end process;


    pipe_line <= ADDR(LINE_RANGE);

    imaybe_if_check: if REPORT_IF_MISUSE generate
        if_check_p: process(clk, res_n) is
            variable last_ix: std_logic_vector(LINE_RANGE);
            variable startup: boolean;
        begin
            if res_n /= '1' then
                if_misuse_stall <= false;
                last_ix := (others => '0');
                startup := true;
            else
                if (clk'event and clk = '1') then  
                    if (last_ix /= addr(LINE_RANGE) and (rd or we)) and not startup then
                        if_misuse_stall <= true;
                        assert false report "bad processor interface input" severity failure;
                    end if;

                    last_ix := next_addr(LINE_RANGE);
                    startup := false;
                end if;
            end if;
        end process if_check_p;
        
    else generate
        if_misuse_stall <= false;
    end generate;
    iffault <= if_misuse_stall;

    if_check_g : if REPORT_IF_MISUSE generate
        -- synthesis off
        if_check: process(clk, res_n) is
            variable last_stall: boolean := false; 
            variable stall_we: boolean;
            variable stall_rd: boolean;
            variable stall_byteena: std_logic_vector(byte_ena'range);
            variable stall_sd: std_logic_vector(sd'range);
            variable stall_addr: std_logic_vector(addr'range);
            variable stall_next_addr: std_logic_vector(next_addr'range);
        begin
            if res_n = '0' then
                last_stall := false;
            else
                if (clk'event and clk = '0') then  
                    if not (last_stall and stall)  or not stall_int then
                        stall_we := we;
                        stall_rd := rd;
                        stall_byteena := byte_ena;
                        stall_sd := sd;
                        stall_addr := addr;
                        stall_next_addr := next_addr;
                    end if;


                    assert  not stall_int or stall_we = we report "WE CHANGED DURING STALL!" severity failure;
                    assert  not stall_int or stall_rd = rd report "RD CHANGED DURING STALL!" severity failure;
                    assert  not stall_int or stall_sd = sd or not we report "SD CHANGED DURING STALL!" severity failure;
                    assert  not stall_int or stall_byteena = byte_ena  report "BYTE ENA CHANGED DURING STALL!" severity failure;
                    assert  not stall_int or stall_addr = addr  report "ADDR CHANGED DURING STALL!" severity failure;
                    last_stall := stall;
                end if;
            end if;
        end process;
        -- synthesis on
    end generate;


--    ███████╗██╗██╗     ██╗     
--    ██╔════╝██║██║     ██║     
--    █████╗  ██║██║     ██║     
--    ██╔══╝  ██║██║     ██║     
--    ██║     ██║███████╗███████╗
--    ╚═╝     ╚═╝╚══════╝╚══════╝
                               

fill_unit_state_p: process(clk, res_n) is
begin
    if res_n /= '1' then
        line_fill_ctr   <= 0;
        fill_state      <= IDLE;
    else
        if clk'event and clk = '1' then
            case fill_state is
                when IDLE => 
                    if start_fill then
                        fill_state      <= LOADING;
                        line_fill_ctr   <= 0;                   
                    end if;
                
                when LOADING => 
                    if rack then
                        line_fill_ctr <= next_line_fill_ctr; 
                    end if;

                    if line_fill_ctr = BUS_WORDS_PER_LINE - 1 and rack then
                        line_fill_ctr   <= 0; 
                        fill_state      <= IDLE;
                    end if;
            end case;


            last_used_line_fill_ctr <= used_line_fill_ctr;
        end if;
    end if;
end process fill_unit_state_p;

fill_unit_output_p: process(all) is
begin
    rreq <= false;

    fill_core_in            <= ZERO_CORE_IN;
    fill_core_in.rd_addr    <= addr(LINE_RANGE);
    fill_busy               <= false;
	used_line_fill_ctr      <= 0;
    
    if line_fill_ctr /= BUS_WORDS_PER_LINE - 1 then
        next_line_fill_ctr <= line_fill_ctr + 1;
    else
        next_line_fill_ctr <= 0;
    end if;

    -- memory to cache signals
    if BUS_WORDS_PER_LINE > 1 then
        raddr <= addr(TAG_RANGE) & addr(LINE_RANGE) & std_logic_vector(to_unsigned(used_line_fill_ctr, WORDS_IN_LINE_LOG - WORDS_PER_BUS_LOG)) & ZERO_BYTE_ADDR & ZERO_BUS_ADDR;
    else
        raddr <= addr(addr'left downto LINE_RANGE'right + Q_LOG) & ZERO_BYTE_ADDR & ZERO_BUS_ADDR;
    end if;
      

    case fill_state is
        when IDLE =>
            if start_fill then
                rreq <= true;
            end if;

        when LOADING =>
            if rack then 
                used_line_fill_ctr <= next_line_fill_ctr;
            else
                used_line_fill_ctr <= line_fill_ctr;
            end if;

            fill_busy <= true;
            
            if (used_line_fill_ctr = BUS_WORDS_PER_LINE - 1 or BUS_WORDS_PER_LINE = 0) and rack then 
                fill_core_in.mgmt_wr <= '1'; 
            end if;

            if not (last_used_line_fill_ctr = BUS_WORDS_PER_LINE - 1 and rack)then
                rreq <= true;
            end if;
          
            -- bytes freshly filled into the cache line are not dirty
            fill_core_in.dirties    <= (others => '0');
            fill_core_in.dirties_wr <= '1';
            -- filled line is valid
            fill_core_in.mgmt_data(VALID_IN_MGMT)   <= '1';
            fill_core_in.mgmt_data(TAG_IN_MGMT)     <= addr(TAG_RANGE);
            fill_core_in.mgmt_addr                  <= addr(LINE_RANGE);
            fill_core_in.wr_addr                    <= addr(LINE_RANGE);

            if rack then
                if BUS_WORDS_PER_LINE /= 0 then
                    for i in WORDS_PER_BUS - 1 downto 0 loop
                        for b in BYTES_PER_WORD - 1 downto 0 loop
                            fill_core_in.line_bens(((last_used_line_fill_ctr) * WORDS_PER_BUS + i) * BYTES_PER_WORD + b) <= '1';
                        end loop;
                    end loop;
                else
                    for b in BYTES_PER_WORD - 1 downto 0 loop
                        fill_core_in.line_bens(b) <= '1';
                    end loop;
                end if;
            end if;
    end case;


    -- memory to cache lines
    fill_core_in.line_wdata <= (others => (others => '0'));

    if BUS_WORDS_PER_LINE /= 0 then
        for i in WORDS_PER_BUS - 1 downto 0 loop
            for b in BYTES_PER_WORD - 1 downto 0 loop
                for bit_i in BYTE_SIZE - 1 downto 0 loop
                    fill_core_in.line_wdata(((last_used_line_fill_ctr) * WORDS_PER_BUS + i) * BYTES_PER_WORD + b)(bit_i) <= rdata((i*BYTES_PER_WORD + b) * BYTE_SIZE + bit_i);
                end loop;
            end loop;
        end loop;
    else
        for b in BYTES_PER_WORD - 1 downto 0 loop
            fill_core_in.line_wdata(b) <= rdata(((to_integer(unsigned(addr(WORD_IN_BUS_WORD)))*BYTES_PER_WORD + b + 1))*BYTE_SIZE - 1 downto (to_integer(unsigned(addr(WORD_IN_BUS_WORD)))*BYTES_PER_WORD + b) * BYTE_SIZE);
        end loop;
    end if;
end process fill_unit_output_p;


--    ██╗    ██╗██████╗ ██╗████████╗███████╗██████╗  █████╗  ██████╗██╗  ██╗    
--    ██║    ██║██╔══██╗██║╚══██╔══╝██╔════╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝    
--    ██║ █╗ ██║██████╔╝██║   ██║   █████╗  ██████╔╝███████║██║     █████╔╝     
--    ██║███╗██║██╔══██╗██║   ██║   ██╔══╝  ██╔══██╗██╔══██║██║     ██╔═██╗     
--    ╚███╔███╔╝██║  ██║██║   ██║   ███████╗██████╔╝██║  ██║╚██████╗██║  ██╗    
--     ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    
                                                                            
    writeback_unit_state_p: process(clk, res_n) is
    begin
        if res_n /= '1' then
            line_writeback_ctr <= 0;
            writeback_state <= IDLE;
            saved_writeback_line <= (others => '0');
        else
            if clk'event and clk = '1' then
                case writeback_state is
                    when IDLE => 
                        if start_writeback then
                            saved_writeback_line <= writeback_line;

                            writeback_state <= WRITING;
                            if not bus_word_dirty then
                                if BUS_WORDS_PER_LINE > 1 then
                                    line_writeback_ctr <= 1;             
                                else
                                    line_writeback_ctr <= 0;
                                    writeback_state <= IDLE;
                                end if;
                            end if;           
                        end if;
                    
                    when WRITING => 
                        if wack or not bus_word_dirty then
                            line_writeback_ctr <= next_line_writeback_ctr; 
                        end if;

                        if line_writeback_ctr = BUS_WORDS_PER_LINE - 1 and (wack or not bus_word_dirty) then
                            line_writeback_ctr <= 0; 
                            writeback_state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process writeback_unit_state_p;


    writeback_line_save_p: process(clk, res_n) is
    begin
        if res_n = '0' then
            saved_core_mgmt     <= (others => '0');
            saved_core_rdata    <= (others => (others => '0'));
            saved_core_dirties  <= (others => '0');
        else
            if clk'event and clk = '1' then 
                if save_core_data then
                    saved_core_mgmt     <= core_rmgmt;
                    saved_core_rdata    <= core_rdata;
                    saved_core_dirties  <= core_rdirties;
                else
                    saved_core_mgmt     <= saved_core_mgmt;
                    saved_core_rdata    <= saved_core_rdata;
                    saved_core_dirties  <= saved_core_dirties;
                end if;
            end if;
        end if;
    end process writeback_line_save_p;

    core_wb_sel_p: process(all) is
    begin
        if save_core_data then
            used_core_mgmt <= core_rmgmt;
            used_core_rdata <= core_rdata;
            used_core_rdirties <= core_rdirties;
        else
            used_core_mgmt <= saved_core_mgmt;
            used_core_rdata <= saved_core_rdata;
            used_core_rdirties <= saved_core_dirties;
        end if;
    end process core_wb_sel_p;

    bus_word_dirty <= not isAllStd(wbyte_ena_int, '0');
    wbyte_ena <= wbyte_ena_int;

    writeback_unit_output_p: process(all) is
        variable line_tag: std_logic_vector(TAG_WIDTH - 1 downto 0);
        variable used_writeback_line: std_logic_vector(writeback_line'range);
        variable bytei: natural;
        variable out_byte_i: natural;
    begin

        waddr           <= (others => '0');
        wreq            <= false;
        wdata           <= (others => '0');
        wbyte_ena_int   <= (others => '0');

        writeback_busy      <= false;
        writeback_busy_q    <= false;
        save_core_data      <= false;

        line_tag := used_core_mgmt(TAG_IN_MGMT);

        if wack then 
            used_line_writeback_ctr <= next_line_writeback_ctr;
        else
            used_line_writeback_ctr <= line_writeback_ctr;
        end if;

        if start_writeback and writeback_state = IDLE then
            used_writeback_line := writeback_line;
        else
            used_writeback_line := saved_writeback_line;
        end if;

        if BUS_WORDS_PER_LINE > 1 then
            waddr <= line_tag & used_writeback_line & std_logic_vector(to_unsigned(used_line_writeback_ctr, WORDS_IN_LINE_LOG - WORDS_PER_BUS_LOG)) & ZERO_BYTE_ADDR & ZERO_BUS_ADDR;
        else
            waddr <= line_tag & used_writeback_line & std_logic_vector(to_unsigned(used_line_writeback_ctr, WORDS_IN_LINE_LOG - WORDS_PER_BUS_LOG)) & ZERO_BYTE_ADDR & ZERO_BUS_ADDR;
        end if;
        
        
        for i in WORDS_PER_BUS - 1 downto 0 loop
            for b in BYTES_PER_WORD - 1 downto 0 loop
                bytei := (used_line_writeback_ctr * WORDS_PER_BUS + i) * BYTES_PER_WORD + b;
                out_byte_i := i * BYTES_PER_WORD + b;
                if BUS_WORDS_PER_LINE /= 0 then
                    wbyte_ena_int(out_byte_i) <= used_core_rdirties(bytei);
                else
                    wbyte_ena_int(out_byte_i + to_integer(unsigned(addr(BYTES_PER_BUS_WORD_LOG downto BYTES_IN_LINE_LOG + 1))) * BYTES_IN_LINE) <= used_core_rdirties(bytei);
                    end if;
            end loop;
        end loop;

        for i in WORDS_PER_BUS - 1 downto 0 loop
            for b in BYTES_PER_WORD - 1 downto 0 loop
                bytei := (used_line_writeback_ctr * WORDS_PER_BUS + i) * BYTES_PER_WORD + b;
                for bit_i in BYTE_SIZE - 1 downto 0 loop
                    if BUS_WORDS_PER_LINE /= 0 then
                        wdata((i*BYTES_PER_WORD + b) * BYTE_SIZE + bit_i) <= used_core_rdata(bytei)(bit_i);
                    else
                        wdata((i*BYTES_PER_WORD + b) * BYTE_SIZE + bit_i) <= used_core_rdata(i * BYTES_PER_WORD + b)(bit_i);
                    end if;
                end loop;
            end loop;
        end loop;



        if line_writeback_ctr /= BUS_WORDS_PER_LINE - 1 then
            next_line_writeback_ctr <= line_writeback_ctr + 1;
        else
            next_line_writeback_ctr <= 0;
        end if;

        case writeback_state is
            when IDLE => 
                if start_writeback then
                    writeback_busy <= true;
                    save_core_data <= true;
                    if bus_word_dirty then
                        wreq <= true;
                    end if;
                end if;

            when WRITING => 
                writeback_busy      <= true;
                writeback_busy_q    <= true;
                if bus_word_dirty and not (line_writeback_ctr = BUS_WORDS_PER_LINE - 1 and wack) then
                    wreq <= true;
                end if;
        end case;
   
    end process writeback_unit_output_p;




--    ███████╗██╗     ██╗   ██╗███████╗██╗  ██╗
--    ██╔════╝██║     ██║   ██║██╔════╝██║  ██║
--    █████╗  ██║     ██║   ██║███████╗███████║
--    ██╔══╝  ██║     ██║   ██║╚════██║██╔══██║
--    ██║     ███████╗╚██████╔╝███████║██║  ██║
--    ╚═╝     ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝
                                             

    mgm_unit_state_p: process(clk, res_n) is
    begin
        if res_n /= '1' then
            mgm_state <= RESET;
            mgm_line_ix <= (others => '0');
        else
            if clk'event and clk = '1' then
                case mgm_state is
                    when RESET => 
                        if unsigned(mgm_line_ix) = LINES - 1 then
                            mgm_state <= WAITS;
                        else
                            mgm_line_ix <= next_mgm_line_ix;
                        end if;
                    when WAITS => 
                        mgm_state <= IDLE;
                        mgm_line_ix <= (others => '0');

                    when IDLE => 
                        if start_mgm_op then
                            if we then 
                                mgm_state <= WAIT_STORE;
                            else
                                mgm_state <= ITERATING;
                            end if;
                        end if;
                    when WAIT_STORE => 
                        mgm_state <= ITERATING; 

                    when ITERATING => 
                        if not writeback_busy then
                            if not start_end_same_tag and unsigned(mgm_line_ix) = LINES - 1 then
                                mgm_state <= RESTORE_PIPE_ADDR;
                                mgm_line_ix <= (others => '0');
                            elsif start_end_same_tag and mgm_line_ix = mgm_end(LINE_RANGE) then
                                mgm_state <= RESTORE_PIPE_ADDR;
                                mgm_line_ix <= (others => '0');
                            else
                                mgm_line_ix <= next_mgm_line_ix;
                            end if;
                        end if;
                    when RESTORE_PIPE_ADDR => 
                        mgm_state <= DONE;
                    when DONE => 
                        if not (mgm_flush or mgm_inval) then
                            mgm_state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process mgm_unit_state_p;

    line_in_mgm_range <= to_integer(unsigned(line_tag_selected)) >= to_integer(unsigned(mgm_start(TAG_RANGE)))
                       and to_integer(unsigned(line_tag_selected)) <= to_integer(unsigned(mgm_end(TAG_RANGE)))
                       and to_integer(unsigned(mgm_core_in.wr_addr)) >= to_integer(unsigned(mgm_start(LINE_RANGE)))
                       and to_integer(unsigned(mgm_core_in.wr_addr)) <= to_integer(unsigned(mgm_end(LINE_RANGE)));

    in_locked_range <= to_integer(unsigned(addr(TAG_RANGE))) >= to_integer(unsigned(mgm_start(TAG_RANGE)))
               and to_integer(unsigned(addr(TAG_RANGE))) <= to_integer(unsigned(mgm_end(TAG_RANGE)))
               and to_integer(unsigned(addr(LINE_RANGE))) >= to_integer(unsigned(mgm_start(LINE_RANGE)))
               and to_integer(unsigned(addr(LINE_RANGE))) <= to_integer(unsigned(mgm_end(LINE_RANGE)));
               
    start_end_same_tag <= mgm_start(TAG_RANGE) = mgm_end(TAG_RANGE);
    mgm_active <= mgm_busy;

    mgm_unit_output_p: process(all) is
        variable next_mgm_line_ix_int: line_addr_log_T;

        variable started_cleaning: boolean;
    begin
        mgm_busy <= true;
        mgm_stall <= false;
        req_writeback <= false;
        mgmt_wait_release <= false;

        mgm_core_in <= ZERO_CORE_IN;
        
        next_mgm_line_ix_int := std_logic_vector(unsigned(mgm_line_ix) + 1);

        case mgm_state is
            when RESET => 
                mgm_core_in.wr_addr <= mgm_line_ix;
                mgm_core_in.mgmt_addr <= mgm_line_ix;
                mgm_core_in.mgmt_wr <= '1';
                mgm_core_in.dirties_wr <= '1';
                
            
            when WAITS => null; -- make sure our invalidation went through before we resume regular pipeline operation

            when WAIT_STORE => 
                if start_end_same_tag then
                    mgm_core_in.rd_addr <= mgm_start(LINE_RANGE);
                else
                    mgm_core_in.rd_addr <= mgm_line_ix;
                end if;

                
                mgm_core_in.wr_addr <= addr(LINE_RANGE);

            when IDLE => 
                mgm_busy <= false;
                mgm_core_in <= pipe_core_in;
                mgm_core_in.rd_addr <= mgm_line_ix;
                

                if start_end_same_tag then
                    mgm_core_in.rd_addr <= mgm_start(LINE_RANGE);
                end if;

                
                
            when ITERATING => 
                if not writeback_busy then
                    mgm_core_in.rd_addr <= next_mgm_line_ix_int;
                    mgm_core_in.mgmt_addr <= next_mgm_line_ix_int;
                else
                    mgm_core_in.rd_addr <= mgm_line_ix;
                    mgm_core_in.mgmt_addr <= mgm_line_ix;
                end if;

                if mgm_flush then -- write back changed data to memory 
                    if line_valid = '1' and line_in_mgm_range and line_is_dirty then
                        mgm_core_in.dirties_wr <= '1';
                        mgm_core_in.mgmt_addr <= mgm_line_ix;
                        req_writeback <= true;
                        mgm_stall <= true;
                    end if;
                end if;

                if mgm_inval then -- remove a line from the cache
                    if line_valid = '1' and line_in_mgm_range then
                        mgm_core_in.mgmt_wr <= '1';
                        mgm_core_in.mgmt_addr <= mgm_line_ix;
                    end if;
                end if;
            
            when RESTORE_PIPE_ADDR => 
                mgm_core_in.mgmt_addr <= next_addr(LINE_RANGE);
                mgm_core_in.rd_addr <= next_addr(LINE_RANGE);

            when DONE => 
                mgm_core_in.mgmt_addr <= next_addr(LINE_RANGE);
                mgm_core_in.rd_addr <= next_addr(LINE_RANGE);
                mgm_busy <= false;
                mgmt_wait_release <= true;
        end case;

        next_mgm_line_ix <= next_mgm_line_ix_int;
        mgm_line <= mgm_line_ix;
    end process mgm_unit_output_p;
END ARCHITECTURE behav;
