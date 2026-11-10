# shellcheck shell=bash disable=SC2034
# GOMEMLIMIT equal to the memory limit (a config finding: pods are not recreated).
SC_DESC="GOMEMLIMIT = memory limit (1GiB) in the StatefulSet"
SC_KIND=config
SC_JQ='.env |= map(if .name == "GOMEMLIMIT" then .value = "1GiB" else . end)'
SC_EXPECT="GOMEMLIMIT_ABOVE_LIMIT"
