create_clock -name "CLK" -period 20.000ns [get_ports {CLK}]
derive_pll_clocks
derive_clock_uncertainty