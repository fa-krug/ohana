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

## The calendar feed

Each family has a public, unguessable **iCalendar feed** for calendar apps, with options for
events and birthdays. Its address is in the app (the calendar's settings) and in
`GET /api/v1/families/{id}/links`. Anyone with the link can read the calendar; a new link can be
made in the app.
