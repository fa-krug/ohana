---
title: Privacy policy
description: Privacy policy for ohana.fa-krug.de and the Ohana app
---

# Privacy policy

This policy explains which personal data is processed when you visit **ohana.fa-krug.de** and
when you use the **Ohana app** for iPhone, iPad and Mac. In short: this website doesn't track
you, and the app sends your data only to the Ohana server you connect it to.

*Last updated: 31 October 2026*

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

### What we receive: nothing

The app contains **no analytics, no tracking, no advertising** and no third-party SDKs. We, the
developers of the app, **receive no data** about you or about how you use it. The app's
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
  and ages and the data the assistant reads to answer),
- a **web search provider** (Tavily or Brave) for the assistant's searches,
- **Doctolib** and **jameda** for appointment searches (the specialities, practices and places
  searched),
- **Photon** by komoot to find addresses (the address typed),
- the **notification services** a family sets up (Pushover, Pushbullet, Telegram, an email
  provider, ntfy) with the text of the notifications.

Ask your server's operator about their privacy policy.

### On your device

The app stores on your device only what it needs to work: the **API token** for your server
(in the Keychain), app settings such as the selected family (in the app's preferences) and
changes to the shopping list made offline until they're sent, and the cook view's running timers. Signing out deletes the token on
the server and on the device. Deleting the app removes the rest.

### Permissions

The app only asks for these permissions, and only when you use the feature:

- **Camera and photos:** to add pictures to recipes. The picture is uploaded to your server.
  And to scan receipts: the receipt is read on your device (Apple's text recognition); the
  picture stays there, only the amount, date and shop you save are sent to your server.
- **Microphone and speech recognition:** to dictate messages to the assistant. The speech is
  turned into text by Apple's speech recognition, which may process it on Apple's servers
  ([Apple's privacy policy](https://www.apple.com/legal/privacy/)); the text is sent to your
  server.
- **Notifications:** asked when you start your first timer in a recipe's cook view, to tell you
  when it's done. The timer runs on the device; nothing is sent to your server. Running timers
  also show as a Live Activity on the Lock Screen and in the Dynamic Island.

With Siri and Shortcuts (*Ask Ohana*), what you say is processed by Apple as for any Siri
request.

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
