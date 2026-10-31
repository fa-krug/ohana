---
layout: home
title: Ohana
titleTemplate: One app for the whole family

hero:
  name: Ohana
  text: One app for the whole family
  tagline: Calendar, finances, meals, doctor appointments and an AI assistant that works across all of them. Open source, self-hosted, with a native app for iPhone, iPad and Mac.
  image:
    src: /icon.svg
    alt: Ohana
  actions:
    - theme: brand
      text: Quick start
      link: /quickstart
    - theme: alt
      text: What is Ohana?
      link: /introduction
    - theme: alt
      text: GitHub
      link: https://github.com/fa-krug/ohana

features:
  - icon: 📅
    title: Calendar
    details: The family's year at a glance. Vacation, public holidays, sick days and day-care closures, the days nobody covers, timed events, birthdays and an iCalendar feed for any calendar app.
    link: /introduction#calendar
  - icon: 💶
    title: Finance
    details: Accounts, a category tree, transfers and split bookings, CSV import of bank statements, monthly overviews and comparisons.
    link: /introduction#finance
  - icon: 🍲
    title: Meals
    details: Recipes with photos and kitchen-machine steps, a meal plan that shares ingredients and skips the days you're away, shopping lists that work offline.
    link: /introduction#meals
  - icon: 🩺
    title: Appointments
    details: Searches that watch Doctolib and jameda for a free appointment and tell you the moment one shows up. Booked ones go into the calendar.
    link: /introduction#appointments
  - icon: ✨
    title: Assistant
    details: Chat with any OpenAI-compatible model, in the cloud or on your own machine. It reads and changes the calendar, finances, meals and appointments, with undo.
    link: /introduction#assistant
  - icon: 🏠
    title: Yours, at home
    details: One Docker image and one SQLite file on a Raspberry Pi or a small server. No tracking, no account with us, your data stays on your server.
    link: /self-hosting
---

## How it fits together

```
 iPhone / iPad / Mac app ──HTTPS──▶  ohana (server)             ohana-worker (same image)
   SwiftUI, native                    JSON API /api/v1          assistant turns, appointment
                                      sign-in pages             searches, notifications, backups
                                            └──── /app/data: SQLite, photos, backups ────┘
```

You run the **server** on your own machine: two containers from one image, sharing one volume.
Your family uses the **native app** on their iPhones, iPads and Macs. There is no web app: the
server serves the API and the few pages that need your server's own address (signing in with
passkeys, the first-run setup, invite links). [Read more →](/introduction)

## Up and running in five minutes

```bash
mkdir ohana && cd ohana
curl -O https://raw.githubusercontent.com/fa-krug/ohana/main/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/fa-krug/ohana/main/.env.example
# set APP_URL and AUTH_SECRET in .env, then:
docker compose up -d
```

Then open `https://<your server>/setup`, create the first account and connect the app. The
[quick start](/quickstart) walks you through it, the [self-hosting guide](/self-hosting) covers
HTTPS, backups, updates, AI and notifications.

## Open source

The server is licensed under the **GNU AGPL-3.0**, the app under the **Mozilla Public License
2.0**. Contributions are welcome: see
[CONTRIBUTING.md](https://github.com/fa-krug/ohana/blob/main/CONTRIBUTING.md) and report
vulnerabilities [privately](/security).
