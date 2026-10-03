{
  writeShellApplication,
  jq,
  curl,
  coreutils,
  hostname,
}:
writeShellApplication {
  name = "neo-incident-report";
  runtimeInputs = [jq curl coreutils hostname];
  text = builtins.readFile ../scripts/neo-incident-report.sh;
}
