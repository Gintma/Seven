# Resolve to a certificate hash and its name to use the same identity for every signature.
find_signing_identity() {
  local requested="$1"
  local developer_id_only="${2:-false}"
  security find-identity -v -p codesigning | awk -v wanted="$requested" -v developer_id_only="$developer_id_only" '
    /^[[:space:]]*[0-9]+\)/ {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*$/, "", name)
      if (developer_id_only == "true" && name !~ /^Developer ID Application:/) next
      if (wanted != "" && toupper(wanted) != $2 && wanted != name) next
      if (!found++) print $2 "\t" name
    }
  '
}
