import sys
import json
import re

# Usage: python3 link_lib.py <path_to_artifact_file> <placeholder> <library_address>

# Get bytecode from file
path = sys.argv[1]
with open(path, 'r') as file: # Open the compiler output file
    artifact = json.load(file)
    bytecode = artifact['bytecode']

# Pattern to match the hex string in the bytecode (__$placeholder$__).
placeholder = sys.argv[2].lower()
if len(placeholder) != 34:
    raise Exception("Invalid placeholder")

# Get a library address without the 0x prefix
lib_addr = sys.argv[3].lower()[2:]
if len(lib_addr) != 40:
    raise Exception("Invalid library address")

# e.g. __$1234567890123456789012345678901234567890$__
pattern = r"__\$" + re.escape(placeholder) + r"\$__"

# Replacement
result = re.sub(pattern, lib_addr, bytecode)
print(result)