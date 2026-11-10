# shellcheck shell=bash disable=SC2034
# weaviate-2 asks for more CPU than any node has: it cannot be scheduled.
SC_DESC="weaviate-2 requests 1000 CPUs -> Pending"
SC_KIND=pod
SC_POD=weaviate-2
SC_JQ='.resources.requests.cpu = "1000"'
SC_EXPECT="POD_PENDING STATEFULSET_NOT_READY"
sc_wait() {
  # The pod's own state: an event could be left over from an earlier scenario.
  _pending() { [ "$(kn get pod weaviate-2 -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}' 2> /dev/null)" = False ]; }
  pg_wait 120 _pending
}
