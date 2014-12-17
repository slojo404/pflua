#!/usr/bin/env luajit

local file_prefix = "~/igalia/pflua-bench/savefiles/"

-- not supported: LLC-load-misses LLC-store-misses LLC-prefetch-misses
local miss_exps = {'cache-misses', 'branch-misses', 'L1-dcache-load-misses',
   'L1-icache-load-misses', 'dTLB-load-misses', 'iTLB-load-misses',
   'branch-load-misses' }
local files = {'one-gigabyte.pcap', 'ping-flood.pcap', 'wingolog.org.pcap'}

function perfnum_to_lua(perfnum)
   return tonumber((perfnum:gsub("'", "")))
end

-- Escape '-' so it's not taken to mean non-greedy matching
function pattern_escape(exp)
   return (exp:gsub('-', '%%-'))
end

function perfstat(miss_exp, pcapfile)
   local cmd = string.format('perf stat -e %s ./pflua-match %s%s "" 2>&1',
                             miss_exp, file_prefix, pcapfile)
   local results = io.popen(cmd):read("*all")
   local expected_miss = string.format("([0-9']+) %s", pattern_escape(miss_exp))
   local raw_misses = results:match(expected_miss)
   local miss_count = perfnum_to_lua(raw_misses)
   local checked_packets = perfnum_to_lua(results:match("/([0-9']+) packets"))
   local iterations = tonumber(results:match("(%d+) iterations"))
   local total_packets = checked_packets * iterations
   return miss_count, total_packets
end

function print_perf(miss_exp, file)
   local miss_count, total_packets = perfstat(miss_exp, file)
   local miss_per_packet = miss_count / total_packets
   print(string.format("\t%s misses per packet (%s misses, %s packets)",
                       miss_per_packet, miss_count, total_packets))
end

function run_perfs()
   for _,miss_exp in ipairs(miss_exps) do
      for _, file in ipairs(files) do
      print(string.format("%s: %s", file, miss_exp))
         for i=1,3 do -- get an idea of variance
            print_perf(miss_exp, file)
         end
      end
      print()
   end
end

run_perfs()
