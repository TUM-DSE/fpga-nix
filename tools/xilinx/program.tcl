# Program one Xilinx device through a running hw_server.
# Usage: vivado -mode batch -source program.tcl
#          -tclargs <image> <part_hint> <hw_server_url> <jtag_target_hint>
# Exactly one device whose part contains <part_hint> must be found. An
# optional <jtag_target_hint> restricts the search to matching JTAG targets.

if {$argc < 4} {
  puts "Usage: -tclargs <image> <part_hint> <hw_server_url> <jtag_target_hint>"
  exit 1
}
set image [lindex $argv 0]
set needle [string tolower [lindex $argv 1]]
set hw_server_url [lindex $argv 2]
set target_needle [string tolower [lindex $argv 3]]

open_hw_manager
connect_hw_server -url $hw_server_url

set tgts [get_hw_targets]
if {[llength $tgts] == 0} {
  puts "No hw targets found"
  exit 3
}

set matches {}
set match_targets {}

foreach t $tgts {
  set target_lower [string tolower $t]
  if {$target_needle ne "" && [string first $target_needle $target_lower] < 0} {
    puts "Skipping target: $t (does not match FPGA_JTAG_TARGET=$target_needle)"
    continue
  }

  puts "Scanning target: $t"
  if {[catch {open_hw_target $t} open_msg] != 0} {
    puts "Skipping target $t: $open_msg"
    continue
  }

  foreach d [get_hw_devices] {
    set part [string tolower [get_property PART $d]]
    puts "Found device: $d  PART=$part  TARGET=$t"
    if {[string first $needle $part] >= 0} {
      lappend matches $d
      lappend match_targets $t
    }
  }

  catch {close_hw_target $t}
}

if {[llength $matches] != 1} {
  puts "Expected exactly one device matching '$needle', got [llength $matches]"
  if {$target_needle ne ""} {
    puts "Target filter: FPGA_JTAG_TARGET=$target_needle"
  }
  for {set i 0} {$i < [llength $matches]} {incr i} {
    puts "  match [expr {$i + 1}]: [lindex $matches $i] on [lindex $match_targets $i]"
  }
  exit 2
}

set dev [lindex $matches 0]
set tgt [lindex $match_targets 0]

if {[catch {open_hw_target $tgt} open_msg] != 0} {
  puts "Failed to reopen matching target $tgt: $open_msg"
  exit 4
}

current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $image $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "OK: programmed $dev with $image"

catch {close_hw_target $tgt}
disconnect_hw_server
close_hw_manager
exit 0
