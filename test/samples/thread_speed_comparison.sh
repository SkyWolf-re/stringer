TIMEFORMAT='%3lR real  %3lU user  %3lS sys'

echo -n "# $(uname -srmo)"
printf '\n'
echo -n "# cores: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo NA)"
printf '\n'
echo -n "# zig: $(zig version 2>/dev/null || echo NA)"
printf '\n'
cp 100mb.bin /dev/shm/100mb.bin
for t in 1 2; do
  echo -n "$t threads (text): "
  time ../../zig-out/bin/stringer --min-len 15 --enc ascii --threads "$t" /dev/shm/100mb.bin >/dev/null
done
for t in 1 2; do
  echo -n "$t threads (JSON): "
  time ../../zig-out/bin/stringer --json --min-len 15 --enc ascii --threads "$t" /dev/shm/100mb.bin >/dev/null
done
echo -n "    strings      :"
time strings -n 15 /dev/shm/100mb.bin >/dev/null

#echo "time w/o grep"
#time ../../zig-out/bin/stringer --enc ascii --threads 2 ~/gihub/stringer/zig-out/bin/stringer >/dev/null

#echo "time with grep"
#time ../../zig-out/bin/stringer --enc ascii --threads 2 ~/gihub/stringer/zig-out/bin/stringer | grep -F 'stringer' >/dev/null
