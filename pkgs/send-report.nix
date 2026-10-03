{writers}:
writers.writePython3Bin "send-report" {
  flakeIgnore = ["E501" "W503"];
} (builtins.readFile ../scripts/send-report.py)
