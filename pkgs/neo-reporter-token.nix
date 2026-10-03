{writers}:
writers.writePython3Bin "neo-reporter-token" {
  flakeIgnore = ["E501"];
} (builtins.replaceStrings ["#!/usr/bin/env python3\n"] [""] (builtins.readFile ../scripts/neo-reporter-token.py))
