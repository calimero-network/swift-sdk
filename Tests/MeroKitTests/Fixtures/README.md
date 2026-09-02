# Response fixtures

Bodies captured **verbatim** from a live `merod` on core `0.11.0-rc.29`
(`ci/core-version`). Nothing here is hand-assembled from what the SDK expects,
which is the point: a fixture written to match the model can only confirm the
model agrees with itself.

That is not hypothetical. `joinNamespace` shipped broken against core rc.25
because every test asserted the *request* — verb, path, body — and none decoded
a realistic reply, so a renamed response field went unnoticed until the call
threw on every join. And the previous invitation model named 2 of the envelope's
5 keys and 5 of the signed body's 6, with a full green suite, because each test
built its input from the same model it then asserted on.

## Refreshing after a core bump

Boot a node at the pinned release (TESTING.md §4a) and re-capture:

```sh
TOK=…   # POST /auth/token, see TESTING.md §4b
B=http://localhost:4001/admin-api

curl -s "$B/identity"                      -H "Authorization: Bearer $TOK"  # rc29-node-identity.json
curl -s "$B/account/devices"               -H "Authorization: Bearer $TOK"  # rc29-account-devices.json
curl -s "$B/account/applications"          -H "Authorization: Bearer $TOK"  # rc29-account-applications.json
curl -s "$B/groups/$NS/member-devices"     -H "Authorization: Bearer $TOK"  # rc29-member-devices.json
curl -s -X POST "$B/namespaces/$NS/invite" -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' -d '{}'                              # .data.invitation
```

A diff against the committed file is itself the signal: if a field appeared or
changed shape, that is a wire change to handle, not a fixture to overwrite
quietly.
