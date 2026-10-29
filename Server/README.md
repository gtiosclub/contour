# Contour server

Two HTTPS endpoints on Firebase Cloud Functions that call OpenAI for the app.
The OpenAI key lives here as a Firebase secret. It never goes in the iOS app,
in this repo, or in a log.

- `POST {base}/plan`: turn what the user said into a sequence of button presses.
- `POST {base}/label`: read the buttons in a scan photo.

`{base}` is the function URL, for example
`https://us-central1-<project-id>.cloudfunctions.net/api`.

## Contract

Every request needs the header `X-Firebase-AppCheck: <App Check token>` and
`Content-Type: application/json`.

### POST /plan

```json
{ "request": "cook for a minute and a half",
  "buttons": [{ "id": "<button id>", "label": "1" }, { "id": "<button id>", "label": "Start" }] }
```

`label` may be `null` (or missing, or `""`) for a button that couldn't be read.

```json
200 { "steps": ["<id>", "<id>", "<id>", "<id>"], "say": "Press 1, 3, 0, then Start." }
200 { "steps": [], "say": "This microwave doesn't have a defrost button." }
```

- `steps` only ever contains ids from the request. A button can appear more
  than once ("1, 1, 0").
- If any step the model picks doesn't match a button that was sent, the server
  returns `steps: []` rather than a shortened plan. Dropping one digit from
  1, 3, 0 cooks for the wrong time.
- When there are steps, the server builds `say` from their labels, so what the
  user hears always matches what the vibration guides them through. The
  model's own sentence is used only when `steps` is empty.

### POST /label

```json
{ "image": "<base64 JPEG of the scan photo>",
  "boxes": [{ "id": "b1", "x": 0.1, "y": 0.2, "w": 0.1, "h": 0.05 }] }
```

Box coordinates are fractions of the photo, origin top-left, y down. `image` is
bare base64 with no `data:` prefix and no line breaks (Swift's
`data.base64EncodedString()` gives exactly that).

```json
200 { "boxes": [{ "id": "b1", "label": "Popcorn", "isButton": true }], "start": "b7" }
```

- Ids only come from the request. `boxes` is in request order but may leave
  out a box the model didn't answer for, so look results up by `id`.
- `label` is `""` when the model couldn't read the box.
- `start` is the id of the start button, or `null`.

### Errors

Error bodies keep the success shape, so one decoder handles every status, and
add a short sentence the app can read aloud plus a machine code:

```json
401 { "steps": [], "say": "Sorry, Contour couldn't verify this app.", "error": "unauthorized" }
504 { "boxes": [], "start": null, "say": "That took too long. Please try again.", "error": "upstream_timeout" }
```

| status | `error` | when |
|---|---|---|
| 400 | `invalid_request` | the body breaks a rule below. `detail` says which field. |
| 401 | `unauthorized` | missing or invalid App Check token |
| 404 / 405 | `not_found` / `method_not_allowed` | wrong path, or not POST |
| 413 | `too_large` | body or image over the limit |
| 429 | `rate_limited` | too many requests from this IP. Has a `Retry-After` header. |
| 500 | `misconfigured` / `internal` | no model or key set up, or a bug |
| 502 | `upstream_error` | OpenAI failed, refused a `/label`, or returned something unusable |
| 504 | `upstream_timeout` | OpenAI took longer than 8 s |

A plan the model can't do, or refuses, is a `200` with `steps: []`, as the
contract says.

### Limits

| | |
|---|---|
| `request` | 1 to 300 characters |
| `buttons`, `boxes` | at most 120, ids unique, 1 to 64 characters |
| button `label` | longer labels are cut to 60 characters |
| `image` | at most 1,500,000 base64 characters (about 1.1 MB of JPEG) |
| body | 64 KB for /plan, 1.6 MB for /label |
| plan length | at most 20 steps |
| OpenAI call | 8 s, then 504 |

For the photo, about 1600 px on the long side at JPEG quality 0.7 is a sensible
starting point and stays well under the limit.

All limits are in `functions/src/limits.js`.

## Layout

```
Server/
  firebase.json            functions source, runtime (Node 24), emulator port
  .firebaserc.example      copy to .firebaserc and set the project id
  functions/
    index.js               Firebase wiring only (secret, params, App Check, logger)
    src/limits.js          every limit in one place
    src/validate.js        request validation
    src/prompts.js         prompts and the strict JSON schemas
    src/openai.js          one Chat Completions call over fetch
    src/repair.js          model answer -> contract response
    src/rateLimit.js       in-memory per-IP limiter
    src/handler.js         the whole request path, dependencies passed in
    test/*.test.js         node --test, offline, stubbed fetch
```

Nothing in `src/` has a dependency, so the tests run without `npm install`.
The model never sees the app's ids: buttons and boxes go to it numbered 1, 2, 3
and the answer is mapped back, which costs fewer tokens than UUIDs and makes an
invented id impossible to return.

## Tests

```sh
cd Server/functions
node --test
```

No network, no install, no key. `test/structure.test.js` also checks that
`src/` stays dependency-free and that `index.js` parses.

## One-time setup (Neel)

1. **Firebase project.** Create one in the Firebase console (or reuse one) and
   switch it to the Blaze plan. Cloud Functions, secrets and outbound calls to
   OpenAI need it. In Google Cloud Billing, add a budget alert on the project.
   That only sends alerts. What limits spending is the OpenAI budget in step 3
   and `maxInstances` in `functions/index.js`.
2. **Point the CLI at it.**
   ```sh
   cd Server
   cp .firebaserc.example .firebaserc     # put the project id in it
   firebase login
   cd functions && npm install
   ```
3. **OpenAI budget and key.** In the OpenAI dashboard, make a project just for
   Contour, set a monthly budget on that project, and create the API key inside
   it. Check whether the budget hard-stops requests or only emails you. If it
   only emails, keep `maxInstances` low and watch usage. If you can restrict
   the key's permissions, it only needs Chat Completions.
4. **Store the key as a secret.** It prompts for the value, so the key never
   lands in a file or your shell history:
   ```sh
   firebase functions:secrets:set OPENAI_API_KEY
   ```
5. **Pick the model.** Create `Server/functions/.env` (Git ignores it):
   ```sh
   OPENAI_MODEL=<model id>
   ```
   Pick a small, fast model that accepts images and supports Structured
   Outputs (`json_schema`), from OpenAI's current model list. The code has no default on purpose, because model names change. Time a
   real `/label` call with 30 or so boxes: it has to come back well inside 8 s.
   If the model is a reasoning model, also set
   `OPENAI_REASONING_EFFORT=<the lowest value it accepts>` or it will time out.
   Leave that line out for other models, because they reject the field.

## App Check (iOS)

The function checks every request's `X-Firebase-AppCheck` token with
`firebase-admin`. That token check is the only enforcement. The App Check
"Enforce" switch in the console only covers Firebase's own products, so it
does nothing for this function.

1. In the Firebase console, add an iOS app with bundle id
   `edu.gatech.gtiosclub.contour` and download `GoogleService-Info.plist`.
2. App Check → Apps → register that app with **App Attest** (needs the Apple
   Team ID). Contour targets iOS 27 and App Attest has been there since
   iOS 14, so DeviceCheck, the older fallback provider, isn't needed.
3. In Xcode, add the App Attest capability to ContourApp. App Attest needs a
   paid Apple Developer Program team. Anyone signing with a personal team uses
   the debug provider instead. Before a TestFlight or App Store build, set the
   App Attest environment in ContourApp's `.entitlements` file to
   `production`, as Firebase's App Attest guide says.
4. Add `FirebaseCore` and `FirebaseAppCheck` (firebase-ios-sdk, SPM) to
   ContourApp, then set the provider before `FirebaseApp.configure()`:
   ```swift
   final class ContourAppCheckFactory: NSObject, AppCheckProviderFactory {
       func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
           #if DEBUG
           return AppCheckDebugProvider(app: app)
           #else
           return AppAttestProvider(app: app)
           #endif
       }
   }

   AppCheck.setAppCheckProviderFactory(ContourAppCheckFactory())
   FirebaseApp.configure()
   ```
   On every request:
   ```swift
   let token = try await AppCheck.appCheck().token(forcingRefresh: false)
   request.setValue(token.token, forHTTPHeaderField: "X-Firebase-AppCheck")
   ```
5. Debug builds print a debug token in the Xcode console on first launch. Add
   it in the console under App Check → Apps → Manage debug tokens. Each
   developer and each simulator gets its own.

## Run locally (emulator)

```sh
cd Server
# Skip App Check in the emulator only. A deployed function ignores this flag.
echo 'APPCHECK_BYPASS=true' > functions/.env.local
firebase emulators:start --only functions
```

The emulator reads the key from `functions/.secret.local`. Make that file in
an editor with one line, `OPENAI_API_KEY=sk-...`. Git ignores `*.local` in
`functions/`. `OPENAI_MODEL` comes from `functions/.env`, the same as a deploy.

The base URL is `http://127.0.0.1:5001/<project-id>/us-central1/api`:

```sh
curl -s http://127.0.0.1:5001/<project-id>/us-central1/api/plan \
  -H 'Content-Type: application/json' \
  -d '{"request":"cook for a minute and a half","buttons":[{"id":"a","label":"1"},{"id":"b","label":"3"},{"id":"c","label":"0"},{"id":"d","label":"Start"}]}'

printf '{"image":"%s","boxes":[{"id":"b1","x":0.1,"y":0.2,"w":0.1,"h":0.05}]}' \
  "$(base64 -i panel.jpg | tr -d '\n')" > /tmp/label.json
curl -s http://127.0.0.1:5001/<project-id>/us-central1/api/label \
  -H 'Content-Type: application/json' --data-binary @/tmp/label.json
```

The bypass needs both `FUNCTIONS_EMULATOR=true`, which the emulator sets, and
`APPCHECK_BYPASS=true`. Without the bypass, the emulator verifies real tokens
like production does.

The iOS simulator can reach `127.0.0.1` on the Mac, but a phone can't. If App
Transport Security blocks plain `http`, add an `NSAllowsLocalNetworking`
exception to debug builds only.

## Deploy

```sh
cd Server
firebase deploy --only functions
```

The first deploy enables the Google Cloud APIs it needs and asks about an
Artifact Registry cleanup policy (say yes, it keeps old images from costing
money). The function URL it prints is `{base}`. Check it is locked:

```sh
curl -i -X POST {base}/plan -H 'Content-Type: application/json' -d '{}'
# expect 401 and "error": "unauthorized"
```

## Switching the app from the fake to the server

Surface devs keep building against their fakes until the URL exists. The real
client takes two things from ContourApp:

- a base URL: the deployed `{base}`, or the emulator URL in the simulator
- a token provider: `{ try await AppCheck.appCheck().token(forcingRefresh: false).token }`

Keep Firebase in ContourApp and pass the token provider into the client as a
closure. That keeps SurfaceUnderstanding depending on ContourCore only, and
the switch from fake to real client happens in ContourApp's wiring. Requests
and responses are exactly the contract above, which the fakes already follow.
Set the client's request timeout above the server's 8 s, for example 12 s.

## Rate limit

Per client IP, in memory, per function instance: 20 `/plan` and 6 `/label`
requests a minute. Each instance counts on its own and a cold start resets the
count, so the real ceiling is those numbers times `maxInstances` (3, in
`index.js`). That's enough to stop one client hammering the endpoint. The
OpenAI project budget is the real spending limit. The IP is the right-most
`X-Forwarded-For` entry, which is the one Google's front end adds. That is an
assumption about Cloud Run's header to confirm once deployed. If it's wrong,
the limit turns into a shared per-instance limit, which errs strict. Phones on
one network (campus Wi-Fi, a demo room) can share a public IP and so share
these limits; raise `RATE_LIMITS` in `src/limits.js` if a demo hits 429s.

## Logging

One structured log line per request: route, status, outcome, body bytes,
counts (buttons, boxes, steps, labeled), request length, image bytes, token
usage, OpenAI time and total time. Never the image, the request text, labels,
ids, IPs or tokens. `test/handler.test.js` checks this.
