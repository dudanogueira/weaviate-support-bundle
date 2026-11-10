# shellcheck shell=bash disable=SC2034
# The cluster as installed: nothing broken.
SC_DESC="nothing broken (the base install)"
SC_KIND=custom
SC_NO_HIGH=1
SC_ABSENT="WEAVIATE_VERSION_MISMATCH"
sc_apply() { pg_all_ready || pg_say "warning: not all replicas are ready"; }
sc_revert() { :; }
