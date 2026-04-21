-- Minimal testbench for opencores fpu100 bugtracker #4/#5
-- https://opencores.org/projects/fpu100/issues/4
-- Multiply: 0xc1800300 * 0x00034000  (normal * subnormal -> subnormal)
-- Soft float expected: 0x80340138
-- Unpatched FPU100:    0x80068027

library ieee;
use ieee.std_logic_1164.all;

entity tb_bugtracker is
end tb_bugtracker;

architecture sim of tb_bugtracker is

  component fpu
    port (
      clk_i       : in  std_logic;
      opa_i       : in  std_logic_vector(31 downto 0);
      opb_i       : in  std_logic_vector(31 downto 0);
      fpu_op_i    : in  std_logic_vector(2 downto 0);
      rmode_i     : in  std_logic_vector(1 downto 0);
      output_o    : out std_logic_vector(31 downto 0);
      ine_o       : out std_logic;
      overflow_o  : out std_logic;
      underflow_o : out std_logic;
      div_zero_o  : out std_logic;
      inf_o       : out std_logic;
      zero_o      : out std_logic;
      qnan_o      : out std_logic;
      snan_o      : out std_logic;
      start_i     : in  std_logic;
      ready_o     : out std_logic
    );
  end component;

  signal clk_i    : std_logic := '0';
  signal opa_i    : std_logic_vector(31 downto 0) := (others => '0');
  signal opb_i    : std_logic_vector(31 downto 0) := (others => '0');
  signal fpu_op_i : std_logic_vector(2 downto 0)  := (others => '0');
  signal rmode_i  : std_logic_vector(1 downto 0)  := (others => '0');
  signal output_o : std_logic_vector(31 downto 0);
  signal start_i  : std_logic := '0';
  signal ready_o  : std_logic;
  signal ine_o, overflow_o, underflow_o, div_zero_o, inf_o, zero_o, qnan_o, snan_o : std_logic;

  constant CLK_PERIOD : time := 10 ns;

  constant EXPECTED : std_logic_vector(31 downto 0) := x"80340138";

  function slv_to_hex(slv : std_logic_vector(31 downto 0)) return string is
    variable result : string(1 to 8);
    variable nibble : std_logic_vector(3 downto 0);
    constant hex    : string(1 to 16) := "0123456789abcdef";
  begin
    for i in 0 to 7 loop
      nibble := slv(31 - i*4 downto 28 - i*4);
      case nibble is
        when "0000" => result(i+1) := hex(1);
        when "0001" => result(i+1) := hex(2);
        when "0010" => result(i+1) := hex(3);
        when "0011" => result(i+1) := hex(4);
        when "0100" => result(i+1) := hex(5);
        when "0101" => result(i+1) := hex(6);
        when "0110" => result(i+1) := hex(7);
        when "0111" => result(i+1) := hex(8);
        when "1000" => result(i+1) := hex(9);
        when "1001" => result(i+1) := hex(10);
        when "1010" => result(i+1) := hex(11);
        when "1011" => result(i+1) := hex(12);
        when "1100" => result(i+1) := hex(13);
        when "1101" => result(i+1) := hex(14);
        when "1110" => result(i+1) := hex(15);
        when "1111" => result(i+1) := hex(16);
        when others => result(i+1) := '?';
      end case;
    end loop;
    return result;
  end function;

begin

  dut : fpu port map (
    clk_i       => clk_i,
    opa_i       => opa_i,
    opb_i       => opb_i,
    fpu_op_i    => fpu_op_i,
    rmode_i     => rmode_i,
    output_o    => output_o,
    ine_o       => ine_o,
    overflow_o  => overflow_o,
    underflow_o => underflow_o,
    div_zero_o  => div_zero_o,
    inf_o       => inf_o,
    zero_o      => zero_o,
    qnan_o      => qnan_o,
    snan_o      => snan_o,
    start_i     => start_i,
    ready_o     => ready_o
  );

  clk_i <= not clk_i after CLK_PERIOD / 2;

  stim : process
    variable fail_count : integer := 0;

    procedure do_mul(constant a : in std_logic_vector(31 downto 0);
                     constant b : in std_logic_vector(31 downto 0);
                     constant expected : in std_logic_vector(31 downto 0);
                     constant name : in string) is
    begin
      wait for CLK_PERIOD;
      start_i  <= '1';
      opa_i    <= a;
      opb_i    <= b;
      fpu_op_i <= "010";
      rmode_i  <= "00";
      wait for CLK_PERIOD;
      start_i <= '0';
      wait until ready_o = '1';
      wait for 1 ns;  -- sample just after rising edge
      if output_o = expected then
        report "PASS " & name & ": 0x" & slv_to_hex(a) & " * 0x" & slv_to_hex(b) &
               " = 0x" & slv_to_hex(output_o);
      else
        report "FAIL " & name & ": 0x" & slv_to_hex(a) & " * 0x" & slv_to_hex(b) &
               " got=0x" & slv_to_hex(output_o) & " expected=0x" & slv_to_hex(expected)
               severity warning;
        fail_count := fail_count + 1;
      end if;
      wait for CLK_PERIOD * 3;  -- drain pipeline before next op
    end procedure;

  begin
    start_i <= '0';
    wait for CLK_PERIOD * 2;

    -- bugtracker #4/#5: (-16.000...) * subnormal = subnormal
    do_mul(x"c1800300", x"00034000", x"80340138", "#4/#5 denormal mul");

    -- Normal * normal: 2.0 * 3.0 = 6.0
    -- 2.0 = 0x40000000, 3.0 = 0x40400000, 6.0 = 0x40c00000
    do_mul(x"40000000", x"40400000", x"40c00000", "2.0 * 3.0");

    -- Normal * normal, negative: -1.5 * 2.0 = -3.0
    -- -1.5 = 0xbfc00000, 2.0 = 0x40000000, -3.0 = 0xc0400000
    do_mul(x"bfc00000", x"40000000", x"c0400000", "-1.5 * 2.0");

    -- Zero * anything = zero
    do_mul(x"00000000", x"40400000", x"00000000", "0 * 3.0");

    -- One * pi
    -- 1.0 = 0x3f800000, pi ~= 0x40490fdb
    do_mul(x"3f800000", x"40490fdb", x"40490fdb", "1.0 * pi");

    -- Small normal * small normal that produces denormal result
    -- 1e-20 ~= 0x1e3ce508, f32(1e-20 * 1e-20) = 0x000116c2
    do_mul(x"1e3ce508", x"1e3ce508", x"000116c2", "1e-20 * 1e-20 -> denormal");

    if fail_count = 0 then
      report "ALL PASS (" & integer'image(fail_count) & " failures)" severity note;
    else
      report "HAS FAIL (" & integer'image(fail_count) & " failures)" severity note;
    end if;

    assert false report "sim done" severity failure;
  end process;

end sim;
