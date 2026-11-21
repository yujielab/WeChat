#!/usr/bin/env bash
# Seeds a local `wrangler dev` hub with demo accounts and conversations, for
# the Simulator screenshots (.github/workflows/ios-screens.yml).
# Usage: ios/tools/seed.sh http://localhost:8787
set -euo pipefail
B=${1:-http://localhost:8787}

# The session cookie is Secure, which curl won't send over plain http, so
# each account's token is kept and sent by hand. (Plain variables: macOS
# ships bash 3.2, without associative arrays.)
tok() { local v="TOKEN_$1"; printf '%s' "${!v}"; }
post() { # who path json
  curl -sS --max-time 90 --retry 3 --retry-delay 2 --retry-all-errors -H "Cookie: cfm_session=$(tok "$1")" -H "Origin: $B" -H 'content-type: application/json' -d "$3" "$B$2"
}
get() { curl -sS --max-time 90 --retry 3 --retry-delay 2 --retry-all-errors -H "Cookie: cfm_session=$(tok "$1")" -H "Origin: $B" "$B$2"; }

reg() { # who username display
  local h
  h=$(curl -sS --max-time 90 --retry 3 --retry-delay 2 --retry-all-errors -D - -o /dev/null -H "Origin: $B" -H 'content-type: application/json' \
    -d "{\"username\":\"$2\",\"password\":\"cuven-demo\",\"display\":\"$3\"}" "$B/auth/register")
  local t
  t=$(printf '%s' "$h" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: cfm_session=\([^;]*\).*/\1/p' | head -1)
  [ -n "$t" ] || { echo "register $2 failed"; printf '%s\n' "$h"; exit 1; }
  printf -v "TOKEN_$1" '%s' "$t"
}

reg a alice "Alice"
reg b bob "Bob Lin"
reg c carol "Carol"
reg d dan "Dan Wu"
reg e eve "Eve"

id() { get "$1" /api/me | jq -r .me.id; }
A=$(id a); BOB=$(id b); C=$(id c); D=$(id d); E=$(id e)

# Friends: Bob and Dan accepted; Carol waiting for Alice; Alice asked Eve.
post b /api/contacts/add "{\"user\":\"$A\"}" >/dev/null
post a /api/contacts/accept "{\"user\":\"$BOB\"}" >/dev/null
post d /api/contacts/add "{\"user\":\"$A\"}" >/dev/null
post a /api/contacts/accept "{\"user\":\"$D\"}" >/dev/null
post c /api/contacts/add "{\"user\":\"$A\"}" >/dev/null
post a /api/contacts/add "{\"user\":\"$E\"}" >/dev/null

say() { # jar room text
  local body
  body=$(jq -n --arg r "$2" --arg t "$3" '{room:$r,type:"text",text:$t}')
  post "$1" /api/messages "$body" >/dev/null
  sleep 0.15
}

R1=$(post b /api/dm "{\"user\":\"$A\"}" | jq -r .room.id)
say b "$R1" "Hey! Are we still on for Saturday?"
say a "$R1" "Yes! Hiking at 8, meet at the metro station 🚇"
say b "$R1" "Perfect. The forecast says sunny and not too hot."
say b "$R1" "Should we ask Dan to come too?"
say a "$R1" "Good idea, he mentioned it last time"
say b "$R1" "I'll bring snacks 🍙"
say a "$R1" "See you then 👋"
say b "$R1" "Oh, and bring a jacket, it gets windy at the top"
say a "$R1" "Good call. Do you still have the trail map?"
say b "$R1" "It's on my phone, I'll send it Friday"
say a "$R1" "How long is the loop?"
say b "$R1" "About 12 km, four hours with lunch"
say a "$R1" "Lunch at the hut?"
say b "$R1" "Yes, they do the noodle soup 🍜"
say a "$R1" "Sold."
say b "$R1" "❤️"

R2=$(post d /api/dm "{\"user\":\"$A\"}" | jq -r .room.id)
say d "$R2" "Did you see the photos from the trip?"
say a "$R2" "Not yet — send them over!"
say d "$R2" "Tonight, promise."

G=$(post a /api/group "{\"name\":\"Weekend hike\",\"members\":[\"$BOB\",\"$D\"]}" | jq -r .room.id)
say a "$G" "Made a group for Saturday"
say b "$G" "Nice 🙌"
say d "$G" "Count me in!"

# A note and a moment from Bob, a reaction from Alice.
post b /api/note '{"text":"Saturday hike ⛰️"}' >/dev/null
post d /api/note '{"text":"Coffee anyone?"}' >/dev/null
post b /api/moments '{"text":"First snow of the year on the ridge. Who is coming up next weekend?","media":[],"audience":"friends"}' >/dev/null
post d /api/moments '{"text":"New café around the corner has the best flat white in town ☕️","media":[],"audience":"everyone"}' >/dev/null
post d /api/moments '{"text":"Saturday plan: up early, coffee, then the long loop round the lake.","media":[],"audience":"everyone"}' >/dev/null
post d /api/moments '{"text":"Finally fixed the bike. It only took three weekends and one very patient friend.","media":[],"audience":"everyone"}' >/dev/null
LAST=$(get a "/api/messages?room=$R1&limit=1" | jq -r '.messages[-1].id')
post a /api/react "{\"id\":\"$LAST\",\"emoji\":\"❤️\"}" >/dev/null

echo "seeded: alice / cuven-demo (rooms $R1 $R2 $G)"
