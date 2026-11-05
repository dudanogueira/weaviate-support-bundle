# lib/jq/metrics.jq: turn two Prometheus text snapshots into a short,
# readable summary of the metrics support actually looks at.
#
# Input: two arrays of parsed samples {name, labels, value} ($t0, $t1),
# produced by metrics.sh from the raw /metrics text.
#
# For each metric: number of series, total at t0 and t1, and the change per
# second. For *_sum/*_count pairs (latencies) the average over the interval
# is computed. Per-label detail is kept only when there are few series, so
# clusters with thousands of tenants stay readable.

# Lines "name<TAB>labels<TAB>value" (from metrics.sh) -> samples.
def parse_samples:
  [inputs | split("\t") | select(length == 3)
   | {name: .[0],
      labels: ([.[1] | match("([a-zA-Z_][a-zA-Z0-9_]*)=\"((?:[^\"\\\\]|\\\\.)*)\""; "g")
                | {(.captures[0].string): .captures[1].string}] | add // {}),
      value: (.[2] | try tonumber catch null)}
   | select(.value != null and (.value | isnan | not) and (.value | isinfinite | not))];

def total: map(.value) | add // 0;

def by_name($samples): $samples | group_by(.name) | map({key: .[0].name, value: .}) | from_entries;

def summarize($t0; $t1; $interval):
  by_name($t0) as $a
  | by_name($t1) as $b
  | ($b | keys) as $names
  | [ $names[] as $n
      | ($a[$n] // []) as $s0
      | ($b[$n] // []) as $s1
      | {name: $n,
         series: ($s1 | length),
         t0: ($s0 | total),
         t1: ($s1 | total)}
      | .delta_per_s = (if $interval > 0 then (((.t1 - .t0) / $interval) * 1000 | round / 1000) else null end)
      | if .series <= 20 then
          .detail = [$s1[] | {labels, value}]
        else . end ]
  | (map({key: .name, value: .}) | from_entries) as $m
  # Average latency over the interval for summary/histogram pairs.
  | [ $m | keys[] | select(endswith("_sum")) | sub("_sum$"; "") as $base
      | select($m[$base + "_count"] != null)
      | ($m[$base + "_sum"]) as $sum | ($m[$base + "_count"]) as $cnt
      | {key: $base, value: {
          requests_in_interval: ($cnt.t1 - $cnt.t0),
          avg_in_interval: (if ($cnt.t1 - $cnt.t0) > 0 then ((($sum.t1 - $sum.t0) / ($cnt.t1 - $cnt.t0)) * 100 | round / 100) else null end),
          avg_since_start: (if $cnt.t1 > 0 then (($sum.t1 / $cnt.t1) * 100 | round / 100) else null end)}} ]
  | from_entries as $lat
  | {interval_seconds: $interval, metrics: ($m | to_entries | map(.value) | sort_by(.name)), latency: $lat};
