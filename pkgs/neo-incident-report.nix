# neo-incident-report: compatibility alias (one release) for send-report.
#   neo-incident-report [--dry-run] [--config FILE] [--file PAYLOAD.json | -]
# → send-report --json [--dry-run] --file PAYLOAD.json (--config is ignored:
# the reporter service owns endpoint and token now).
{
  writeShellApplication,
  send-report,
}:
writeShellApplication {
  name = "neo-incident-report";
  text = ''
    args=(--json)
    file=-
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) args+=(--dry-run) ;;
        --config) shift ;;
        --file) shift; file="''${1:?--file needs a path}" ;;
        -) file=- ;;
        -h|--help) exec ${send-report}/bin/send-report --help ;;
        *) echo "neo-incident-report: unknown argument: $1 (use send-report)" >&2; exit 2 ;;
      esac
      shift
    done
    echo "neo-incident-report is deprecated; use send-report --json --file …" >&2
    exec ${send-report}/bin/send-report "''${args[@]}" --file "$file"
  '';
}
