{writers}:
writers.writePython3Bin "neo-reporter-submit" {
  flakeIgnore = ["E501" "W503"];
} (builtins.readFile ../scripts/neo-reporter-submit.py)
