import re, sys, urllib.request, urllib.parse, http.cookiejar, random, uuid
base = sys.argv[1]
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
def get(p):
    r = op.open(base + p); return r.geturl(), r.read().decode()
# Rails pages carry a CSRF token; the Rust app checks Sec-Fetch-Site instead and renders none.
def csrf(html): m = re.search(r'name="csrf-token" content="([^"]+)"', html); return m.group(1) if m else ""
def post(p, data, token):
    d = urllib.parse.urlencode({**data, "authenticity_token": token}).encode()
    r = op.open(urllib.request.Request(base + p, d, {"Accept": "text/vnd.turbo-stream.html, text/html", "Sec-Fetch-Site": "same-origin"})); return r.geturl(), r.read().decode()
op.open(base + "/session/new")
if "--prepared" not in sys.argv[2:]:
    url, html = get("/first_run")
url, html = get("/session/new")
url, html = post("/session", {"email_address": "david@example.com", "password": "secret123456"}, csrf(html)) if "first_run" not in url else post("/first_run", {"user[name]": "David Hansson", "user[email_address]": "david@example.com", "user[password]": "secret123456"}, csrf(html))
print("after first run:", url)
room = re.search(r"/rooms/(\d+)", url + html).group(1)
random.seed(1)
words = "campfire rails ship deploy review parity sqlite gzip cable turbo stimulus hotwire basecamp once message room sidebar avatar boost thread".split()
bodies = []
for i in range(80):
    s = " ".join(random.choice(words) for _ in range(random.randint(5, 40)))
    kind = i % 5
    if kind == 1: s = f"<div>Look at <a href=\"https://example.com/{i}\">this link</a> about <strong>{s}</strong></div>"
    elif kind == 2: s = f"<div>{s}</div><ul><li>{random.choice(words)}</li><li>{random.choice(words)} https://github.com/basecamp/{random.choice(words)}</li></ul>"
    elif kind == 3: s = f"<div><em>{s}</em></div><pre>let x = {i};\nprintln!(\"{{x}}\");</pre>"
    else: s = f"<div>{s}</div>"
    bodies.append(s)
_, html = get(f"/rooms/{room}")
token = csrf(html)
for b in bodies:
    post(f"/rooms/{room}/messages", {"message[body]": b, "message[client_message_id]": str(uuid.uuid4())}, token)
print("room", room)
for c in jar: print(f"{c.name}={c.value}")
