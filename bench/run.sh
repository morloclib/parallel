#!/usr/bin/env bash
# Run the parallel benchmarks for one language.
#
#   usage: run.sh <py|cpp|rust> [reps]      (run from anywhere)
#
# Builds parallel-<lang>/bench.loc, calibrates the per-element cost so the
# sequential `spin` takes about 100 us per element in that language, runs every
# case, and appends rows to parallel/bench/results/<date>-<lang>.tsv:
#
#   case  variant  workers  rep  wall_s  stage_s  checksum
#
# `stage_s` is the in-pool time of the labelled call (empty when the call has
# no row, as for the stream stages); stream cases also record a `*-empty` run
# on an empty source so pool start-up can be subtracted from wall time.
#
# Every build and run goes through /work/scripts/memguard when it exists.

set -u

lang=${1:?usage: run.sh <py|cpp|rust> [reps]}
reps=${2:-3}
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$here/../../parallel-$lang" && pwd)
results="$here/results"
mkdir -p "$results"
tsv="$results/$(date +%F)-$lang.tsv"
workers_list=${PARALLEL_BENCH_WORKERS:-"1 2 4 8 12"}

guard() {
  if [ -x /work/scripts/memguard ]; then
    /work/scripts/memguard -m "${PARALLEL_BENCH_MEM:-8192}" -t "${PARALLEL_BENCH_TIMEOUT:-1200}" -- "$@"
  else
    "$@"
  fi
}

cd "$dir" || exit 1
echo "building $dir/bench" >&2
guard morloc make -o bench bench.loc > bench-build.log 2>&1 || { cat bench-build.log >&2; exit 1; }

[ -s "$tsv" ] || printf 'case\tvariant\tworkers\trep\twall_s\tstage_s\tchecksum\n' > "$tsv"

# Seconds since the epoch with microseconds. $EPOCHREALTIME would do, but it
# needs bash 5 and macOS ships 3.2, where it is empty and every time reads 0.
now_s() { python3 -c 'import time; print("%.6f" % time.time())'; }

# One timed run: prints "wall stage checksum".
run_once() {
  local start end
  start=$(now_s)
  guard ./bench "$@" > bench.out 2> bench.err
  local rc=$?
  end=$(now_s)
  if [ $rc -ne 0 ]; then
    echo "FAILED ($rc): ./bench $*" >&2
    tail -5 bench.err >&2
    return 1
  fi
  local stage
  stage=$(awk -F'\t' '$1 == "BENCH" { print $6; exit }' bench.err)
  printf '%s\t%s\t%s\n' "$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.4f", e - s }')" "$stage" "$(tail -1 bench.out)"
}

measure() {
  local case=$1 variant=$2 workers=$3
  shift 3
  local rep row
  for rep in $(seq 1 "$reps"); do
    row=$(run_once "$@") || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$case" "$variant" "$workers" "$rep" "$row" >> "$tsv"
  done
  echo "  $case $variant w=$workers" >&2
}

# Calibrate: iterations per element for ~100 us of sequential `spin`.
probe_n=500
probe_base=${PARALLEL_BENCH_PROBE:-20000}
[ "$lang" = py ] && probe_base=1000
stage=$(run_once seqMap 0 "$probe_n" "$probe_base" | cut -f2)
base=$(awk -v t="$stage" -v n="$probe_n" -v b="$probe_base" 'BEGIN { printf "%d", b * (n * 100e-6) / t }')
echo "calibrated base = $base iterations/element (probe $probe_n x $probe_base took ${stage}s)" >&2
printf 'calibration\tbase\t0\t0\t0\t%s\t%s\n' "$stage" "$base" >> "$tsv"

# B1 raw scaling: uniform 100 us elements.
n1=20000
measure scaling seq 1 seqMap 0 $n1 "$base"
for w in $workers_list; do measure scaling pmap "$w" parMap "$w" 1 0 0 $n1 "$base"; done

# B2 overhead: near-zero cost, many elements.
n2=1000000
measure overhead seq 1 seqMap 0 $n2 0
for w in $workers_list; do measure overhead pmap "$w" parMap "$w" 1 0 0 $n2 0; done

# B3 payload: large elements, cheap work.
n3=5000
bytes=10000
measure payload seq 1 seqPayload $n3 $bytes
for w in $workers_list; do measure payload pmap "$w" parPayload "$w" 1 $n3 $bytes; done

# B4 skew: shapes x chunking at 4 and 12 workers.
n4=10000
for shape in 1 2 3; do
  measure "skew$shape" seq 1 seqMap $shape $n4 "$base"
  for w in 4 12; do
    measure "skew$shape" even "$w" parMap "$w" 0 0 $shape $n4 "$base"
    measure "skew$shape" shrinking "$w" parMap "$w" 1 0 $shape $n4 "$base"
    measure "skew$shape" fixed16 "$w" parMap "$w" 2 16 $shape $n4 "$base"
    measure "skew$shape" fixed256 "$w" parMap "$w" 2 256 $shape $n4 "$base"
  done
done

# B5 filter and concatMap against map at equal cost.
n5=20000
measure filter seq 1 seqFilter 0 $n5 "$base"
measure concatmap seq 1 seqConcatMap 0 $n5 "$base"
for w in $workers_list; do
  measure filter pfilter "$w" parFilter "$w" 1 0 0 $n5 "$base"
  measure concatmap pconcatMap "$w" parConcatMap "$w" 1 0 0 $n5 "$base"
done

# B6 streams: 200 batches x 100 elements, and a cheap 200 x 1000 file. The
# baseline is the native stage with one worker, which runs inline.
if grep -q streamNative bench.loc; then
  src=bench-src.dat
  cheap=bench-cheap.dat
  empty=bench-empty.dat
  dst=bench-dst.dat
  guard ./bench streamMake $src 200 100 "$base" > /dev/null 2>&1
  guard ./bench streamMake $cheap 200 1000 0 > /dev/null 2>&1
  guard ./bench streamMake $empty 0 1 0 > /dev/null 2>&1

  for w in $workers_list; do
    measure stream native "$w" streamNative "$w" 1 0 0 0 $src $dst
    measure stream native-empty "$w" streamNative "$w" 1 0 0 0 $empty $dst
    measure stream pure "$w" streamPure "$w" 1 0 $src $dst
    measure stream pure-empty "$w" streamPure "$w" 1 0 $empty $dst
  done
  measure stream native-arrival 12 streamNative 12 1 0 1 0 $src $dst
  for inflight in 1 12 24 96; do
    measure stream "native-inflight$inflight" 12 streamNative 12 1 0 0 $inflight $src $dst
  done

  for w in 1 12; do
    measure streamcheap native "$w" streamNative "$w" 1 0 0 0 $cheap $dst
    measure streamcheap native-empty "$w" streamNative "$w" 1 0 0 0 $empty $dst
    measure streamcheap pure "$w" streamPure "$w" 1 0 $cheap $dst
    measure streamcheap pure-empty "$w" streamPure "$w" 1 0 $empty $dst
  done

  for w in 1 12; do
    measure streamfold native "$w" streamFoldNative "$w" 1 0 $src
    measure streamfold native-empty "$w" streamFoldNative "$w" 1 0 $empty
    measure streamfold pure "$w" streamFoldPure "$w" 1 0 $src
    measure streamfold pure-empty "$w" streamFoldPure "$w" 1 0 $empty
  done
  rm -f $src $cheap $empty $dst
fi

# B7 a mapped function in another language, when this directory has one.
if [ -f bench-cross.loc ]; then
  guard morloc make -o bench-cross bench-cross.loc > bench-cross-build.log 2>&1 || { cat bench-cross-build.log >&2; exit 1; }
  mv bench bench.main && mv bench-cross bench
  # `spin` comes from the other language here, so calibrate it separately.
  xprobe=1000
  [ "$lang" = py ] && xprobe=20000
  xstage=$(run_once seqMap 0 "$probe_n" "$xprobe" | cut -f2)
  xbase=$(awk -v t="$xstage" -v n="$probe_n" -v b="$xprobe" 'BEGIN { printf "%d", b * (n * 100e-6) / t }')
  printf 'calibration\tcross-base\t0\t0\t0\t%s\t%s\n' "$xstage" "$xbase" >> "$tsv"
  n7=2000
  measure cross seq 1 seqMap 0 $n7 "$xbase"
  for chunk in 1 64 1024; do
    measure cross "fixed$chunk" 12 parMap 12 2 $chunk 0 $n7 "$xbase"
  done
  measure cross shrinking 12 parMap 12 1 0 0 $n7 "$xbase"
  mv bench bench-cross && mv bench.main bench
fi

rm -f bench.out bench.err
echo "results: $tsv" >&2
