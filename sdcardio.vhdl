use WORK.ALL;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;

entity sdcardio is
  port (
    clock : in std_logic;
    reset : in std_logic;

    ---------------------------------------------------------------------------
    -- fast IO port (clocked at core clock). 1MB address space
    ---------------------------------------------------------------------------
    fastio_addr : in unsigned(19 downto 0);
    fastio_write : in std_logic;
    fastio_read : in std_logic;
    fastio_wdata : in unsigned(7 downto 0);
    fastio_rdata : out unsigned(7 downto 0);
    fastio_sd_rdata : out unsigned(7 downto 0);

    colourram_at_dc00 : in std_logic;
    viciii_iomode : in std_logic_vector(1 downto 0);
    
    sectorbuffermapped : out std_logic := '0';
    sectorbuffermapped2 : out std_logic := '0';
    sectorbuffercs : in std_logic;

    led : out std_logic := '0';
    motor : out std_logic := '0';
    
    sw : in std_logic_vector(15 downto 0);
    btn : in std_logic_vector(4 downto 0);
    
    -------------------------------------------------------------------------
    -- Lines for the SDcard interface itself
    -------------------------------------------------------------------------
    cs_bo : out std_logic;
    sclk_o : out std_logic;
    mosi_o : out std_logic;
    miso_i : in  std_logic
    );
end sdcardio;

architecture behavioural of sdcardio is
  
  component sd_controller is
    port (
        cs : out std_logic;
        mosi : out std_logic;
        miso : in std_logic;
        sclk : out std_logic;

        sector_number : in std_logic_vector(31 downto 0);  -- sector number requested
        sdhc_mode : in std_logic;
        rd : in std_logic;
        wr : in std_logic;
        dm_in : in std_logic;   -- data mode, 0 = write continuously, 1 = write single block
        reset : in std_logic;
        data_ready : out std_logic;     -- 1= data written, or data accepted,
                                        -- 0= wait for data, or pre-load data
                                        -- for writing
        din : in std_logic_vector(7 downto 0);
        dout : out std_logic_vector(7 downto 0);
        clk : in std_logic      -- twice the SPI clk
        );
  end component;

  component ram8x512 IS
  PORT (
    clka : IN STD_LOGIC;
    ena : IN STD_LOGIC;
    wea : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
    addra : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    dina : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    douta : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    clkb : IN STD_LOGIC;
    enb : IN STD_LOGIC;
    web : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
    addrb : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    dinb : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    doutb : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
  );
  END component;
  
  signal skip : integer range 0 to 2;
  signal read_bytes : std_logic;
  signal sd_doread       : std_logic := '0';
  signal sd_dowrite      : std_logic := '0';
  signal data_ready : std_logic := '0';
  
  signal sd_sector       : unsigned(31 downto 0) := (others => '0');
  signal sd_datatoken    : unsigned(7 downto 0);
  signal sd_rdata        : std_logic_vector(7 downto 0);
  signal sd_wdata        : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_error        : std_logic;
  signal sd_reset        : std_logic := '1';
  signal sdhc_mode : std_logic := '0';
  
  -- IO mapped register to indicate if SD card interface is busy
  signal sdio_busy : std_logic := '0';
  signal sdio_error : std_logic := '0';
  signal sdio_fsm_error : std_logic := '0';

  signal sector_buffer_mapped : std_logic := '0';

  -- Counter for reading/writing sector
  signal sector_offset : unsigned(9 downto 0);
  signal sbweb : std_logic_vector(0 downto 0) := "0";
  
  type sd_state_t is (Idle,
                      ReadSector,ReadingSector,ReadingSectorAckByte,DoneReadingSector,
                      WriteSector,WritingSector,WritingSectorAckByte,
                      DoneWritingSector);
  signal sd_state : sd_state_t := Idle;

  -- F011 FDC emulation registers and flags
  signal diskimage_sector : unsigned(31 downto 0) := x"ffffffff";
  signal diskimage_enable : std_logic := '0';
  signal diskimage_offset : unsigned(10 downto 0);
  signal f011_track : unsigned(7 downto 0) := x"00";
  signal f011_sector : unsigned(7 downto 0) := x"00";
  signal f011_side : unsigned(7 downto 0) := x"00";
  signal f011_sector_fetch : std_logic := '0';

  signal f011_buffer_address : unsigned(8 downto 0) := (others => '0');
  signal f011_buffer_next_read : unsigned(8 downto 0) := (others => '0');
  signal f011_fdc_buffer_write : std_logic := '0';
  signal f011_buffer_wdata : unsigned(7 downto 0);
  signal f011_buffer_rdata : unsigned(7 downto 0);
  signal f011_flag_eq : std_logic := '1';
  signal f011_swap : std_logic := '0';
  signal f011_rdata : unsigned(7 downto 0);
  signal f011_buffer_write : std_logic := '0';
  signal f011_wdata : unsigned(7 downto 0);

  signal f011_irqenable : std_logic := '0';
  
  signal f011_cmd : unsigned(7 downto 0) := x"00";
  signal f011_busy : std_logic := '0';
  signal f011_lost : std_logic := '0';
  signal f011_irq : std_logic := '0';
  signal f011_rnf : std_logic := '0';
  signal f011_crc : std_logic := '0';
  signal f011_drq : std_logic := '0';
  signal f011_ds : unsigned(2 downto 0) := "000";
  signal f011_track0 : std_logic := '0';
  signal f011_head_track : unsigned(6 downto 0) := "0000000";
  signal f011_disk_present : std_logic := '0';
  signal f011_over_index : std_logic := '0';
  signal f011_disk_changed : std_logic := '0';

  signal f011_rsector_found : std_logic := '0';
  signal f011_wsector_found : std_logic := '0';
  signal f011_write_gate : std_logic := '0';
  signal f011_write_protected : std_logic := '0';

  signal f011_led : std_logic := '0';
  signal f011_motor : std_logic := '0';
  
begin  -- behavioural

  --**********************************************************************
  -- SD card controller module.
  --**********************************************************************
  
  sd0: sd_controller 
    port map (
	cs => cs_bo,
	mosi => mosi_o,
	miso => miso_i,
	sclk => sclk_o,

        sector_number => std_logic_vector(sd_sector),
        sdhc_mode => sdhc_mode,
	rd =>  sd_doread,
	wr =>  sd_dowrite,
	dm_in => '1',	-- data mode, 0 = write continuously, 1 = write single block
	reset => sd_reset,
        data_ready => data_ready,
	din => sd_wdata,
	dout => sd_rdata,
	clk => clock	-- twice the SPI clk.  XXX Cannot exceed 50MHz
        );

  ram0: ram8x512
    port map (
      clka => clock,
      ena => sectorbuffercs,
      wea(0) => fastio_write,
      addra => std_logic_vector(fastio_addr(8 downto 0)),
      dina => std_logic_vector(fastio_wdata),
      unsigned(douta) => fastio_sd_rdata,

      clkb => clock,
      enb => '1',
      web => sbweb,
      addrb => std_logic_vector(sector_offset(8 downto 0)),
      dinb => sd_rdata,
      doutb => sd_wdata
      
      );

  ram1: ram8x512
    port map (
      -- FDC side access to the buffer
      clka => clock,
      ena => '1',
      wea(0) => f011_fdc_buffer_write,
      addra => std_logic_vector(f011_buffer_address),
      dina => std_logic_vector(f011_buffer_wdata),
      unsigned(douta) => f011_buffer_rdata,

      -- fastio side access to the buffer
      clkb => clock,
      enb => '1',
      web(0) => f011_buffer_write,
      addrb => std_logic_vector(f011_buffer_next_read(8 downto 0)),
      dinb => std_logic_vector(f011_wdata),
      unsigned(doutb) => f011_rdata      
      );

  
  -- XXX also implement F1011 floppy controller emulation.
  process (clock,fastio_addr,fastio_wdata,sector_buffer_mapped,sdio_busy,
           sd_reset,fastio_read,sd_sector,fastio_write,
           f011_track,f011_sector,f011_side,sdio_fsm_error,sdio_error,
           sd_state) is
    variable temp_cmd : unsigned(7 downto 0);
  begin
    
    if rising_edge(clock) then

      f011_buffer_write <= '0';
      if f011_buffer_address = f011_buffer_next_read then
        f011_flag_eq <= '0';
      else
        f011_flag_eq <= '0';
      end if;
      f011_fdc_buffer_write <= '0';
      if f011_head_track="0000000" then
        f011_track0 <= '1';
      else
        f011_track0 <= '0';
      end if;
      
      -- update diskimage offset
      diskimage_offset(10 downto 0) <=
        to_unsigned(
          to_integer(f011_track(6 downto 0) & "0000")
          +to_integer("00" & f011_track(6 downto 0) & "00")
          +to_integer("000" & f011_sector),11);
      -- and don't let it point beyond the end of the disk
      if (f011_track >= 80) or (f011_sector >= 20) then
        -- point to last sector if disk instead
        diskimage_offset <= to_unsigned(1599,11);
      end if;
      
      -- De-map sector buffer if VIC-IV maps colour RAM at $DC00
      report "colourram_at_dc00 = " &
std_logic'image(colourram_at_dc00) & ", sector_buffer_mapped = " & std_logic'image(sector_buffer_mapped) severity note;
      if colourram_at_dc00='1' or viciii_iomode(1)='0' then
        report "unmapping sector buffer due to mapping of colour ram/D02F mode select" severity note;
        sector_buffer_mapped <= '0';
        sectorbuffermapped <= '0';
        sectorbuffermapped2 <= '0';
      else
        sectorbuffermapped <= sector_buffer_mapped;
        sectorbuffermapped2 <= sector_buffer_mapped;
      end if;
      
      fastio_rdata <= (others => 'Z');
      
      if  fastio_read='0' and fastio_write='1' then
        if fastio_write='1' then
          if (fastio_addr(19 downto 5)&'0' = x"D108")
            or (fastio_addr(19 downto 5)&'0' = x"D308") then
            -- F011 FDC emulation registers
            case fastio_addr(4 downto 0) is
              when "00000" =>           -- $D080
                -- CONTROL |  IRQ  |  LED  | MOTOR | SWAP  | SIDE  |  DS2  |  DS1  |  DS0  | 0 RW
                --IRQ     When set, enables interrupts to occur,  when reset clears and
                --        disables interrupts.
                --LED     These  two  bits  control  the  state  of  the  MOTOR and LED
                --MOTOR   outputs. When both are clear, both MOTOR and LED outputs will
                --        be off. When MOTOR is set, both MOTOR and LED Outputs will be
                --        on. When LED is set, the LED will "blink".
                --SWAP    swaps upper and lower halves of the data buffer
                --        as seen by the CPU.
                --SIDE    when set, sets the SIDE output to 0, otherwise 1.
                --DS2-DS0 these three bits select a drive (drive 0 thru drive 7).  When
                --        DS0-DS2  are  low  and  the LOCAL input is true (low) the DR0
                --        output will go true (low).
                f011_irqenable <= fastio_wdata(7);
                f011_led <= fastio_wdata(6);
                led <= fastio_wdata(6);
                f011_motor <= fastio_wdata(5);
                motor <= fastio_wdata(5);
                f011_swap <= fastio_wdata(4);
                f011_side(0) <= fastio_wdata(3);
                f011_ds <= fastio_wdata(2 downto 0);
                if fastio_wdata(2 downto 0) /= f011_ds then
                  f011_disk_changed <= '0';
                end if;
              when "00001" =>           -- $D081
                -- COMMAND | WRITE | READ  | FREE  | STEP  |  DIR  | ALGO  |  ALT  | NOBUF | 1 RW
                --WRITE   must be set to perform write operations.
                --READ    must be set for all read operations.
                --FREE    allows free-format read or write vs formatted
                --STEP    write to 1 to cause a head stepping pulse.
                --DIR     sets head stepping direction
                --ALGO    selects read and write algorithm. 0=FC read, 1=DPLL read,
                --        0=normal write, 1=precompensated write.

                --ALT     selects alternate DPLL read recovery method. The ALG0 bit
                --        must be set for ALT to work.
                --NOBUF   clears the buffer read/write pointers

                --  Legal commands are...
                --
                -- hexcode notes   macro   function
                -- ------- -----   -----   --------
                -- 40    1,4,5   RDS     Read Sector
                -- 80    1,2     WTS     Write Sector
                -- 60    1,4,5   RDT     Read Track
                -- A0    1,2     WTT     Write Track (format)
                -- 10    3       STOUT   Head Step Out
                -- 14    3       TIME    Time 1 head step interval (no pulse)
                -- 18    3       STIN    Head Step In
                -- 20    3       SPIN    Wait for motor spin-up
                -- 00    3       CAN     Cancel any command in progress
                -- 01            CLB     Clear the buffer pointers
                -- 
                -- Notes:    1. Add 1 for nonbuffered operation
                --           2. Add 4 for write precompensation
                --           3. Add 1 to clear buffer pointers
                --           4. Add 4 for DPLL recovery instead of FC recovery
                --           5. Add 6 for Alternate DPLL recovery
                f011_cmd <= fastio_wdata;
                f011_busy <= '0';
                f011_lost <= '0';
                f011_irq  <= '0';
                f011_rnf  <= '0';
                f011_crc  <= '0';
                f011_rsector_found <= '0';
                f011_wsector_found <= '0';
                if fastio_wdata(0) = '1' then
                  f011_buffer_next_read <= (others => '0');
                end if;
                temp_cmd := fastio_wdata(7 downto 3) & "000";
                case temp_cmd is
                  when x"40" =>         -- read sector
                    -- calculate sector number.
                    -- physical sector on disk = track * $14 + sector on track
                    -- then add to disk image start sector for the selected
                    -- drive.
                    -- put sector number into sd_sector, and then trigger read.
                    -- If no disk image is enabled, then report an error.
                    if diskimage_enable='0' or f011_disk_present='0' then
                      f011_rnf <= '1';
                    else
                      -- f011_buffer_address gets pre-incremented, so start
                      -- with it pointing to the end of the buffer first
                      f011_buffer_address <= (others => '1');
                      f011_sector_fetch <= '1';
                      f011_busy <= '1';
                      if sdhc_mode='1' then
                        sd_sector <= diskimage_sector + diskimage_offset;
                      else
                        sd_sector(31 downto 9) <= diskimage_sector(31 downto 9) +
                                                  diskimage_offset;     
                      end if;
                      sd_state <= ReadSector;
                      sdio_error <= '0';
                      sdio_fsm_error <= '0';
                    end if;
                    null;
                  when x"80" =>         -- write sector
                    null;
                  when x"10" =>         -- head step out, or no step
                    if fastio_wdata(2)='1' then
                      -- time, but don't step
                      null;
                    else
                      f011_head_track <= f011_head_track - 1;
                    end if;
                  when x"18" =>         -- head step in
                    f011_head_track <= f011_head_track + 1;
                  when x"20" =>         -- motor spin up
                    f011_motor <= '1';
                  when x"00" =>         -- cancel running command (not implemented)
                  when others =>        -- illegal command
                    null;
                end case;
              when "00100" => f011_track <= fastio_wdata;
              when "00101" => f011_sector <= fastio_wdata;
              when "00110" => f011_side <= fastio_wdata;
              when "00111" =>
                -- Data register -- should probably be putting byte into the sector
                -- buffer.
                f011_wdata <= fastio_wdata;
                f011_buffer_write <= '1';
                f011_buffer_next_read <= f011_buffer_next_read + 1;
                f011_drq <= '0';
              when others => null;           
            end case;
          elsif (fastio_addr(19 downto 4) = x"D168"
                 or fastio_addr(19 downto 4) = x"D368") then
            -- microSD controller registers
            case fastio_addr(3 downto 0) is
              when x"0" =>
                -- status / command register
                case fastio_wdata is
                  when x"00" =>
                    -- Reset SD card
                    sd_reset <= '1';
                    sd_state <= Idle;
                    sdio_error <= '0';
                    sdio_fsm_error <= '0';
                    sd_sector <= (others => '0');
                  when x"10" =>
                    -- Reset SD card with flags specified
                    sd_reset <= '1';
                    sd_state <= Idle;
                    sdio_error <= '0';
                    sdio_fsm_error <= '0';
                  when x"01" =>
                    -- End reset
                    sd_reset <= '0';
                    sd_state <= Idle;
                    sdio_error <= '0';
                    sdio_fsm_error <= '0';
                  when x"11" =>
                    -- End reset
                    sd_reset <= '0';
                    sd_state <= Idle;
                    sdio_error <= '0';
                    sdio_fsm_error <= '0';
                  when x"02" =>
                    -- Read sector
                    if sdio_busy='1' then
                      sdio_error <= '1';
                      sdio_fsm_error <= '1';
                    else
                      sd_state <= ReadSector;
                      sdio_error <= '0';
                      sdio_fsm_error <= '0';
                    end if;
                  when x"03" =>
                    -- Write sector
                    if sdio_busy='1' then
                      sdio_error <= '1';
                      sdio_fsm_error <= '1';
                    else                  
                      sd_state <= WriteSector;
                      sdio_error <= '0';
                      sdio_fsm_error <= '0';
                    end if;
                  when x"41" => sdhc_mode <= '1';
                  when x"42" => sdhc_mode <= '0';
                  when x"81" => sector_buffer_mapped<='1';
                                sdio_error <= '0';
                                sdio_fsm_error <= '0';
                  when x"82" => sector_buffer_mapped<='0';
                                sdio_error <= '0';
                                sdio_fsm_error <= '0';
                  when others =>
                    sdio_error <= '1';
                end case;
              when x"1" => sd_sector(7 downto 0) <= fastio_wdata;
              when x"2" => sd_sector(15 downto 8) <= fastio_wdata;
              when x"3" => sd_sector(23 downto 16) <= fastio_wdata;
              when x"4" => sd_sector(31 downto 24) <= fastio_wdata;
              when x"b" =>
                diskimage_enable <= fastio_wdata(0);
                f011_disk_present <= fastio_wdata(1);
                f011_write_protected <= not fastio_wdata(2);                
              when x"c" => diskimage_sector(7 downto 0) <= fastio_wdata;
              when x"d" => diskimage_sector(15 downto 8) <= fastio_wdata;
              when x"e" => diskimage_sector(23 downto 16) <= fastio_wdata;
              when x"f" => diskimage_sector(31 downto 24) <= fastio_wdata;
              when others => null;
            end case;
          end if;
        end if;
      end if;
      
      if fastio_read='1' and fastio_write='0' then
        if (fastio_addr(19 downto 5)&'0' = x"D108")
          or (fastio_addr(19 downto 5)&'0' = x"D308") then
          -- F011 FDC emulation registers
          case fastio_addr(4 downto 0) is
            when "00000" =>
              -- CONTROL |  IRQ  |  LED  | MOTOR | SWAP  | SIDE  |  DS2  |  DS1  |  DS0  | 0 RW
              --IRQ     When set, enables interrupts to occur,  when reset clears and
              --        disables interrupts.
              --LED     These  two  bits  control  the  state  of  the  MOTOR and LED
              --MOTOR   outputs. When both are clear, both MOTOR and LED outputs will
              --        be off. When MOTOR is set, both MOTOR and LED Outputs will be
              --        on. When LED is set, the LED will "blink".
              --SWAP    swaps upper and lower halves of the data buffer
              --        as seen by the CPU.
              --SIDE    when set, sets the SIDE output to 0, otherwise 1.
              --DS2-DS0 these three bits select a drive (drive 0 thru drive 7).  When
              --        DS0-DS2  are  low  and  the LOCAL input is true (low) the DR0
              --        output will go true (low).
              fastio_rdata <=
                f011_irqenable & f011_led & f011_motor & f011_swap &
                f011_side(0) & f011_ds;
            when "00001" =>
              -- COMMAND | WRITE | READ  | FREE  | STEP  |  DIR  | ALGO  |  ALT  | NOBUF | 1 RW
              --WRITE   must be set to perform write operations.
              --READ    must be set for all read operations.
              --FREE    allows free-format read or write vs formatted
              --STEP    write to 1 to cause a head stepping pulse.
              --DIR     sets head stepping direction
              --ALGO    selects read and write algorithm. 0=FC read, 1=DPLL read,
              --        0=normal write, 1=precompensated write.

              --ALT     selects alternate DPLL read recovery method. The ALG0 bit
              --        must be set for ALT to work.
              --NOBUF   clears the buffer read/write pointers
              fastio_rdata <= f011_cmd;
            when "00010" =>             -- READ $D082
              -- STAT A  | BUSY  |  DRQ  |  EQ   |  RNF  |  CRC  | LOST  | PROT  |  TKQ  | 2 R
              --BUSY    command is being executed
              --DRQ     disk interface has transferred a byte
              --EQ      buffer CPU/Disk pointers are equal
              --RNF     sector not found during formatted write or read
              --CRC     CRC check failed
              --LOST    data was lost during transfer
              --PROT    disk is write protected
              --TK0     head is positioned over track zero
              fastio_rdata <= f011_busy & f011_drq & f011_flag_eq & f011_rnf
                              & f011_crc & f011_lost & f011_write_protected
                              & f011_track0;
            when "00011" =>             -- READ $D083 
              -- STAT B  | RDREQ | WTREQ |  RUN  | NGATE | DSKIN | INDEX |  IRQ  | DSKCHG| 3 R
              -- RDREQ   sector found during formatted read
              -- WTREQ   sector found during formatted write
              -- RUN     indicates successive matches during find operation
              --         (that so far, the found sector matches the requested sector)
              -- WGATE   write gate is on
              -- DSKIN   indicates that a disk is inserted in the drive
              -- INDEX   disk index is currently over sensor
              -- IRQ     an interrupt has occurred
              -- DSKCHG  the DSKIN line has changed
              --         this is cleared by deselecting drive
              fastio_rdata <= f011_rsector_found & f011_wsector_found &
                              f011_rsector_found & f011_write_gate & f011_disk_present &
                              f011_over_index & f011_irq & f011_disk_changed;
            when "00100" =>
              -- TRACK   |  T7   |  T6   |  T5   |  T4   |  T3   |  T2   |  T1   |  T0   | 4 RW
              fastio_rdata <= f011_track;
            when "00101" =>
              -- SECTOR  |  S7   |  S6   |  S5   |  S4   |  S3   |  S2   |  S1   |  S0   | 5 RW
              fastio_rdata <= f011_sector;
            when "00110" =>
              -- SIDE    |  S7   |  S6   |  S5   |  S4   |  S3   |  S2   |  S1   |  S0   | 6 RW
              fastio_rdata <= f011_side;
            when "00111" =>
              -- DATA    |  D7   |  D6   |  D5   |  D4   |  D3   |  D2   |  D1   |  D0   | 7 RW
              fastio_rdata <= f011_rdata;
              f011_buffer_next_read <= f011_buffer_next_read + 1;
              f011_drq <= '0';
            when "01000" =>
              -- CLOCK   |  C7   |  C6   |  C5   |  C4   |  C3   |  C2   |  C1   |  C0   | 8 RW
              fastio_rdata <= (others => 'Z');
            when "01001" =>
              -- STEP    |  S7   |  S6   |  S5   |  S4   |  S3   |  S2   |  S1   |  S0   | 9 RW
              fastio_rdata <= (others => 'Z');
            when "01010" =>
              -- P CODE  |  P7   |  P6   |  P5   |  P4   |  P3   |  P2   |  P1   |  P0   | A R
              fastio_rdata <= (others => 'Z');
            when others =>
              fastio_rdata <= (others => 'Z');
          end case;
        elsif (fastio_addr(19 downto 8) = x"D16"
               or fastio_addr(19 downto 8) = x"D36") then
          -- microSD controller registers
          case fastio_addr(7 downto 0) is
            when x"80" =>
              -- status / command register
              -- error status in bit 6 so that V flag can be used for check      
              fastio_rdata(7) <= '0';
              fastio_rdata(6) <= sdio_error;
              fastio_rdata(5) <= sdio_fsm_error;
              fastio_rdata(4) <= sdhc_mode;
              fastio_rdata(3) <= sector_buffer_mapped;
              fastio_rdata(2) <= sd_reset;
              fastio_rdata(1) <= sdio_busy;
              fastio_rdata(0) <= sdio_busy;
            when x"81" => fastio_rdata <= sd_sector(7 downto 0);
            when x"82" => fastio_rdata <= sd_sector(15 downto 8);
            when x"83" => fastio_rdata <= sd_sector(23 downto 16);
            when x"84" => fastio_rdata <= sd_sector(31 downto 24);        
            when x"85" => fastio_rdata <= to_unsigned(sd_state_t'pos(sd_state),8);
            when x"86" => fastio_rdata <= sd_datatoken;
            when x"87" => fastio_rdata <= unsigned(sd_rdata);                        
            when x"88" => fastio_rdata <= sector_offset(7 downto 0);
            when x"89" =>
              fastio_rdata(7 downto 1) <= (others => '0');
              fastio_rdata(0) <= sector_offset(8);
              fastio_rdata(1) <= sector_offset(9);
            when x"8b" =>
              fastio_rdata(0) <= diskimage_enable;
              fastio_rdata(1) <= f011_disk_present;
              fastio_rdata(2) <= not f011_write_protected;
            when x"8c" => fastio_rdata <= diskimage_sector(7 downto 0);
            when x"8d" => fastio_rdata <= diskimage_sector(15 downto 8);
            when x"8e" => fastio_rdata <= diskimage_sector(23 downto 16);
            when x"8f" => fastio_rdata <= diskimage_sector(31 downto 24);
            when x"F0" => fastio_rdata(7 downto 0) <= unsigned(sw(7 downto 0));
            when x"F1" => fastio_rdata(7 downto 0) <= unsigned(sw(15 downto 8));
            when x"F2" =>
            fastio_rdata(7 downto 5) <= "000";
            fastio_rdata(4 downto 0) <= unsigned(btn(4 downto 0));
            when others => fastio_rdata <= (others => 'Z');
          end case;
        else
          -- Otherwise tristate output
          fastio_rdata <= (others => 'Z');
        end if;
      end if;
      
      sbweb(0) <= '0';
      case sd_state is
        when Idle => sdio_busy <= '0';
        when ReadSector =>
          -- Begin reading a sector into the buffer
          if sdio_busy='0' then
            sd_doread <= '1';
            sd_state <= ReadingSector;
            sdio_busy <= '1';
            skip <= 2;
            sector_offset <= (others => '1');
            read_bytes <= '0';
          else
            sd_doread <= '0';
          end if;
        when ReadingSector =>
          if data_ready='1' then
            sd_doread <= '0';
            -- A byte is ready to read, so store it
            -- sector_buffer(to_integer(sector_offset)) <= unsigned(sd_rdata);
            sbweb(0) <= '1';
            sd_state <= ReadingSectorAckByte;
            if skip=0 then
              sector_offset <= sector_offset + 1;
              read_bytes <= '1';
              if f011_sector_fetch='1' then
                f011_rsector_found <= '1';
                if f011_drq='1' then f011_lost <= '1'; end if;
                f011_drq <= '1';
                -- XXX update F011 sector buffer
                f011_buffer_address <= f011_buffer_address + 1;
                f011_fdc_buffer_write <= '1';
                f011_buffer_wdata <= unsigned(sd_rdata);
              end if;
            else
              skip <= skip - 1;
              if skip=2 then
                sd_datatoken <= unsigned(sd_rdata);
              end if;
            end if;
          end if;
        when ReadingSectorAckByte =>
          -- Wait until controller acknowledges that we have acked it
          if data_ready='0' then
            if (sector_offset = "0111111111") and (read_bytes='1') then
              -- sector offset has reached 511, so we must have
              -- read the whole sector.
              -- Advance sector offset to 512 for compatibility with existing code.
              sector_offset <= sector_offset + 1;
              -- Update F011 FDC emulation status registers
              f011_sector_fetch <= '0';
              f011_busy <= '0';
              sd_state <= DoneReadingSector;
            else
              -- Still more bytes to read.
              sd_state <= ReadingSector;
            end if;
          end if;
        when WriteSector =>
          -- Begin writing a sector into the buffer
          if sdio_busy='0' then
            sd_dowrite <= '1';
            sdio_busy <= '1';
            sd_state <= WritingSector;
            sector_offset <= (others => '0');
--            sd_wdata <= std_logic_vector(sector_buffer(0));
          else
            sd_dowrite <= '0';
          end if;
        when WritingSector =>
          if data_ready='1' then
            sd_dowrite <= '0';
            -- Byte has been accepted, write next one
--            sd_wdata <= std_logic_vector(sector_buffer(to_integer(sector_offset+1)));
            sd_state <= WritingSectorAckByte;
            sector_offset <= sector_offset + 1;
          end if;
        when WritingSectorAckByte =>
          -- Wait until controller acknowledges that we have acked it
          if data_ready='0' then
            if sector_offset = "1000000000" then
              -- sector offset has reached 512, so we have
              -- written the whole sector.
              sd_state <= DoneWritingSector;
            else
              -- Still more bytes to read.
              sd_state <= WritingSector;
            end if;
          end if;
        when DoneReadingSector =>
          sdio_busy <= '0';
          sd_state <= Idle;
        when DoneWritingSector =>
          sdio_busy <= '0';
          sd_state <= Idle;
      end case;    

    end if;
  end process;

end behavioural;
