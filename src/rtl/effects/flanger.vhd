-- ===================================================================================================================================
-- @ Author: Krzysztof Pierczyk
-- @ Create Time: 2021-05-25 14:42:57
-- @ Modified time: 2021-05-25 14:42:59
-- @ Description: 
--    
--    Module of the IIR-filter-based flanger guitar effect with adjustable depth, strnegth and vibration's frequency.
--    
-- @ Note: This module uses two preconfigured BRAM blocks that have to be named `FlangerEffectBram` and `FlangerEffectGeneratorBram`.
--     For this reason it can be spwawned only once in the project.
-- ===================================================================================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.edge.all;
use work.generator.all;

-- ------------------------------------------------------------- Entity --------------------------------------------------------------

entity FlangerEffect is
    generic(
        -- Width of the input sample
        SAMPLE_WIDTH : Positive range 2 to Positive'High;

        -- ====================== Effect-specific parameters ==================== --

        -- -------------------------------------------------------------------------
        -- Strength level of the delayed summand is treated as value in range
        -- <0, 1), so width of his input impacts only granularity of the setup.
        -- 12-bit (1/4096 precision) should be enough to provide smooth control
        -- over the delayed samples' level.
        -- -------------------------------------------------------------------------

        -- Width of the @in attenuation_in port
        STRENGTH_WIDTH : Positive := 12;

        -- -------------------------------------------------------------------------
        -- As described below (@see 'Generator's BRAM parameters'), the internal
        -- LFO (Low Frequency Oscilator) generates numbers in range <0, 1024>. The
        -- `depth_in` input always scales this amplitude in range <0, 1) so it's
        -- width impacts only granularity of the setup. 10-bit width corresponding
        -- tot width of the LFO's samples is the highest reasonable setup that
        -- can be set in such configuration.
        -- -------------------------------------------------------------------------

        -- Width of the @in depth port
        DEPTH_WIDTH : Positive := 10;

        -- -------------------------------------------------------------------------
        -- @improtant: For the flanger effect to function properly it is crucial
        --    to relatively small frequencies of the LFO generator so that 
        --    osilcations in the delay's values doe not create too much distrotions
        --    in the input signal. Assuming 100MHz system clock and 1024 samples
        --    per LFO's period, the 20-bit input will quarante frequencies in range
        --    ~ <0.1, 97k> Hz. In fact the higher frequenies (in practice above 4Hz)
        --    should not be used but it is user's duty to properly scale 
        --    `ticks_per_delay_sample_in` input.
        -- 
        -- @note: f_LFO[t] = f_SYS / A_LFO / (ticks[t] + 1), where
        --
        --     - f_LFO[t] - frequency of the LFO in [Hz]
        --     - f_SYS - system clock's frequency in [Hz]
        --     - A_LFO - amplitude of the LFO generator
        --     - ticks[t] - value on the `ticks_per_delay_sample_in` input
        --
        -- -------------------------------------------------------------------------

        -- Width of the `ticks_per_delay_sample_in` input
        TICKS_PER_DELAY_SAMPLE_WIDTH : Positive := 20;

        -- ===================== Delay line's BRAM parameters =================== --

        -- ---------------------------------------------------------------------- --
        -- The first of incorporated BRAM blocks is used within the delay line 
        -- buffering historical sample in a FIFO maner (as a ring buffer). For
        -- 'flanger' effects delays in range of 10-25 ms are recommended to keep
        -- signals distrortions on reasonable level. Assuming 44100Hz sampling
        -- rate buffer should be able to hold about 662 samples (15 ms delay). 
        -- With 16-bit samples 1324-byte buffer is needed. A single 18Kb block RAM
        -- module can hold up to 1024 samples (yes, it's less than 18Kbits). To 
        -- effectively utilize a block, the full sapce is used. Should delay's 
        -- amplitude turn out too high, it can  always be limited by constraints 
        -- put on the `depth_in` input's values.
        -- ---------------------------------------------------------------------- --

        -- Number of usable cells in delay line's BRAM
        DELAY_BRAM_SAMPLES_NUM : Positive := 1024;
        -- Width of the delay line's address port
        DELAY_BRAM_ADDR_WIDTH : Positive := 10;

        -- ---------------------------------------------------------------------- --
        -- To isolate latencies of the BRAM Core's internal multiplexers a single
        -- output register stage was used. It extends BRAM latency to 2 cycles.
        -- ---------------------------------------------------------------------- --

        -- Latency of the delay line's BRAM read operation (1 for lack of output registers in the BRAM block)
        DELAY_BRAM_LATENCY : Positive := 2;

        -- ====================== Generator's BRAM parameters =================== --

        -- ---------------------------------------------------------------------- --
        -- Granularity of the delay-modulating wave's samples should be able to 
        -- address (more or less) all delayed samples in the delay line. Taking
        -- into account above-mentioned size of the delay buffer, the 10-bit
        -- wave was choosen. With such granularity all samples can be addressed. 
        -- That translates to about 23ms of delay.
        --
        -- As quadruplet generator is used internally (@see QuadrupletGenerator)
        -- it is enough to hold first 257 samples of the sinusoid wave from range
        -- <0, 2pi>.
        -- ---------------------------------------------------------------------- --

        -- Number of usable cells in delay line's BRAM
        GENERATOR_BRAM_SAMPLES_NUM : Positive := 257;
        -- Width of the delay line's address port
        GENERATOR_BRAM_ADDR_WIDTH : Positive := 9;
        -- Width of the data hold in the generator's BRAM
        GENERATOR_BRAM_DATA_WIDTH : Positive := 10;

        -- ---------------------------------------------------------------------- --
        -- To isolate latencies of the BRAM Core's internal multiplexers a single
        -- output register stage was used. It extends BRAM latency to 2 cycles.
        -- ---------------------------------------------------------------------- --

        -- Latency of the delay line's BRAM read operation (1 for lack of output registers in the BRAM block)
        GENERATOR_BRAM_LATENCY : Positive := 2     
    );
    port(
        -- ====================== Effects' common interface ===================== --

        -- Reset signal (asynchronous)
        reset_n : in Std_logic;
        -- System clock
        clk : in Std_logic;

        -- Enable signal (when module's disabled, samples are not modified) (active high)
        enable_in : in Std_logic;
        -- `New input sample` signal
        valid_in : in Std_logic;
        -- `Output sample ready` signal
        valid_out : out Std_logic;

        -- Input sample
        sample_in : in Signed(SAMPLE_WIDTH - 1 downto 0);
        -- Gained sample
        sample_out : out Signed(SAMPLE_WIDTH - 1 downto 0);

        -- ===================== Effect's-specific interface ==================== --

        -- ---------------------------------------------------------------------- --
        -- `Depth` parameter determines actual amplitude of the delay wave 
        --  produced by the internal generator. The formula used is:
        --  D(t) = g(t) * d(t) / 2**DIV, where:
        -- 
        --     - D(t) : current delay passed to the delay line understood as
        --              delay (in number of input samples) of the sample summed
        --              with the incoming input
        --     - g(t) : signal generated by the internal egenrator. It's values
        --              depend on the content of `FlangerEffectGeneratorBram` 
        --              block and usually ranges over the whole accessible range
        --              to provide high precision
        --     - d(t) : velu of the `depth_in` input
        --     - DIV  : value of the `DEPTH_TWO_POW_DIV` generic set at the
        --              compilation time
        -- ---------------------------------------------------------------------- --

        -- Depth level
        depth_in : in unsigned(DEPTH_WIDTH - 1 downto 0);

        -- ---------------------------------------------------------------------- --
        -- Strength input defines attenuation values for delayed and non-delayed
        -- lines before being summed up. In fact it determines value K2 of the
        -- delayed line's attenuation and is interpreted as value in range <0, 1).
        -- Non-delayed line's attenuation K1 is calculated as (1 - K2) and so
        -- this input determines both of them.
        -- ---------------------------------------------------------------------- --

        -- Strength of the flanger effect
        strength_in : in unsigned(STRENGTH_WIDTH - 1 downto 0);

        -- ---------------------------------------------------------------------- --
        -- `ticks_per_delay_sample_in` input determines number of system clock's
        -- cycles falling on the single sample of the internally generated delay
        -- waveform (g(t) in above-mentioned analysis) and allows to controll
        -- it's effective frequency.
        -- ---------------------------------------------------------------------- --

        -- Delay's modulation frequency
        ticks_per_delay_sample_in : in Unsigned(TICKS_PER_DELAY_SAMPLE_WIDTH - 1 downto 0)

    );
end entity FlangerEffect;

-- ---------------------------------------------------------- Architecture -----------------------------------------------------------

architecture logic of FlangerEffect is

    -- =========================== Constants ============================ --

    -- Width of the `delay` input of the internal delay line (delay magnitude)
    constant DELAY_WIDTH : Positive := GENERATOR_BRAM_DATA_WIDTH;

    -- ======================= Input-derivations ======================== --

    -- Signal activated hight for one cycle when rising edge detected on @p in valid_in
    signal new_sample : Std_logic;

    -- ========================= Input buffers ========================== --

    -- Input sample buffer
    signal sample_in_buf : Signed(SAMPLE_WIDTH - 1 downto 0);

    -- Buffer for effect's strength input
    signal strength_buf : unsigned(STRENGTH_WIDTH - 1 downto 0);
    -- Buffer for depth input
    signal depth_buf : unsigned(DEPTH_WIDTH - 1 downto 0);

    -- ==================== Internal lines/buffers ====================== --

    -- Internal result of internal samples' summation
    signal sum : Signed(SAMPLE_WIDTH - 1 downto 0);

    -- Internal result of the input sample's attenuation
    signal input_summant : Signed(SAMPLE_WIDTH - 1 downto 0);
    -- Internal result of delayed sample's attenuation
    signal delayed_summant : Signed(SAMPLE_WIDTH - 1 downto 0);

    -- Current delay based on the `depth_in` and generator's value
    signal current_delay : Unsigned(DELAY_WIDTH - 1 downto 0);


    -- =============== Internal delay line's interface ================== --

    -- Delay line's manual reset signal
    signal delay_manual_reset_n : Std_logic;
    -- Delayline's reset signal (<= `reset_n` and `delay_manual_reset_n`)
    signal delay_reset_n : Std_logic;

    -- Enable line; when high the module starts processing samples on the input
    signal delay_enable_in : Std_logic;
    -- Busy line (active high)
    signal delay_busy_out : Std_logic;

    -- Delay level
    signal delay_delay_in : Unsigned(DELAY_WIDTH - 1 downto 0);
    
    -- Data lines
    signal delay_data_in : Std_logic_vector(SAMPLE_WIDTH - 1 downto 0);
    signal delay_data_out : Std_logic_vector(SAMPLE_WIDTH - 1 downto 0);

    -- ==================== Delay line's BRAM's signals ================= --

    -- BRAM declaration
    component FlangerEffectBram
    port (
        clka : in Std_logic;
        rsta : in Std_logic;
        ena : in Std_logic;
        wea : in Std_logic_vector(0 downto 0);
        addra : in Std_logic_vector(DELAY_BRAM_ADDR_WIDTH - 1 downto 0);
        dina : in Std_logic_vector(SAMPLE_WIDTH - 1 downto 0);
        douta : out Std_logic_vector(SAMPLE_WIDTH - 1 downto 0)
    );
    end component;

    -- BRAM's reset signal
    signal delay_bram_reset : Std_logic;
    -- Address lines
    signal delay_bram_addr_in : Std_logic_vector(DELAY_BRAM_ADDR_WIDTH - 1 downto 0);
    -- Data lines
    signal delay_bram_data_out, delay_bram_data_in : Std_logic_vector(SAMPLE_WIDTH - 1 downto 0);
    -- Enable/write enable lines
    signal delay_bram_en_in : Std_logic;
    signal delay_bram_wen_in : std_logic_vector(0 downto 0);

    -- ======================= Generator's interface =================== --

    -- `Enable` input f the generator starting generation of the next wave's sample
    signal generator_en_in : Std_logic;
    -- Output data from the wave generator
    signal generator_sample_out : Std_logic_vector(GENERATOR_BRAM_DATA_WIDTH - 1 downto 0);


    -- ==================== Generator's BRAM's signals ================= --

    -- BRAM declaration
    component FlangerEffectGeneratorBram
    port (
        clka : in Std_logic;
        rsta : in Std_logic;
        ena : in Std_logic;
        wea : in Std_logic_vector(0 downto 0);
        addra : in Std_logic_vector(GENERATOR_BRAM_ADDR_WIDTH - 1 downto 0);
        dina : in Std_logic_vector(GENERATOR_BRAM_DATA_WIDTH - 1 downto 0);
        douta : out Std_logic_vector(GENERATOR_BRAM_DATA_WIDTH - 1 downto 0)
    );
    end component;

    -- BRAM's reset signal
    signal generator_bram_reset : Std_logic;
    -- Address lines
    signal generator_bram_addr_in : Std_logic_vector(GENERATOR_BRAM_ADDR_WIDTH - 1 downto 0);
    -- Data lines
    signal generator_bram_data_out : Std_logic_vector(GENERATOR_BRAM_DATA_WIDTH - 1 downto 0);
    -- Enable/write enable lines
    signal generator_bram_en_in : Std_logic;
    signal generator_bram_wen_in : std_logic_vector(0 downto 0);    

    -- ======================= Auxiliary mechanisms ==================== --

    -- Function calculating completion of the unsigned number
    function complete(vec : Unsigned) return Unsigned is
        variable ret : Unsigned(vec'range);
    begin
        for i in vec'range loop
            ret(i) := not(vec(i));
        end loop;
        return ret;
    end function;

begin

    -- Assert that delay level's width is not bigger than BRAM's adress port
    assert (DELAY_WIDTH <= DELAY_BRAM_ADDR_WIDTH)
        report 
            "[FlangerEffect] Result of the multiplication of depth input and internally generated wave" &
            "cannot be wider than delay line's BRAM address port! (" & 
            "DEPTH_WIDTH + GENERATOR_BRAM_DATA_WIDTH - DEPTH_TWO_POW_DIV: " & Positive'Image(DELAY_WIDTH) & ", " &
            "BRAM_ADDR_WIDTH: " & Positive'Image(DELAY_BRAM_ADDR_WIDTH) & ")" &
            "Please modify parameters."
    severity error;

    -- =================================================================================
    -- Internal components and connections
    -- =================================================================================

    -- ============================= Input edge detector ============================ --

    -- `valid_in` edge detector
    edgeDetectotInstance : entity work.EdgeDetectorSync(logic)
    generic map(
        OUTPUT_ACTIVE => '1',
        EDGE_DETECTED => RISING
    )
    port map(
        reset_n   => reset_n,
        clk       => clk,
        sig       => valid_in,
        detection => new_sample
    );

    -- ================================= Delay line ================================= --

    -- Delay line can be also reset manually
    delay_reset_n <= reset_n and delay_manual_reset_n;

    -- Delay magnitude seen by the delay line is 1 less than the currently calculated delay
    delay_delay_in <= current_delay - 1 when current_delay > to_unsigned(0, DELAY_WIDTH) else to_unsigned(0, DELAY_WIDTH);

    -- Output of the output sample buffer is connected to the delay line's input
    delay_data_in <= Std_logic_vector(sample_in_buf);

    -- Internal delay line
    delayLineInstance: entity work.DelayLine(logic)
    generic map (
        DATA_WIDTH       => SAMPLE_WIDTH,
        DELAY_WIDTH      => DELAY_WIDTH,
        SOFT_START       => TRUE,
        BRAM_SAMPLES_NUM => DELAY_BRAM_SAMPLES_NUM,
        BRAM_ADDR_WIDTH  => DELAY_BRAM_ADDR_WIDTH,
        BRAM_LATENCY     => DELAY_BRAM_LATENCY
    )
    port map (
        reset_n       => delay_reset_n,
        clk           => clk,
        enable_in     => delay_enable_in,
        busy_out      => delay_busy_out,
        delay_in      => delay_delay_in,
        data_in       => delay_data_in,
        data_out      => delay_data_out,
        bram_addr_out => delay_bram_addr_in,
        bram_data_in  => delay_bram_data_out,
        bram_data_out => delay_bram_data_in,
        bram_en_out   => delay_bram_en_in,
        bram_wen_out  => delay_bram_wen_in
    );

    -- ============================== Delay line's BRAM ============================= --

    -- BRAM is reset with high signal
    delay_bram_reset <= not(reset_n);

    -- Internal BRAM block
    flangerEffectBramInstance: FlangerEffectBram
    port map (
        clka  => clk,
        rsta  => delay_bram_reset,
        ena   => delay_bram_en_in,
        wea   => delay_bram_wen_in,
        addra => delay_bram_addr_in,
        dina  => delay_bram_data_in,
        douta => delay_bram_data_out
    );

    -- ================================== Genertor ================================== --

    -- @ Note: Genertor's `busy` output can left open as it's overall delay can be
    --     deduced from the corresponding BRAM's latency

    -- Generator's instance
    quadrupletGeneratorInstance : entity work.QuadrupletGenerator
    generic map (
        MODE         => UNSIGNED_OUT,
        SAMPLES_NUM  => GENERATOR_BRAM_SAMPLES_NUM,
        SAMPLE_WIDTH => GENERATOR_BRAM_DATA_WIDTH,
        ADDR_WIDTH   => GENERATOR_BRAM_ADDR_WIDTH,
        BRAM_LATENCY => GENERATOR_BRAM_LATENCY
    )
    port map (
        reset_n       => reset_n,
        clk           => clk,
        en_in         => generator_en_in,
        sample_out    => generator_sample_out,
        busy_out      => open,
        bram_addr_out => generator_bram_addr_in,
        bram_data_in  => generator_bram_data_out,
        bram_en_out   => generator_bram_en_in
    );

    -- =============================== Genertor's BRAM ============================= --

    -- BRAM is reset with high signal
    generator_bram_reset <= not(reset_n);

    -- Internal BRAM block
    flangerEffectGeneratorBramInstance: FlangerEffectGeneratorBram
    port map (
        clka  => clk,
        rsta  => generator_bram_reset,
        ena   => generator_bram_en_in,
        wea   => generator_bram_wen_in,
        addra => generator_bram_addr_in,
        dina  => (others => '0'),
        douta => generator_bram_data_out
    );

    -- ====================== Asynchronous sample's attenuation ===================== --

    -- Attenuated version of the input sample
    input_summant <= resize(
        Signed(resize(complete(strength_buf), STRENGTH_WIDTH + 1)) * Signed(sample_in_buf) / 2**STRENGTH_WIDTH,
    SAMPLE_WIDTH);

    -- Attenuated version of the delayed sample
    delayed_summant <= resize(
        Signed(resize(strength_buf, STRENGTH_WIDTH + 1)) * Signed(delay_data_out) / 2**STRENGTH_WIDTH,
    SAMPLE_WIDTH);

    -- ============================= Samples' summation ============================= --

    -- Internal summation of samples with saturation
    sumSignedSatInstance : entity work.sumSignedSat
    port map (
        a_in       => input_summant,
        b_in       => delayed_summant,
        result_out => sum,
        err_out    => open
    );

    -- ============================== Other connections ============================= --

    -- Asynchronously calculated actual delay
    current_delay <= resize(
        Unsigned(generator_sample_out) * depth_buf / 2**DEPTH_WIDTH,
    DELAY_WIDTH);

    -- =================================================================================
    -- Module's logic
    -- =================================================================================

    process(reset_n, clk) is

        -- Module's state
        type Stage is (IDLE_ST, DELAY_ST);
        variable state : Stage;

        -- Auxiliary variable used to test falling edge of the delay line's `busy` signal
        variable delay_busy_prev : Std_logic;

    begin

        -- Reset condition
        if(reset_n = '0') then

            -- Reset outputs
            valid_out <= '0';
            -- Reset internal buffers
            sample_in_buf <= (others => '0');
            sample_out <= (others => '0');
            strength_buf <= (others => '0');
            depth_buf <= (others => '0');
            delay_manual_reset_n <= '1';
            delay_busy_prev := '0';
            -- Keep delay line's `enable` signal inactive
            delay_enable_in <= '0';
            -- Reset module's state
            state := IDLE_ST;

        -- Normal operation
        elsif(rising_edge(clk)) then

            -- Keep `valid_out` low by default
            valid_out <= '0';
            -- Keep delay line active by default
            delay_manual_reset_n <= '1';               
            -- Keep delay line's `enable` signal inactive by default
            delay_enable_in <= '0';

            -- If module is enabled
            if(enable_in = '1') then

                -- State machine
                case state is

                    -- Idle state
                    when IDLE_ST =>

                        -- Check whether new sample arrived
                        if(new_sample = '1') then

                            -- Push input data to internal buffers
                            sample_in_buf <= sample_in;
                            strength_buf <= strength_in;
                            depth_buf <= depth_in;
                            -- Enable delay line to buffer previous output sample and get a new delayed sample
                            delay_enable_in <= '1';
                            -- Reset internal buffer used to test falling edge of the delay line's `busy` signal
                            delay_busy_prev := '0';
                            -- Go to the next state
                            state := DELAY_ST;

                        end if;

                    -- Waiting for end of delay line's processing
                    when DELAY_ST =>

                        -- Wait for rising edge on the delay line's `busy` output
                        if(delay_busy_prev = '1' and delay_busy_out = '0') then

                            -- If actual `delay` is zero
                            if(current_delay = to_unsigned(0, DEPTH_WIDTH)) then
                                -- Push not-modified input sample to the output
                                sample_out <= sample_in_buf;
                            -- If non-zero depth was requested
                            else
                                -- Push sum of the input sample snd delayed sample to the output
                                sample_out <= sum;
                            end if;

                            -- Inform that the new sample arrived on the output
                            valid_out <= '1';
                            -- Back to the IDLE state
                            state := IDLE_ST;

                        -- Else keep waiting for the end of delay line's processing
                        else
                            delay_busy_prev := delay_busy_out;
                        end if;

                end case;

            -- If module is disabled
            else

                -- Reset delay line
                delay_manual_reset_n <= '0';

                -- Check whether a new sample arrived or module was disabled during processing the old one
                if(new_sample = '1' or state /= IDLE_ST) then

                    -- Output unprocessed input sample
                    if(state /= IDLE_ST) then
                        sample_out <= sample_in_buf;
                    else
                        sample_out <= sample_in;
                    end if;

                    -- Signal new sample on the output
                    valid_out <= '1';
                    -- Reset state
                    state := IDLE_ST;                    

                end if;

                -- Reset module's state
                state := IDLE_ST;            

            end if;

        end if;

    end process;

    -- =================================================================================
    -- Internal generator's logic
    -- =================================================================================

    process(reset_n, clk) is

        -- Generator's latency
        constant GENERATOR_LATENCY : Positive := GENERATOR_BRAM_LATENCY + 1; 
        -- Counter of input samples since last wave sample's update
        variable ticks_since_last_modulation_sample : Unsigned(TICKS_PER_DELAY_SAMPLE_WIDTH - 1 downto 0);
        -- Multiplexer choosing apropriate value of ticks per modulation's sample
        variable ticks_per_modulation_sample_actual : 
            Unsigned(maximum(TICKS_PER_DELAY_SAMPLE_WIDTH, 3) - 1 downto 0);

    begin

        -- Reset condition
        if(reset_n = '0') then

            -- Keep generator disabled
            generator_en_in <= '0';
            -- Reset internal counter
            ticks_since_last_modulation_sample := to_unsigned(0, TICKS_PER_DELAY_SAMPLE_WIDTH);

        -- Regular generation
        elsif(rising_edge(clk)) then

            -- Generate modulation samples only when module is enabled
            if(enable_in = '1') then

                -- If too high modulation frequency is used, select valid frequency
                ticks_per_modulation_sample_actual := 
                    ticks_per_delay_sample_in when 
                        ticks_per_delay_sample_in > to_unsigned(GENERATOR_LATENCY, ticks_per_modulation_sample_actual'length) 
                    else to_unsigned(GENERATOR_LATENCY, ticks_per_modulation_sample_actual'length);

                -- Check whether next sample is to be generated
                if(ticks_since_last_modulation_sample < ticks_per_modulation_sample_actual) then
                    generator_en_in <= '0';
                    ticks_since_last_modulation_sample := ticks_since_last_modulation_sample + 1;
                else
                    generator_en_in <= '1';
                    ticks_since_last_modulation_sample := to_unsigned(0, TICKS_PER_DELAY_SAMPLE_WIDTH);
                end if;

            -- Else, reset internal counter
            else 
                ticks_since_last_modulation_sample := to_unsigned(0, TICKS_PER_DELAY_SAMPLE_WIDTH);
                ticks_per_modulation_sample_actual := to_unsigned(GENERATOR_LATENCY, ticks_per_modulation_sample_actual'length);
            end if;

        end if;

    end process;

end architecture logic;