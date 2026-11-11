# Write the worst slack per analysis, clock and operating condition of a
# compiled Quartus project, one "<analysis> <condition> <clock> <slack>" line
# each. Run with: quartus_sta -t timing-slack.tcl <project> <revision> <out>

if {[llength $quartus(args)] != 3} {
  post_message -type error "usage: timing-slack.tcl <project> <revision> <output>"
  qexit -error
}
lassign $quartus(args) project revision output

project_open $project -revision $revision
create_timing_netlist
read_sdc
update_timing_netlist

set out [open $output w]
foreach condition [get_available_operating_conditions] {
  set_operating_conditions $condition
  update_timing_netlist
  foreach analysis {setup hold recovery removal} {
    foreach domain [get_clock_domain_info -$analysis] {
      # Each domain is {clock slack keeper-tns edge-tns}.
      lassign $domain clock slack
      puts $out [list $analysis $condition $clock $slack]
    }
  }
}
close $out

delete_timing_netlist
project_close
