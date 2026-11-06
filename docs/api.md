# API

Everything the app does goes through a documented JSON API, and your own scripts and AI agents
can use it the same way.

- **Reference:** [API reference](/api-reference.html) (OpenAPI 3.1, the file is
  [openapi.yaml](https://github.com/fa-krug/ohana/blob/main/docs/openapi.yaml)).
- **Base URL:** `https://<your server>/api/v1`.

## Signing in

Send a personal **API token** as a bearer token:

```bash
curl -H "Authorization: Bearer $OHANA_TOKEN" https://ohana.example.com/api/v1/me
```

Create a token in the app under *Settings → Account* (API tokens), or with
`POST /api/v1/me/tokens` using an existing one. The token is shown once; the server stores only
its hash. Every token acts as its account: it can do what the account may do in each family.

## AI agents

To let an outside AI agent (Claude Code, ChatGPT, …) work with a family, choose *Copy Prompt for
AI Agent* in the app's assistant and paste the prompt into the agent. It holds a token that
works for **one hour** and **only for that family's API** (`/api/v1/families/{id}/…`, plus
`/api/v1/server`): it can't reach your account (`/api/v1/me…`, so no new tokens or password),
the administration, invites or your other families (`403`). It acts with your role in the
family, so a viewer's agent can only read, and an editor's can change everything but what would
outlast the hour or send the family's data elsewhere: members and people, invites, notification
channels, the assistant's settings and deleting the family stay with the app (`403`). The token shows among your API tokens until it
expires, and you can revoke it there. Scripts get the same with
`POST /api/v1/families/{id}/agent/token` → `{ "token", "expiresAt", "prompt" }`. The prompt
points the agent to `GET /api/v1/families/{id}/agent`: the family's instructions (its calendar's
entry types with their ids, the finance conventions and ready-to-use requests).

## A first look around

```bash
# Who am I, which families am I in? (the ids are in "families")
curl -H "Authorization: Bearer $OHANA_TOKEN" https://ohana.example.com/api/v1/me

# A family's calendar year, with its events and birthdays
curl -H "Authorization: Bearer $OHANA_TOKEN" \
  "https://ohana.example.com/api/v1/families/$FAMILY_ID"

# The overview: what's coming up across all modules
curl -H "Authorization: Bearer $OHANA_TOKEN" \
  "https://ohana.example.com/api/v1/families/$FAMILY_ID/overview"

# The week ahead: the next two weeks and what doesn't work out (clashes, tight transfers, …)
curl -H "Authorization: Bearer $OHANA_TOKEN" \
  "https://ohana.example.com/api/v1/families/$FAMILY_ID/digest"
```

`GET /api/v1/server` (no token needed) tells you the server's version, its API version and which
modules are on.

## Rules of the road

- **Roles:** members are editors (read and change) or viewers (read). Not being a member is a
  `404`, as if the family didn't exist; a viewer asking for a change gets `403`.
- **Errors** are JSON: `{ "error": "…" }` (a few routes: `{ "message": "…" }`).
- **Dates** are `YYYY-MM-DD`, timestamps ISO 8601, **money** is integer cents.
- **Undo:** changes that can be undone return what puts them back (`inverse` ops for finance,
  `undo` for the meal plan) instead of the server keeping a history.
- **The API only grows.** Fields and routes are added, not removed or renamed; a change older
  apps can't handle raises `apiVersion` in `/api/v1/server`.

## Calendar events

Events may span several days (`date` to `endDate`) and repeat (`rrule`, an iCalendar RRULE
value such as `FREQ=WEEKLY;BYDAY=MO,WE`). `GET /api/v1/families/{id}/events?from=&to=` lists
the occurrences in a range; an occurrence of a repeating event carries its original day in
`occurrence`, and `?occurrence=…&span=this|future` on `PATCH` / `DELETE /events/{id}` changes or
removes only that occurrence, or it and the ones after it. `?raw=1` lists every event as stored:
a series with its rule, the days taken out of it (`exdates`) and the occurrences changed on their
own (`overrides`).

## Chores

`GET /api/v1/families/{id}/chores/agenda?from=&to=&today=` lists the chores by day (at most 62
days), each day's by part of the day (`morning`, `day`, `evening`) and time, with the open ones
before `today` as `overdue`. `POST /chores/{id}/done` with `{ "done": true, "day": "…" }` ticks
one off (`day`: the occurrence of a repeating chore); repeating chores use the same `rrule` as
events.
