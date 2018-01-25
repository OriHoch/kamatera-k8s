#!/usr/bin/env python2

import sys, json, yaml, os

filename = sys.argv[1]
with open(filename) as f:
    values = yaml.load(f)

def get_from_dict(values, keys):
    if len(keys) > 1:
        return get_from_dict(values[keys[0]], keys[1:])
    else:
        return values[keys[0]]

try:
    print(json.dumps(get_from_dict(values, sys.argv[2:]), separators=(',', ':')))
except Exception:
    if os.environ.get("KAMATERA_DEBUG") == "1":
        raise
    else:
        print('{}')
