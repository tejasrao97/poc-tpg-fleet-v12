#!/usr/bin/env bash
# Fixture, not part of the fleet: check_zero_defaults.py must find exactly the
# two lines marked FIND and none of the others.
sa_json='{}'
https_only="$(jq -r '.enableHttpsTrafficOnly // true' <<<"$sa_json")"        # FIND
replicas="$(yq '.spec.replicas // 1' spec.yaml)"                            # FIND
safe1="$(jq -r '.enabled // false' <<<"$sa_json")"
safe2="$(jq -r '.count // 0' <<<"$sa_json")"
safe3="$(jq -r 'if .enableHttpsTrafficOnly == null then true else .enableHttpsTrafficOnly end' <<<"$sa_json")"
safe4="$(jq -r '.name // "1"' <<<"$sa_json")"
url="https://true.example.com"
echo "$https_only $replicas $safe1 $safe2 $safe3 $safe4 $url"
