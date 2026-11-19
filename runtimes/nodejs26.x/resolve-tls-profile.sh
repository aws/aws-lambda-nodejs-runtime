#!/bin/bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Resolves AWS_LAMBDA_TLS_PROFILE through profiles.map and applies it with
# OPENSSL_CONF and NODE_OPTIONS. Unset keeps node's defaults, any other value
# that does not resolve fails init. Sourced by bootstrap before exec.

_tls_profile_dir="/var/runtime/tls-profiles"
_tls_profile_map="${_tls_profile_dir}/profiles.map"

_log_and_fail() {
  echo "[tls-profile] FATAL: $1" >&2
  exit 1
}

resolve_tls_profile() {
  unset _AWS_LAMBDA_RESOLVED_TLS_PROFILE
  if [ -z "${AWS_LAMBDA_TLS_PROFILE+set}" ]; then
    return 0
  fi
  local requested="$AWS_LAMBDA_TLS_PROFILE"

  if [ ! -f "$_tls_profile_map" ]; then
    _log_and_fail "profile map not found at ${_tls_profile_map}"
  fi

  local config_base="" name target _rest
  while read -r name target _rest || [ -n "$name" ]; do
    case "$name" in
      ''|'#'*) continue ;;
    esac
    if [ "$name" = "$requested" ]; then
      config_base="$target"
      break
    fi
  done < "$_tls_profile_map"

  if [ -z "$config_base" ]; then
    _log_and_fail "unknown or misconfigured TLS profile '${requested}'"
  fi

  local config_file="${_tls_profile_dir}/${config_base}.conf"
  if [ ! -f "$config_file" ]; then
    _log_and_fail "profile '${requested}' resolved to '${config_base}' but ${config_file} is missing"
  fi

  if [ -n "${OPENSSL_CONF-}" ]; then
    echo "[tls-profile] '${requested}' resolved to ${config_file} but customer OPENSSL_CONF is set, keeping customer value" >&2
    return 0
  fi

  # Node accepts _ for - in option names and strips quotes from NODE_OPTIONS.
  local node_options="${NODE_OPTIONS-}" token tokens
  read -ra tokens <<< "${node_options//_/-}"
  for token in "${tokens[@]}"; do
    token="${token//[\"\\]/}"
    case "$token" in
      --openssl-config|--openssl-config=*)
        echo "[tls-profile] '${requested}' resolved to ${config_file} but customer --openssl-config is set in NODE_OPTIONS, keeping customer value" >&2
        return 0
        ;;
      --tls-cipher-list|--tls-cipher-list=*|--tls-min-v1*|--tls-max-v1*)
        echo "[tls-profile] '${requested}' resolved to ${config_file} but customer TLS flags are set in NODE_OPTIONS, keeping customer settings" >&2
        return 0
        ;;
    esac
  done

  tls_profile_node_options "$config_file"
  local profile_options="$_tls_node_options"
  if [[ "$profile_options" != *--tls-cipher-list=* ]]; then
    _log_and_fail "profile '${requested}' resolved to ${config_file} but it has no cipher settings"
  fi

  export OPENSSL_CONF="$config_file"
  export _AWS_LAMBDA_RESOLVED_TLS_PROFILE="$config_base"
  export NODE_OPTIONS="${NODE_OPTIONS:+${NODE_OPTIONS} }${profile_options}"
  echo "[tls-profile] applied '${requested}' -> ${config_file}" >&2
}

# Node ignores the ciphers and protocol bounds in OPENSSL_CONF, so they are
# passed as node options. Node uses the loosest of repeated --tls-min-v and
# --tls-max-v flags, so bounds equal to node's defaults are left out.
tls_profile_node_options() {
  _tls_read_conf "$1"
  local policy="${_tls_conf[ssl_module/system_default]-}" value ciphers="" options=()
  _tls_node_options=""
  [ -n "$policy" ] || return 0
  ciphers="${_tls_conf[$policy/CipherString]-}"
  value="${_tls_conf[$policy/Ciphersuites]-}"
  [ -n "$value" ] && ciphers="${ciphers:+${ciphers}:}${value}"
  value="${_tls_conf[$policy/TLS.MinProtocol]-TLSv1.2}"
  [ "$value" != "TLSv1.2" ] && options+=("--tls-min-v$(_tls_node_version "$value")")
  value="${_tls_conf[$policy/TLS.MaxProtocol]-TLSv1.3}"
  [ "$value" != "TLSv1.3" ] && options+=("--tls-max-v$(_tls_node_version "$value")")
  [ -n "$ciphers" ] && options+=("--tls-cipher-list=${ciphers}")
  _tls_node_options="${options[*]}"
  return 0
}

# Reads a conf into _tls_conf[section/key] the way OpenSSL does: spaces around
# = are optional, # starts a comment and the last value wins.
_tls_read_conf() {
  local line section="default"
  declare -gA _tls_conf=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    if [[ "$line" =~ ^[[:space:]]*\[[[:space:]]*([^][:space:]]+)[[:space:]]*\] ]]; then
      section="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]]) ]]; then
      _tls_conf["$section/${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done < "$1"
}

# TLSv1 -> 1.0, TLSv1.2 -> 1.2
_tls_node_version() {
  local v="${1#TLSv}"
  [ "$v" = "1" ] && v="1.0"
  echo "$v"
}

resolve_tls_profile
