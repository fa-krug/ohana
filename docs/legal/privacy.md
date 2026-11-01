---
title: Privacy policy
description: Privacy policy for ohana.fa-krug.de and the Ohana app
---

# Privacy policy

This policy explains which personal data is processed when you visit **ohana.fa-krug.de** and
when you use the **Ohana app** for iPhone, iPad and Mac. In short: this website doesn't track
you, and the app sends your data only to the Ohana server you connect it to. If you turn on
notifications in the app, they pass through our push relay encrypted, so we can't read them.

*Last updated: 1 November 2026*

## Who is responsible

The controller within the meaning of the General Data Protection Regulation (GDPR) for this
website and the Ohana app is:

<Operator />

## This website

### Hosting on GitHub Pages

This website is a static site hosted by **GitHub Pages**, a service of GitHub, Inc., 88 Colin P
Kelly Jr Street, San Francisco, CA 94107, USA. When you open a page, your browser sends GitHub
technical data that every web server receives: your IP address, the date and time, the page
requested, the referring page, and your browser and operating system. GitHub processes this
data to deliver the website and to keep the service secure, and may keep it in log files for a
limited time. The legal basis is Art. 6(1)(f) GDPR: the legitimate interest in presenting this
website reliably and securely.

GitHub may process this data in the USA. GitHub, Inc. is certified under the EU-U.S. Data
Privacy Framework, on the basis of the European Commission's adequacy decision (Art. 45 GDPR).
Details: [GitHub General Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

### No cookies, no tracking

This website sets **no cookies** and uses **no analytics, tracking or advertising**. Fonts,
scripts and the API reference are served from this website itself, not from third-party
servers. The search runs entirely in your browser.

If you switch between the light and the dark theme, your browser remembers the choice in its
local storage (`vitepress-theme-appearance`). This stays on your device, is never sent to us
and is strictly necessary for the function you asked for (§ 25(2) no. 2 TDDDG). You can remove
it at any time by clearing the site's data in your browser.

### Links to GitHub

Many links lead to the project's repository on GitHub (github.com). When you follow them,
GitHub's own privacy statement applies.

### Contacting us

If you write to us by email or through GitHub, we process your message and contact details
only to deal with your request (Art. 6(1)(b) GDPR where it concerns a contract or a request in
advance of one, otherwise Art. 6(1)(f) GDPR) and delete them once it has been dealt with,
unless the law requires us to keep them.

## The Ohana app

### What we receive: almost nothing

The app contains **no analytics, no tracking, no advertising** and no third-party SDKs. We, the
developers of the app, **receive no data** about you or about how you use it, except what our
push relay needs when you turn on notifications (see *Notifications in the app*). The app's
privacy manifest declares no collected data types and no tracking.

The only exception is Apple's own mechanism: if you have chosen in your device's settings to
share analytics with app developers, Apple may provide us with anonymised crash reports and
usage statistics. This is controlled by Apple and by your device settings
([Apple's privacy policy](https://www.apple.com/legal/privacy/)).

### Your Ohana server

Ohana is self-hosted. Everything you enter in the app (calendar, finances, recipes,
appointments, chats with the assistant, account data) is sent **directly to the Ohana server
you connect the app to**, over the address you enter, and stored there. The **operator of that
server** (often you or someone in your family) decides how it is run and is responsible for the
data on it. We have no access to servers run by others.

What a server sends to other services depends on what its families set up, for example:

- the **AI provider** a family chooses for the assistant (the chat, the family members' names
  and ages, the data the assistant reads to answer and, if you let the app use Reminders, your
  open reminders; see *Permissions*),
- a **web search provider** (Tavily or Brave) for the assistant's searches,
- **Doctolib** and **jameda** for appointment searches (the specialities, practices and places
  searched),
- **Photon** by komoot to find addresses (the address typed) and, for the *Week ahead*'s travel
  checks, where the next two weeks' events are (their locations, unless the server turned that
  off),
- the **notification services** a family sets up (Pushover, Pushbullet, Telegram, an email
  provider, ntfy) with the text of the notifications.

Ask your server's operator about their privacy policy.

### Notifications in the app

Notifications in the app are **off until you turn them on** on a device (*Settings →
Notifications on this device*). Apple delivers notifications to an app only when they are
signed with the app developer's key, which your Ohana server doesn't have. So your server sends
them through our **push relay** (`ohana-push.fa-krug.de`), which passes them on to Apple's Push
Notification service (APNs) and on to your device:

- When you turn notifications on, the app sends the relay your device's **push token** (an
  address Apple gives the app for notifications on this device), whether it is an iPhone/iPad or
  a Mac, and its network address. The relay answers with an encrypted form of that token, which
  the app gives your server. The relay doesn't store it.
- For each notification, your server sends the relay that encrypted token and the
  notification. **What a notification says is encrypted end to end**: the app makes a key that
  only your server and your device know; the relay and Apple can't read the text, the link or
  which family it is about. The relay sees the address of the sending server, the device token,
  the time and the size, keeps them only in memory while sending (and, for limiting misuse, for
  at most a day), and logs only counts and errors, never tokens or contents.
- Apple processes the token and the encrypted notification to deliver it
  ([Apple's privacy policy](https://www.apple.com/legal/privacy/)).

The legal basis is Art. 6(1)(b) GDPR (delivering the notifications you turned on) and our
legitimate interest in keeping the relay from being misused (Art. 6(1)(f)). Turning
notifications off, signing out or deleting the app stops them; your server's operator can also
turn them off for the whole server.

### On your device

The app stores on your device only what it needs to work: the **API token** for your server
and, so the *Save to Ohana* share extension can reach it, the server's address and the selected
family, and with notifications on the key for them (in the Keychain), app settings such as the
selected family and the Reminders list for each family's shopping (in the app's preferences), a
**copy of what your server last sent** (your account, your families and the screens you opened,
and what it loads ahead in the background: calendar, meal plan, recipes and so on), so the app
opens on it at once and you can read it without a connection, changes made offline (calendar
days and notes) until they're sent, and the cook view's running timers. The copy is kept in the
app's cache, which the system may empty when space runs low. If you use the **widgets**, they
load your family's overview from the same server with the same token and keep a copy of it on
your device (today's and tomorrow's calendar, tonight's dinner, found appointments), so they can
show it while the server is out of reach; no other service or permission is involved. The names, tags and short descriptions of
your recipes are added to the device's **Spotlight** index, so you can find them in the system
search; the index stays on the device. Signing out deletes the token on the server and on the
device, the app's copy and the changes not sent yet, and removes the recipes from Spotlight;
the widgets then delete their copy. Deleting the app removes the rest.

### Permissions

The app only asks for these permissions, and only when you use the feature:

- **Camera and photos:** to add pictures to recipes. The picture is uploaded to your server.
  And to scan receipts: the receipt is read on your device (Apple's text recognition); the
  picture stays there, only the amount, date and shop you save are sent to your server.
  And to scan letters (a school letter, a notice, an invitation): the letter is read on your
  device the same way and the picture stays there. With the assistant on, its text is sent to
  your server and from there to the AI provider your family set up, which finds the dates,
  tasks and deadlines in it (also when you attach a letter to a chat). What it finds is only
  added (to your family's calendar, or as reminders) once you choose it. If you save a scanned letter or receipt as a PDF, it goes only into the folder you pick
  (the app remembers that folder on the device); its name and tags are suggested on your device
  (with Apple's on-device model where available), and the PDF isn't sent anywhere.
- **Microphone and speech recognition:** to dictate messages to the assistant. The speech is
  turned into text by Apple's speech recognition, which may process it on Apple's servers
  ([Apple's privacy policy](https://www.apple.com/legal/privacy/)); the text is sent to your
  server.
- **Notifications:** asked when you turn on notifications on a device (see *Notifications in the
  app*), or when you start your first timer in a recipe's cook view, to tell you when it's done.
  The timer runs on the device; nothing is sent to your server. Running timers also show as a
  Live Activity on the Lock Screen and in the Dynamic Island.
- **Calendars:** asked when you turn on the sync with Apple Calendar (Settings → Calendar). The
  app reads and writes only the one calendar you pick: your family's events and day entries are
  written into it, and its events are sent to your server as events of the family (title,
  times, place, notes, a link). Which calendar and which events belong together is kept on the
  device. The sync runs on the device; your calendar account (iCloud, Google, …) syncs that
  calendar as it does any other. Stopping the sync can remove Ohana's events from the calendar;
  signing out forgets the setting.
  When you use the **assistant** on a device with calendar access, each message you send also
  carries the **events of your calendars** from a week back to three months ahead (their titles,
  times, places, notes, repeat rules and the names of their calendars, at most 1000) to your
  Ohana server, which keeps the latest copy with the chat and sends it to the AI provider your
  family set up, so the assistant can answer about them. The assistant can't change your
  calendars on its own: it shows what it wants to change, and the app changes them on your device
  only after you tap **Apply**. You can take the permission back at any time in the system
  settings (*Privacy & Security → Calendars*); the assistant then no longer sees your calendars.
- **Reminders:** asked when you pick a Reminders list for a family's shopping, or when you add
  a task or deadline found in a scanned letter. For the shopping, the app
  writes what the meal plan needs (item, amount, shopping day) into that list on your device and
  keeps those items up to date; it gets them from your server, but nothing from Reminders is
  sent back for this. If your reminders sync over iCloud, Apple stores them as it does any
  reminder ([Apple's privacy policy](https://www.apple.com/legal/privacy/)).
  When you use the **assistant** on a device with Reminders access, each message you send
  also carries your **open reminders** (their titles, notes, due dates and the names of their
  lists, at most 500) to your Ohana server, which keeps the latest copy with the chat and sends
  it to the AI provider your family set up, so the assistant can answer about them. The
  assistant can't change your reminders on its own: it shows what it wants to change, and the
  app changes them on your device only after you tap **Apply**. You can take the permission back
  at any time in the system settings (*Privacy & Security → Reminders*); the assistant then no
  longer sees your reminders.

With Siri and Shortcuts (*Ask Ohana*, adding to the shopping list in Reminders, adding an event,
importing a recipe), what you say is processed by Apple as for any Siri request; the result is
sent to your server, or, for the shopping list, added to your Reminders list on the device.

### Importing recipes

When you import a recipe from a web page (the *Save to Ohana* share extension in Safari, the
Shortcuts action or the address field in the app), the page's address and, from Safari on iPhone
and iPad, its text are sent to your server. The server loads the page and its photo itself when
needed and sends the page's content to the AI provider your family set up for the assistant, as
for any request to the assistant.

### Demo mode

Without a connected server, the app shows demo data that is part of the app. Nothing is sent
anywhere.

## Your rights

You have the right to **access** your personal data (Art. 15 GDPR), to have it **corrected**
(Art. 16), **erased** (Art. 17) or its processing **restricted** (Art. 18), to **data
portability** (Art. 20) and to **object** to processing based on legitimate interests
(Art. 21). To exercise them, contact us at the address above. For data on an Ohana server, the
server's operator is the right contact.

You also have the right to lodge a complaint with a data protection supervisory authority
(Art. 77 GDPR), in particular in the EU member state of your residence, your place of work or
the place of the alleged infringement.

## Changes

We update this policy when the website or the app changes. The current version is always on
this page; its history is in the
[repository](https://github.com/fa-krug/ohana/commits/main/docs/legal/privacy.md).
