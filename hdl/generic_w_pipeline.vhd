--
-- VHDL Architecture generic_cache_lib.generic_w_pipeline.behav
--
-- Created:
--          by - surfer.UNKNOWN (SURFER-A0000001)
--          at - 21:55:52 15.12.2024
--
-- using Mentor Graphics HDL Designer(TM) 2021.1 Built on 14 Jan 2021 at 15:11:42
--
LIBRARY ieee;
USE ieee.std_logic_1164.all;
use IEEE.math_real.all;
use ieee.numeric_std.all;

LIBRARY generic_cache_lib;
USE generic_cache_lib.generic_caches.all;

ENTITY generic_w_pipeline IS
    GENERIC(
        ADDR_WIDTH: positive := 64;
        BUS_WIDTH: positive := 256;
        DEPTH: natural := 8;
        RETENTION_LEVEL: natural := 4;
        COALESCING: boolean := false
    );
    PORT(
        clk, res_n              : IN std_logic;

        flush                   : IN boolean := false;
        flush_active            : OUT boolean;

        entry_probe_addr        : IN std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
        entry_exists            : OUT boolean;

        wreq_m                  : OUT boolean;
        wack_m                  : IN boolean := false;
        waddr_m                 : OUT std_logic_vector(ADDR_WIDTH - 1 downto 0);
        wdata_m                 : OUT std_logic_vector(BUS_WIDTH - 1 downto 0);
        wbyte_ena_m             : OUT std_logic_vector(BUS_WIDTH/BYTE_SIZE - 1 downto 0);

        wreq_c                  : IN boolean;
        wack_c                  : OUT boolean := false;
        waddr_c                 : IN std_logic_vector(ADDR_WIDTH - 1 downto 0);
        wdata_c                 : IN std_logic_vector(BUS_WIDTH - 1 downto 0);
        wbyte_ena_c             : IN std_logic_vector(BUS_WIDTH/8 - 1 downto 0);

        rreq_m                  : OUT boolean;
        rack_m                  : IN boolean := false;
        raddr_m                 : OUT std_logic_vector(ADDR_WIDTH - 1 downto 0);
        rdata_m                 : IN std_logic_vector(BUS_WIDTH - 1 downto 0) := (others => '0');

        rreq_c                  : IN boolean := false;
        rack_c                  : OUT boolean;
        raddr_c                 : IN std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
        rdata_c                 : OUT std_logic_vector(BUS_WIDTH - 1 downto 0)
    );
END ENTITY generic_w_pipeline;



ARCHITECTURE behav OF generic_w_pipeline IS
    constant BYTES_PER_BUS_WORD: natural := BUS_WIDTH / BYTE_SIZE;
    constant BUS_WIDTH_LOG: natural := integer(ceil(log2(real(BYTES_PER_BUS_WORD))));
    subtype bus_word_T is std_logic_vector(wdata_c'range);
    subtype bena_T is std_logic_vector(wbyte_ena_c'range);

    subtype BUS_WORD_ADDR is natural range ADDR_WIDTH - 1 downto BUS_WIDTH_LOG;
    subtype trunc_addr_T is std_logic_vector(BUS_WORD_ADDR);
    subtype insert_index_T is natural range DEPTH downto 0;
    constant ZERO_BUS_ADDR: std_logic_vector(BUS_WIDTH_LOG - 1 downto 0) := (others => '0');

    type write_entry_T is record
        valid: boolean;
        data: bus_word_T;
        bena: bena_T;
        addr: trunc_addr_T;
    end record write_entry_T;
    constant ZERO_WRITE_ENTRY: write_entry_T := (valid => false, data => (others => '0'), addr => (others => '0'), bena => (others => '0'));

    type write_pipe_T is array(DEPTH - 1 downto 0) of write_entry_T;

    type flush_state_T is (IDLE, PRIMING, FLUSHING);
    signal flush_state: flush_state_T;

    signal write_pipe: write_pipe_T;
    signal next_write_pipe: write_pipe_T;
    signal insert_index: insert_index_T;
    signal next_insert_index: insert_index_T;
    signal used_insert_index: insert_index_T;

    signal pipe_full: boolean;
    signal pipe_empty: boolean;
    signal shift_pipe: boolean;
    signal insert_new_into_pipe: boolean;
    signal next_wack: boolean;
    signal pipe_above_level: boolean;
    signal flush_pipe: boolean;
    signal out_entry: write_entry_T;

    signal entry_is_all_bytes: boolean;
    signal keep_entry: boolean;
    signal transaction_started: boolean;

    signal next_data_entirely_in_pipe: boolean;
    signal data_entirely_in_pipe: boolean;
    signal last_raddr_c: std_logic_vector(raddr_c'range);

    signal waddr_pipe_matches: std_logic_vector(write_pipe'range);
    signal last_waddr_pipe_matches: std_logic_vector(write_pipe'range);
    signal any_waddr_pipe_match: boolean;

    --debug
    signal coalesced_entry: std_logic_vector(write_pipe'range);
    signal coalescing_active: boolean;
    signal coalesced_entry_q: std_logic_vector(write_pipe'range);

    signal content_probe_pipe_matches: std_logic_vector(write_pipe'range);

    signal entry_fwd: boolean_vector(10 downto 0);
BEGIN
    wp: if DEPTH = 0 generate
        -- if we dont have a write buffer at all, just pass the signals through
        wreq_m          <= wreq_c;
        wbyte_ena_m     <= wbyte_ena_c;
        wdata_m         <= wdata_c;
        waddr_m         <= waddr_c;
        wack_c          <= wack_m;

        rreq_m          <= rreq_c;
        raddr_m         <= raddr_c;
        rdata_c         <= rdata_m;
        rack_c          <= rack_m;

        flush_active    <= flush;
    else generate

--      ███████╗██╗     ██╗   ██╗███████╗██╗  ██╗
--      ██╔════╝██║     ██║   ██║██╔════╝██║  ██║
--      █████╗  ██║     ██║   ██║███████╗███████║
--      ██╔══╝  ██║     ██║   ██║╚════██║██╔══██║
--      ██║     ███████╗╚██████╔╝███████║██║  ██║
--      ╚═╝     ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝
        
        flush_stall_state_p: process(clk, res_n) is
        begin
            if res_n /= '1' then
                flush_state <= IDLE;
            else
                if (clk'event and clk = '1') then  
                    case flush_state is
                        when IDLE => 
                            if flush then
                                flush_state <= PRIMING;
                            end if;
                        when PRIMING =>
                            if not flush then
                                flush_state <= FLUSHING;
                            end if;
                        when FLUSHING => 
                            if pipe_empty then
                                flush_state <= IDLE;
                            end if;
                    end case;
                end if;
            end if;
        end process flush_stall_state_p;

        flush_pipe <= flush_state = FLUSHING;
        flush_active <= flush_pipe or flush_state = PRIMING;


--     ██████╗ █████╗       ██╗   ██████╗ ██████╗ 
--     ██╔════╝██╔══██╗     ╚██╗ ██╔════╝██╔═══██╗
--     ██║     ███████║█████╗╚██╗██║     ██║   ██║
--     ██║     ██╔══██║╚════╝██╔╝██║     ██║   ██║
--     ╚██████╗██║  ██║     ██╔╝ ╚██████╗╚██████╔╝
--      ╚═════╝╚═╝  ╚═╝     ╚═╝   ╚═════╝ ╚═════╝ 
--    cache to core 

        insert_index_p: process(clk, res_n) is
        begin
            if res_n /= '1' then
                insert_index <= 0;
            else
                if (clk'event and clk = '1') then
                    insert_index <= next_insert_index;
                end if;
            end if;
        end process insert_index_p;

        insert_indeces_p: process(all) is
        begin
            next_insert_index <= insert_index;
            if shift_pipe and insert_new_into_pipe then
                if pipe_full then
                    next_insert_index <= insert_index - 1;
                end if;
            elsif shift_pipe then
                if insert_index /= 0 then
                    next_insert_index <= insert_index - 1;
                else
                    next_insert_index <= 0;
                end if;
            elsif insert_new_into_pipe then
                if insert_index /= DEPTH - 1 then
                    next_insert_index <= insert_index + 1;
                end if;
            end if;
            
            if wreq_c then 
                used_insert_index <= next_insert_index;
            else
                used_insert_index <= insert_index;
            end if;
        end process insert_indeces_p;





--        ██████╗ ██████╗  ██████╗ ███████╗
--        ██╔════╝██╔═══██╗██╔══██╗██╔════╝
--        ██║     ██║   ██║██████╔╝█████╗  
--        ██║     ██║   ██║██╔══██╗██╔══╝  
--        ╚██████╗╚██████╔╝██║  ██║███████╗
--         ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
        
        -- we shift when the memory consumed the entry or the entry is junk

        -- core status
        pipe_full <= insert_index = DEPTH - 1;
        pipe_empty <= insert_index = 0 and not write_pipe(0).valid;
        pipe_above_level <= next_insert_index > RETENTION_LEVEL or flush_pipe;

        -- regular write entry insertion
        shift_pipe <= (wack_m or not write_pipe(0).valid) and not (keep_entry or pipe_empty);
        insert_new_into_pipe <= wreq_c and not (pipe_full or (any_waddr_pipe_match and COALESCING)) and not flush_pipe;

        -- coalescing
        any_waddr_pipe_match <= not isAllStd(waddr_pipe_matches, '0');
        coalescing_active <= not isAllStd(coalesced_entry, '0');

        -- entry probing
        entry_exists <= not isAllStd(content_probe_pipe_matches, '0');

        pipe_mem: for pi in write_pipe'range generate
            signal waddr_match: boolean;
        begin
            entry_mem_p: process(clk, res_n) is
            begin
                if res_n /= '1' then
                    write_pipe(pi) <= ZERO_WRITE_ENTRY;
                    last_waddr_pipe_matches(pi) <= '0';
                else
                    if (clk'event and clk = '1') then  
                        write_pipe(pi) <= next_write_pipe(pi);
                        last_waddr_pipe_matches(pi) <= waddr_pipe_matches(pi);
                    end if;
                end if;
            end process entry_mem_p;
            
            addr_match_p: process(all) is
            begin
                if write_pipe(pi).addr = entry_probe_addr(BUS_WORD_ADDR) and write_pipe(pi).valid then
                    content_probe_pipe_matches(pi) <= '1';
                else
                    content_probe_pipe_matches(pi) <= '0';
                end if;

                if write_pipe(pi).addr = waddr_c(BUS_WORD_ADDR) and write_pipe(pi).valid and pi /= 0 and pi /= 1 then
                    waddr_pipe_matches(pi) <= '1';
                else
                    waddr_pipe_matches(pi) <= '0';
                end if;
            end process addr_match_p;


            entry_in_p: process(all) is
                variable waddr_matches_entry: boolean;
                variable next_entry: write_entry_T;
            begin
                next_entry := write_pipe(pi);
                waddr_matches_entry := false;
					 coalesced_entry(pi) <= '0';
                
                if shift_pipe then
                    if pi /= write_pipe'high then
                        -- ugh, thank modelsim for that minof-awfulness ;C
                        next_entry := write_pipe(minOf2(pi+1, DEPTH - 1));
                    else    
                        next_entry := ZERO_WRITE_ENTRY;
                    end if;
                end if;

                if insert_new_into_pipe and pi = used_insert_index then
                    next_entry.valid := true;
                    next_entry.addr  := waddr_c(BUS_WORD_ADDR);
                    next_entry.bena  := wbyte_ena_c;
                    next_entry.data  := wdata_c;
                else
                    -- do the address of the current write entry and the write bus word address match?
                    if shift_pipe then
                        if pi /= write_pipe'high then
                            waddr_matches_entry := waddr_pipe_matches(minOf2(pi+1, DEPTH - 1)) = '1';
                        end if;
                    else
                        waddr_matches_entry := waddr_pipe_matches(pi) = '1';
                    end if;

                    -- coalesc entries
                    if waddr_matches_entry and wreq_c and COALESCING then
                        for b in wbyte_ena_c'range loop
                            if wbyte_ena_c(b) = '1' then
                                coalesced_entry(pi) <= '1';
                                -- overwrite pipe data with incoming data
                                for bit_i in BYTE_SIZE - 1 downto 0 loop
                                    next_entry.data(b * BYTE_SIZE + bit_i) := wdata_c(b * BYTE_SIZE + bit_i);
                                end loop;
                                next_entry.bena(b) := '1';
                            end if;
                        end loop;
                    end if; 
                end if;

                next_write_pipe(pi) <= next_entry;
            end process entry_in_p;
        end generate;


        --debug
        debug_info_reg_p: process(clk, res_n) is
        begin
            if res_n /= '1' then
                coalesced_entry_q <= (others => '0');
            else
                if (clk'event and clk = '1') then 
                    coalesced_entry_q <= coalesced_entry; 
                end if;
            end if;
        end process debug_info_reg_p;

        -- we forward the second entry to circumvent the 2 cycle delay
        out_entry   <= write_pipe(0) when not (wack_m or coalescing_active) else next_write_pipe(0);
        wreq_m      <= out_entry.valid and pipe_above_level and (not keep_entry or transaction_started) and not wack_m;
        waddr_m     <= out_entry.addr & ZERO_BUS_ADDR;
        wbyte_ena_m <= out_entry.bena;
        wdata_m     <= out_entry.data;
        
        -- the memory interface requires at least one clock cycle between wreq and wack
        next_wack   <= wreq_c and (any_waddr_pipe_match or not pipe_full) and not flush_pipe;
        wack_delay_p: process(clk, res_n) is
        begin
            if res_n /= '1' then
                wack_c <= false;
                transaction_started <= false;
            else
                if (clk'event and clk = '1') then  
                    wack_c <= next_wack;

                    if wreq_m then
                        transaction_started <= true;
                    elsif wack_m then
                        transaction_started <= false;
                    end if;
                end if;
            end if;
        end process wack_delay_p;


--      ██████╗ ██████╗       ██╗  ██████╗ █████╗ 
--      ██╔════╝██╔═══██╗     ╚██╗ ██╔════╝██╔══██╗
--      ██║     ██║   ██║█████╗╚██╗██║     ███████║
--      ██║     ██║   ██║╚════╝██╔╝██║     ██╔══██║
--      ╚██████╗╚██████╔╝     ██╔╝ ╚██████╗██║  ██║
--       ╚═════╝ ╚═════╝      ╚═╝   ╚═════╝╚═╝  ╚═╝
--      core to cache

        -- we need to search in the write buffer and give its entries a higher priority than the data from the memory
        rdata_fwd_p: process(all) is
        begin
            rdata_c <= rdata_m; 
            entry_is_all_bytes <= false;
            keep_entry <= false;

            for i in 0 to DEPTH - 1 loop 
                entry_fwd(i) <= false;

                if write_pipe(i).addr = raddr_c(BUS_WORD_ADDR) then
                    if isAllStd(write_pipe(i).bena, '1') then
                        entry_is_all_bytes <= true;
                    end if;
                end if;

                if write_pipe(i).addr = last_raddr_c(BUS_WORD_ADDR) then 
                    -- make sure we dont write a entry away which we want to read and might have acked already
                    if i = 0 and rreq_c then
                        keep_entry <= true;                  
                    end if;
                    entry_fwd(i) <= true;

                    

                    for b in write_pipe(i).bena'range loop
                        if write_pipe(i).bena(b) = '1' then
                            for bit_i in BYTE_SIZE - 1 downto 0 loop
                                rdata_c(b * BYTE_SIZE + bit_i) <= write_pipe(i).data(b * BYTE_SIZE + bit_i);
                            end loop;
                        end if;
                    end loop;
                end if;
            end loop;
        end process rdata_fwd_p;

        rreq_m      <= rreq_c and not entry_is_all_bytes;
        raddr_m     <= raddr_c;
        rack_c      <= rack_m or data_entirely_in_pipe;
        next_data_entirely_in_pipe <= entry_is_all_bytes and rreq_c;
        rack_delay_p: process(clk, res_n) is
        begin
            if res_n /= '1' then
                data_entirely_in_pipe <= false;
                last_raddr_c <= (others => '0');
            else
                if (clk'event and clk = '1') then  
                    data_entirely_in_pipe <= next_data_entirely_in_pipe;
                    last_raddr_c <= raddr_c;
                end if;
            end if;
        end process rack_delay_p;
    end generate;

END ARCHITECTURE behav;

