<script setup lang="ts">
// The home page (docs/index.md): a product page. The app pictures are drawn in HTML/CSS
// (made-up family), so they stay sharp, follow the theme and need no screenshots.

const icons: Record<string, string[]> = {
  check: ["M20 6 9 17l-5-5"],
  calendar: ["M8 2v4", "M16 2v4", "M3 10h18", "M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"],
  wallet: ["M19 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2", "M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"],
  utensils: ["M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2", "M7 2v20", "M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7"],
  stethoscope: ["M11 2v2", "M5 2v2", "M5 3H4a2 2 0 0 0-2 2v4a6 6 0 0 0 12 0V5a2 2 0 0 0-2-2h-1", "M8 15a6 6 0 0 0 12 0v-3", "M20 8a2 2 0 1 0 0 4 2 2 0 0 0 0-4z"],
  sparkles: ["M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z", "M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"],
  shield: ["M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z", "m9 12 2 2 4-4"],
  heart: ["M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"],
  code: ["m16 18 6-6-6-6", "m8 6-6 6 6 6"],
  server: ["M4 2h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z", "M4 14h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2z", "M6 6h.01", "M6 18h.01"],
  lock: ["M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z", "M7 11V7a5 5 0 0 1 10 0v4"],
  cpu: ["M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z", "M9 9h6v6H9z", "M9 1v3", "M15 1v3", "M9 20v3", "M15 20v3", "M20 9h3", "M20 14h3", "M1 9h3", "M1 14h3"],
  archive: ["M3 3h18v5H3z", "M5 8v11a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8", "M10 12h4"],
  bell: ["M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9", "M10.3 21a1.94 1.94 0 0 0 3.4 0"],
  arrow: ["M5 12h14", "m12 5 7 7-7 7"],
  github: [],
}

// July 2027 in the calendar picture (starts on a Thursday): v = vacation, h = public holiday, s = sick, g = nobody
// covers, t = today, "" = a normal day, null = outside the month.
const month: (string | null)[] = [
  null, null, null, "", "", "", "",
  "", "", "", "", "t", "", "",
  "", "", "", "g", "", "", "",
  "v", "v", "v", "v", "v", "v", "v",
  "", "s", "", "", "h", "", null,
]
const dayNumber = (i: number) => i - 2

// The meal plan's shopping items as they land in Reminders, due on their shopping day.
const shopping = [
  { day: "Due Saturday", items: [["500 g Tomatoes", true], ["1 bunch Basil", true], ["3 Lemons", false]] },
  { day: "Due Tuesday", items: [["2 Mozzarella", false], ["500 g Greek yogurt", false]] },
]

const spending = [
  { name: "Groceries", value: 82, amount: "€612" },
  { name: "Housing", value: 100, amount: "€1,450" },
  { name: "Kids", value: 38, amount: "€284" },
  { name: "Leisure", value: 24, amount: "€176" },
]

const faqs = [
  {
    q: "What does Ohana cost?",
    a: "Nothing. Ohana is free and open source. You run it on hardware you already have, or a small server for a few euros a month. The only optional costs are the AI provider you pick for the assistant, or none if you run a model at home.",
  },
  {
    q: "Do I need to be technical?",
    a: "A little. If you can run a Docker container and point a domain at it, the quick start gets you there in about ten minutes. After that the family only ever sees the app.",
  },
  {
    q: "Which devices does it run on?",
    a: "The native app runs on iPhone, iPad and Mac (iOS/iPadOS 26 and macOS 26 or newer). The server runs anywhere Docker does, a Raspberry Pi 4 is plenty.",
  },
  {
    q: "Where is my family's data stored?",
    a: "Only on your server, in a single SQLite file with nightly backups. Nobody else, including us, has access to it. The app talks directly to your server.",
  },
  {
    q: "Does it work outside Germany?",
    a: "Yes. The app speaks English and German. Only the appointment search uses German services (Doctolib and jameda), and you can turn that module off with one setting, like any module you don't need.",
  },
  {
    q: "Which AI does the assistant use?",
    a: "The one you choose: any OpenAI-compatible endpoint, from OpenAI, Anthropic or Google to OpenRouter, or a local model with Ollama or LM Studio so nothing leaves your home.",
  },
]
</script>

<template>
  <div class="landing">
    <!-- Hero -->
    <section class="hero">
      <div class="glow glow-a" aria-hidden="true" />
      <div class="glow glow-b" aria-hidden="true" />
      <div class="container hero-grid">
        <div class="hero-copy">
          <p class="eyebrow">
            <span class="dot" /> Free · Open source · Self-hosted
          </p>
          <h1>
            Your whole family.<br />
            <span class="gradient-text">One app.</span>
          </h1>
          <p class="lead">
            Ohana brings your family's calendar, money, meals and doctor's appointments together,
            with an AI assistant that helps across all of them. It runs on your own server, so
            your family's life stays at home.
          </p>
          <div class="cta-row">
            <a class="btn btn-primary" href="/quickstart">
              Get started
              <svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.arrow" :key="d" :d="d" /></svg>
            </a>
            <a class="btn btn-ghost" href="#features">See what it does</a>
          </div>
          <ul class="hero-points">
            <li><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.check" :key="d" :d="d" /></svg>No subscription</li>
            <li><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.check" :key="d" :d="d" /></svg>No tracking</li>
            <li><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.check" :key="d" :d="d" /></svg>iPhone, iPad &amp; Mac</li>
          </ul>
        </div>

        <div class="hero-visual" aria-hidden="true">
          <!-- Mac window: the calendar -->
          <div class="mac">
            <div class="mac-bar"><i /><i /><i /><span>Ohana</span></div>
            <div class="mac-body">
              <div class="mac-side">
                <div class="side-family"><b>M</b> The Millers</div>
                <div class="side-item"><span class="sq ov" />Overview</div>
                <div class="side-item active"><span class="sq cal" />Calendar</div>
                <div class="side-item"><span class="sq fin" />Finance</div>
                <div class="side-item"><span class="sq meal" />Meals</div>
                <div class="side-item"><span class="sq appt" />Appointments</div>
              </div>
              <div class="mac-main">
                <div class="mac-title">July <small>2027</small></div>
                <div class="month-grid small">
                  <span v-for="d in ['M','T','W','T','F','S','S']" class="wd">{{ d }}</span>
                  <span
                    v-for="(c, i) in month"
                    :key="i"
                    class="day"
                    :class="c === null ? 'out' : c"
                  >{{ c === null ? "" : dayNumber(i) }}</span>
                </div>
                <div class="legend">
                  <span><i class="v" />Vacation</span>
                  <span><i class="h" />Holiday</span>
                  <span><i class="s" />Sick</span>
                  <span><i class="g" />Nobody covers</span>
                </div>
              </div>
            </div>
          </div>

          <!-- iPhone: the overview -->
          <div class="phone">
            <div class="notch" />
            <div class="phone-screen">
              <div class="ph-head">
                <small>Friday, 9 July</small>
                <b>Overview</b>
              </div>
              <div class="ph-card">
                <span class="tag appt">Monday</span>
                <b>Emma · Pediatrician</b>
                <small>10:30 · Dr. Weber</small>
              </div>
              <div class="ph-card">
                <span class="tag meal">Tonight</span>
                <b>Tomato basil pasta</b>
                <small>25 min · 4 servings</small>
              </div>
              <div class="ph-card warn">
                <span class="tag cal">Next week</span>
                <b>Thursday not covered</b>
                <small>Day care closed</small>
              </div>
              <div class="ph-ask">
                <svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.sparkles" :key="d" :d="d" /></svg>
                Ask Ohana…
              </div>
            </div>
          </div>

          <!-- A notification -->
          <div class="toast">
            <span class="toast-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.bell" :key="d" :d="d" /></svg></span>
            <div><b>Earlier appointment found</b><small>Dermatologist · Tue 09:15</small></div>
          </div>
        </div>
      </div>
    </section>

    <!-- Pillars -->
    <section class="container pillars">
      <div class="pillar">
        <span class="pillar-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.heart" :key="d" :d="d" /></svg></span>
        <h3>Made for families</h3>
        <p>Parents edit, grandparents look. Kids without a phone still have their birthdays and appointments. Invite everyone with a link.</p>
      </div>
      <div class="pillar">
        <span class="pillar-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.shield" :key="d" :d="d" /></svg></span>
        <h3>Private by design</h3>
        <p>Your server, your rules. No ads, no analytics, no account with us. Sign in with passkeys, secrets encrypted at rest.</p>
      </div>
      <div class="pillar">
        <span class="pillar-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.code" :key="d" :d="d" /></svg></span>
        <h3>Yours, for good</h3>
        <p>Free and open source under AGPL and MPL. No subscription to cancel, no company that can switch it off.</p>
      </div>
    </section>

    <!-- Features -->
    <section id="features" class="container features">
      <div class="section-head">
        <p class="kicker">Everything in one place</p>
        <h2>Five apps your family no longer needs</h2>
        <p>One shared home for the things that keep a family running, built to work together.</p>
      </div>

      <!-- Calendar -->
      <div class="feature">
        <div class="feature-copy">
          <span class="badge cal"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.calendar" :key="d" :d="d" /></svg>Calendar</span>
          <h3>See the whole year at a glance</h3>
          <p>Vacation, public holidays, sick days and day-care closures in one view, so you spot the days nobody can cover long before they arrive.</p>
          <ul class="checks">
            <li>Who's off, who's home, and the gaps in between</li>
            <li>Appointments, events and everyone's birthdays</li>
            <li>A live feed for Apple, Google or any calendar app</li>
          </ul>
        </div>
        <div class="feature-visual">
          <div class="panel">
            <div class="panel-head"><b>July 2027</b><span class="chip warn">1 day not covered</span></div>
            <div class="month-grid">
              <span v-for="d in ['Mon','Tue','Wed','Thu','Fri','Sat','Sun']" class="wd">{{ d }}</span>
              <span v-for="(c, i) in month" :key="i" class="day" :class="c === null ? 'out' : c">{{ c === null ? "" : dayNumber(i) }}</span>
            </div>
            <div class="legend">
              <span><i class="v" />Summer vacation</span>
              <span><i class="h" />Holiday</span>
              <span><i class="s" />Sick</span>
              <span><i class="g" />Nobody covers</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Meals -->
      <div class="feature reverse">
        <div class="feature-copy">
          <span class="badge meal"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.utensils" :key="d" :d="d" /></svg>Meals</span>
          <h3>Dinner, planned. Shopping, sorted.</h3>
          <p>Your recipes, a meal plan that picks dishes sharing ingredients and skips the days you're away, and everything it needs on your shopping list in Apple Reminders.</p>
          <ul class="checks">
            <li>Recipes with photos, tags and kitchen-machine steps</li>
            <li>Groceries in a Reminders list the family shares</li>
            <li>New recipes and photos with AI, if you like</li>
          </ul>
        </div>
        <div class="feature-visual">
          <div class="panel two-col">
            <div>
              <div class="panel-head"><b>This week</b></div>
              <div class="plan">
                <div><small>Mon</small><b>Tomato basil pasta</b></div>
                <div><small>Tue</small><b>Lemon chicken</b></div>
                <div class="away"><small>Wed</small><b>Away · Grandma's</b></div>
                <div><small>Thu</small><b>Veggie curry</b></div>
                <div><small>Fri</small><b>Pizza night</b></div>
              </div>
            </div>
            <div>
              <div class="panel-head"><b>Groceries</b><span class="chip">Reminders</span></div>
              <div v-for="g in shopping" :key="g.day" class="aisle">
                <small>{{ g.day }}</small>
                <div v-for="[name, done] in g.items" :key="String(name)" class="item" :class="{ done }">
                  <span class="box"><svg v-if="done" viewBox="0 0 24 24" class="icon"><path v-for="d in icons.check" :key="d" :d="d" /></svg></span>{{ name }}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Finance -->
      <div class="feature">
        <div class="feature-copy">
          <span class="badge fin"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.wallet" :key="d" :d="d" /></svg>Finance</span>
          <h3>Know where the money goes</h3>
          <p>Import your bank statements, let Ohana sort them into categories, and see each month at a glance, without handing your bank data to yet another service.</p>
          <ul class="checks">
            <li>CSV import for any bank, duplicates recognized</li>
            <li>Transfers, split bookings and your own categories</li>
            <li>Receipts scanned with your phone's camera</li>
          </ul>
        </div>
        <div class="feature-visual">
          <div class="panel">
            <div class="panel-head"><b>June</b><span class="chip good">€340 saved</span></div>
            <div class="bars">
              <div v-for="s in spending" :key="s.name" class="bar-row">
                <span>{{ s.name }}</span>
                <div class="bar"><i :style="{ width: s.value + '%' }" /></div>
                <b>{{ s.amount }}</b>
              </div>
            </div>
            <div class="totals">
              <div><small>Income</small><b>€4,890</b></div>
              <div><small>Spent</small><b>€4,550</b></div>
              <div><small>vs. May</small><b class="good">−6%</b></div>
            </div>
          </div>
        </div>
      </div>

      <!-- Appointments -->
      <div class="feature reverse">
        <div class="feature-copy">
          <span class="badge appt"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.stethoscope" :key="d" :d="d" /></svg>Appointments</span>
          <h3>Get the doctor's appointment, sooner</h3>
          <p>Tell Ohana which doctors you'd go to. It keeps watching Doctolib and jameda and tells you the moment a slot opens up, or only when it's earlier than the one you have.</p>
          <ul class="checks">
            <li>Searches across practices, around the clock</li>
            <li>Notifications on your phone, in seconds</li>
            <li>One tap and the appointment is in the calendar</li>
          </ul>
        </div>
        <div class="feature-visual">
          <div class="panel">
            <div class="panel-head"><b>Pediatrician for Emma</b><span class="chip live"><i />Watching</span></div>
            <div class="slots">
              <div class="slot new"><div><b>Tue, 13 July · 09:15</b><small>Dr. Weber · 1.2 km</small></div><span class="chip good">New</span></div>
              <div class="slot"><div><b>Thu, 22 July · 14:40</b><small>Kinderarztpraxis Nord · 3.8 km</small></div></div>
              <div class="slot"><div><b>Mon, 2 Aug · 08:00</b><small>Dr. Yilmaz · 2.5 km</small></div></div>
            </div>
            <p class="muted">3 practices · checked 2 minutes ago</p>
          </div>
        </div>
      </div>

      <!-- Assistant -->
      <div class="feature">
        <div class="feature-copy">
          <span class="badge ai"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.sparkles" :key="d" :d="d" /></svg>Assistant</span>
          <h3>An assistant that knows your family</h3>
          <p>Ask in plain words. The assistant reads and changes your calendar, finances, meals and appointments, and every change it makes can be undone with a tap. It even keeps your reminders in order, once you say OK.</p>
          <ul class="checks">
            <li>Any AI you like, in the cloud or running at home</li>
            <li>Read-only for viewers, so nothing changes by accident</li>
            <li>Keeps working when you close the app</li>
          </ul>
        </div>
        <div class="feature-visual">
          <div class="panel chat">
            <div class="msg me">We're at Grandma's next weekend. Can you plan dinners around it?</div>
            <div class="msg ai">
              <span class="ai-mark"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.sparkles" :key="d" :d="d" /></svg></span>
              <div>
                Done! I marked <b>Sat–Sun</b> as away, moved the lasagne to Friday and, as you said OK, added 4 items to your shopping list.
                <div class="changes">
                  <span class="chip">Calendar · 2 days</span>
                  <span class="chip">Meal plan · 1 change</span>
                  <span class="chip">Reminders · 4 items</span>
                </div>
                <span class="undo">Undo</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <!-- Connected -->
    <section class="container connected">
      <div class="section-head">
        <p class="kicker">Better together</p>
        <h2>Everything talks to everything</h2>
        <p>Because it's one app, the pieces know about each other, so you don't have to keep them in sync.</p>
      </div>
      <div class="links">
        <div class="link-card"><div class="flow"><span class="sq cal" />→<span class="sq meal" /></div><b>Away days skip the meal plan</b><p>Off to Grandma's? No groceries bought for meals you won't cook.</p></div>
        <div class="link-card"><div class="flow"><span class="sq appt" />→<span class="sq cal" /></div><b>Booked appointments land in the calendar</b><p>With the time, the practice and who it's for.</p></div>
        <div class="link-card"><div class="flow"><span class="sq meal" />→<span class="sq rem" /></div><b>The meal plan writes your shopping list</b><p>What the week's dinners need lands in Reminders, due on shopping day.</p></div>
        <div class="link-card"><div class="flow"><span class="sq ai" />→<span class="sq ov" /></div><b>One assistant for all of it</b><p>One question can touch the calendar, the meal plan and your reminders.</p></div>
      </div>
    </section>

    <!-- Privacy band -->
    <section class="privacy">
      <div class="container privacy-grid">
        <div>
          <p class="kicker light">Self-hosted</p>
          <h2>Your family's life belongs at home</h2>
          <p class="lead light">
            Calendars, bank statements, health appointments: some of the most private data a family
            has. With Ohana it lives on a machine you own, not in someone else's cloud.
          </p>
          <a class="btn btn-light" href="/self-hosting">Read the self-hosting guide</a>
        </div>
        <div class="privacy-points">
          <div><span class="p-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.server" :key="d" :d="d" /></svg></span><b>Runs on a Raspberry Pi</b><p>One Docker image, one SQLite file. Any small server will do.</p></div>
          <div><span class="p-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.lock" :key="d" :d="d" /></svg></span><b>Passkeys &amp; encryption</b><p>Passwordless sign-in, secrets encrypted at rest, tokens stored only as hashes.</p></div>
          <div><span class="p-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.cpu" :key="d" :d="d" /></svg></span><b>Bring your own AI</b><p>Use any provider, or run a model at home so nothing leaves your network.</p></div>
          <div><span class="p-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.archive" :key="d" :d="d" /></svg></span><b>Nightly backups</b><p>Automatic database backups, ready to copy wherever you like.</p></div>
        </div>
      </div>
    </section>

    <!-- How it works -->
    <section class="container how">
      <div class="section-head">
        <p class="kicker">How it works</p>
        <h2>Set it up once, use it every day</h2>
        <p>One person in the family gets Ohana running. Everyone else just installs the app.</p>
      </div>
      <div class="how-steps">
        <div class="how-step">
          <span class="how-num">1</span>
          <h3>Set it up at home</h3>
          <p>Whoever in the family likes tinkering puts Ohana on a small computer at home, like a Raspberry Pi. It takes about ten minutes.</p>
          <div class="how-visual">
            <div class="device">
              <span class="device-icon"><svg viewBox="0 0 24 24" class="icon"><path v-for="d in icons.server" :key="d" :d="d" /></svg></span>
              <div><b>Ohana at home</b><small>Raspberry Pi</small></div>
              <span class="chip live"><i />Running</span>
            </div>
          </div>
        </div>
        <div class="how-step">
          <span class="how-num">2</span>
          <h3>Invite your family</h3>
          <p>Send everyone an invite link. They install the app on their iPhone, iPad or Mac, tap the link and they're in.</p>
          <div class="how-visual">
            <div class="invite">
              <img src="/icon.svg" alt="" width="36" height="36" />
              <div><b>Join “The Millers”</b><small>Anna invited you to Ohana</small></div>
              <span class="invite-btn">Join</span>
            </div>
          </div>
        </div>
        <div class="how-step">
          <span class="how-num">3</span>
          <h3>Plan together</h3>
          <p>Everyone works from the same calendar and meal plan, each on their own iPhone, iPad or Mac.</p>
          <div class="how-visual">
            <div class="together">
              <div class="avatars"><span style="background:#0d9488">A</span><span style="background:#f97316">T</span><span style="background:#8b5cf6">E</span><span style="background:#0ea5e9">N</span></div>
              <div><b>Tom moved Tuesday's dinner</b><small>Meal plan · just now</small></div>
            </div>
          </div>
        </div>
      </div>
      <p class="how-note">
        Setting it up? The <a href="/quickstart">quick start</a> walks you through it step by step.
      </p>
    </section>

    <!-- FAQ -->
    <section class="container faq">
      <div class="section-head">
        <p class="kicker">Questions</p>
        <h2>Good to know</h2>
      </div>
      <div class="faq-list">
        <details v-for="f in faqs" :key="f.q">
          <summary>{{ f.q }}</summary>
          <p>{{ f.a }}</p>
        </details>
      </div>
    </section>

    <!-- Final CTA -->
    <section class="container final">
      <div class="final-card">
        <img src="/icon.svg" alt="" width="72" height="72" />
        <h2>Give your family a home base</h2>
        <p>Free, open source and yours. Set it up this weekend.</p>
        <div class="cta-row center">
          <a class="btn btn-light" href="/quickstart">Get started</a>
          <a class="btn btn-outline-light" href="https://github.com/fa-krug/ohana">View on GitHub</a>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.landing {
  --teal: #0d9488;
  --teal-strong: #0f766e;
  --cal: #0ea5e9;
  --fin: #16a34a;
  --meal: #f97316;
  --appt: #e11d48;
  --ai: #8b5cf6;
  --ink: var(--vp-c-text-1);
  --muted: var(--vp-c-text-2);
  --card: var(--vp-c-bg);
  --soft: var(--vp-c-bg-soft);
  --line: var(--vp-c-divider);
  --shadow: 0 1px 2px rgba(15, 23, 42, 0.06), 0 12px 32px -12px rgba(15, 23, 42, 0.18);
  overflow-x: clip;
  color: var(--ink);
}
:global(.dark .landing) {
  --card: #1e1e22;
  --soft: #18181b;
  --shadow: 0 1px 2px rgba(0, 0, 0, 0.4), 0 16px 40px -16px rgba(0, 0, 0, 0.7);
}

.container {
  max-width: 1152px;
  margin: 0 auto;
  padding: 0 24px;
}
.icon {
  width: 1em;
  height: 1em;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
  flex: none;
}
h1, h2, h3 { letter-spacing: -0.02em; color: var(--ink); }
h2 { font-size: clamp(28px, 4vw, 40px); line-height: 1.15; font-weight: 700; margin: 0 0 14px; }
h3 { font-size: clamp(22px, 2.6vw, 28px); line-height: 1.2; font-weight: 700; margin: 14px 0 12px; }
p { margin: 0; }

/* Buttons */
.cta-row { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 28px; }
.cta-row.center { justify-content: center; }
.btn {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 12px 22px; border-radius: 999px;
  font-weight: 600; font-size: 15px; text-decoration: none;
  transition: transform 0.15s ease, box-shadow 0.15s ease, background 0.15s ease;
}
.btn:hover { transform: translateY(-1px); }
.btn-primary { background: var(--teal); color: #fff; box-shadow: 0 8px 20px -8px rgba(13, 148, 136, 0.7); }
.btn-primary:hover { background: var(--teal-strong); }
.btn-ghost { background: var(--soft); color: var(--ink); border: 1px solid var(--line); }
.btn-light { background: #fff; color: #0f766e; }
.btn-outline-light { border: 1px solid rgba(255, 255, 255, 0.5); color: #fff; }
.btn-outline-light:hover { background: rgba(255, 255, 255, 0.1); }

/* Hero */
.hero { position: relative; padding: 72px 0 96px; }
.glow { position: absolute; border-radius: 50%; filter: blur(80px); opacity: 0.45; pointer-events: none; }
.glow-a { width: 520px; height: 520px; background: #5eead4; top: 40px; right: -120px; }
.glow-b { width: 420px; height: 420px; background: #a5b4fc; bottom: -120px; left: -160px; opacity: 0.3; }
:global(.dark .landing .glow) { opacity: 0.18; }
.hero-grid { position: relative; display: grid; grid-template-columns: 1.02fr 1fr; gap: 48px; align-items: center; }
.eyebrow {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 6px 14px; border-radius: 999px; font-size: 13px; font-weight: 500;
  background: color-mix(in srgb, var(--teal) 10%, transparent); color: var(--vp-c-brand-1);
  border: 1px solid color-mix(in srgb, var(--teal) 25%, transparent);
}
.eyebrow .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--teal); box-shadow: 0 0 0 4px color-mix(in srgb, var(--teal) 25%, transparent); }
h1 { font-size: clamp(42px, 6.2vw, 70px); line-height: 1.04; font-weight: 800; margin: 22px 0 22px; letter-spacing: -0.025em; }
.gradient-text { background: linear-gradient(110deg, #0d9488 10%, #14b8a6 45%, #6366f1 100%); -webkit-background-clip: text; background-clip: text; color: transparent; }
.lead { font-size: 19px; line-height: 1.6; color: var(--muted); max-width: 540px; }
.hero-points { display: flex; flex-wrap: wrap; gap: 8px 22px; list-style: none; padding: 0; margin: 28px 0 0; font-size: 14px; color: var(--muted); }
.hero-points li { display: flex; align-items: center; gap: 6px; }
.hero-points .icon { color: var(--teal); }

/* Hero visual */
.hero-visual { position: relative; height: 560px; }
.mac {
  position: absolute; top: 10px; right: -24px; width: calc(100% + 24px); max-width: 600px;
  background: var(--card); border: 1px solid var(--line); border-radius: 14px; box-shadow: var(--shadow); overflow: hidden;
}
.mac-bar { display: flex; align-items: center; gap: 6px; padding: 10px 12px; border-bottom: 1px solid var(--line); background: var(--soft); font-size: 12px; color: var(--muted); }
.mac-bar i, .term-bar i { width: 11px; height: 11px; border-radius: 50%; background: #ff5f57; }
.mac-bar i:nth-child(2), .term-bar i:nth-child(2) { background: #febc2e; }
.mac-bar i:nth-child(3), .term-bar i:nth-child(3) { background: #28c840; }
.mac-bar span, .term-bar span { margin-left: 10px; }
.mac-body { display: grid; grid-template-columns: 138px 1fr; min-height: 380px; }
.mac-side { padding: 12px 10px; border-right: 1px solid var(--line); background: var(--soft); font-size: 12px; }
.side-family { display: flex; align-items: center; gap: 8px; font-weight: 600; margin-bottom: 14px; }
.side-family b { display: grid; place-items: center; width: 22px; height: 22px; border-radius: 6px; background: var(--teal); color: #fff; font-size: 11px; }
.side-item { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 7px; color: var(--muted); }
.side-item.active { background: color-mix(in srgb, var(--teal) 14%, transparent); color: var(--ink); font-weight: 600; }
.sq { display: inline-block; width: 12px; height: 12px; border-radius: 4px; }
.sq.ov { background: var(--teal); } .sq.cal { background: var(--cal); } .sq.fin { background: var(--fin); }
.sq.meal { background: var(--meal); } .sq.appt { background: var(--appt); } .sq.ai { background: var(--ai); }
.sq.rem { background: #64748b; }
.mac-main { padding: 16px 18px; }
.mac-title { font-size: 20px; font-weight: 700; margin-bottom: 10px; }
.mac-title small { color: var(--muted); font-weight: 500; font-size: 14px; }

.phone {
  position: absolute; left: -36px; bottom: 0; width: 226px; height: 486px;
  border-radius: 38px; padding: 10px; background: #111827; box-shadow: 0 30px 60px -20px rgba(15, 23, 42, 0.55);
}
:global(.dark .landing .phone) { box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.14), 0 30px 60px -20px rgba(0, 0, 0, 0.8); }
.notch { position: absolute; top: 18px; left: 50%; transform: translateX(-50%); width: 72px; height: 20px; border-radius: 12px; background: #111827; z-index: 2; }
.phone-screen { height: 100%; border-radius: 29px; background: var(--soft); padding: 44px 11px 12px; display: flex; flex-direction: column; gap: 7px; overflow: hidden; }
.ph-head small { display: block; font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
.ph-head b { font-size: 19px; }
.ph-card { background: var(--card); border-radius: 14px; padding: 8px 11px; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06); display: flex; flex-direction: column; gap: 2px; }
.ph-card b { font-size: 13px; }
.ph-card small { font-size: 11px; color: var(--muted); }
.ph-card.warn { border: 1px solid color-mix(in srgb, var(--appt) 35%, transparent); }
.tag { white-space: nowrap; align-self: flex-start; font-size: 9.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; padding: 2px 7px; border-radius: 999px; margin-bottom: 3px; }
.tag.appt { background: color-mix(in srgb, var(--appt) 14%, transparent); color: var(--appt); }
.tag.meal { background: color-mix(in srgb, var(--meal) 16%, transparent); color: #c2410c; }
.tag.cal { background: color-mix(in srgb, var(--cal) 15%, transparent); color: #0369a1; }
:global(.dark .landing .tag.meal) { color: #fdba74; }
:global(.dark .landing .tag.cal) { color: #7dd3fc; }
.ph-ask { margin-top: auto; display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-radius: 999px; background: var(--card); border: 1px solid var(--line); font-size: 12px; color: var(--muted); }
.ph-ask .icon { color: var(--ai); }

.toast {
  position: absolute; right: -8px; bottom: 40px; display: flex; align-items: center; gap: 10px;
  padding: 10px 14px 10px 10px; border-radius: 16px; background: color-mix(in srgb, var(--card) 88%, transparent);
  backdrop-filter: blur(12px); border: 1px solid var(--line); box-shadow: var(--shadow); font-size: 12px;
}
.toast b { display: block; font-size: 13px; }
.toast small { color: var(--muted); }
.toast-icon { display: grid; place-items: center; width: 32px; height: 32px; border-radius: 9px; background: var(--appt); color: #fff; font-size: 16px; }

/* Calendar picture */
.month-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 5px; }
.month-grid .wd { font-size: 11px; color: var(--muted); text-align: center; font-weight: 600; padding-bottom: 2px; }
.month-grid .day { aspect-ratio: 1.15; display: grid; place-items: center; border-radius: 8px; font-size: 13px; background: var(--soft); font-variant-numeric: tabular-nums; }
.month-grid.small { gap: 4px; }
.month-grid.small .day { font-size: 11px; border-radius: 6px; aspect-ratio: 1.25; }
.month-grid .day.out { background: transparent; }
.month-grid .day.v { background: color-mix(in srgb, var(--teal) 22%, transparent); color: var(--vp-c-brand-1); font-weight: 600; }
.month-grid .day.h { background: color-mix(in srgb, #f59e0b 25%, transparent); font-weight: 600; }
.month-grid .day.s { background: color-mix(in srgb, var(--appt) 20%, transparent); font-weight: 600; }
.month-grid .day.g { background: transparent; outline: 2px dashed var(--appt); outline-offset: -2px; color: var(--appt); font-weight: 700; }
.month-grid .day.t { background: var(--teal); color: #fff; font-weight: 700; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 14px; margin-top: 14px; font-size: 12px; color: var(--muted); }
.legend span { display: flex; align-items: center; gap: 6px; }
.legend i { width: 10px; height: 10px; border-radius: 3px; }
.legend i.v { background: color-mix(in srgb, var(--teal) 45%, transparent); }
.legend i.h { background: color-mix(in srgb, #f59e0b 55%, transparent); }
.legend i.s { background: color-mix(in srgb, var(--appt) 45%, transparent); }
.legend i.g { border: 2px dashed var(--appt); }

/* Pillars */
.pillars { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-top: -24px; position: relative; }
.pillar { padding: 28px; border-radius: 20px; background: var(--card); border: 1px solid var(--line); box-shadow: var(--shadow); }
.pillar h3 { font-size: 19px; margin: 16px 0 8px; }
.pillar p { color: var(--muted); line-height: 1.6; font-size: 15px; }
.pillar-icon { display: grid; place-items: center; width: 44px; height: 44px; border-radius: 12px; background: color-mix(in srgb, var(--teal) 12%, transparent); color: var(--teal); font-size: 22px; }

/* Sections */
.section-head { text-align: center; max-width: 680px; margin: 0 auto 56px; }
.section-head > p:last-child { color: var(--muted); font-size: 18px; line-height: 1.6; }
.kicker { font-size: 13px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--vp-c-brand-1); margin-bottom: 12px !important; }
.kicker.light { color: #99f6e4; }
.features { padding-top: 120px; }
.feature { display: grid; grid-template-columns: 1fr 1.05fr; gap: 64px; align-items: center; margin-bottom: 112px; }
.feature.reverse .feature-copy { order: 2; }
.feature-copy p { color: var(--muted); font-size: 17px; line-height: 1.65; }
.badge { display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; border-radius: 999px; font-size: 13px; font-weight: 600; }
.badge.cal { background: color-mix(in srgb, var(--cal) 14%, transparent); color: #0369a1; }
.badge.meal { background: color-mix(in srgb, var(--meal) 14%, transparent); color: #c2410c; }
.badge.fin { background: color-mix(in srgb, var(--fin) 14%, transparent); color: #15803d; }
.badge.appt { background: color-mix(in srgb, var(--appt) 12%, transparent); color: #be123c; }
.badge.ai { background: color-mix(in srgb, var(--ai) 14%, transparent); color: #6d28d9; }
:global(.dark .landing .badge.cal) { color: #7dd3fc; }
:global(.dark .landing .badge.meal) { color: #fdba74; }
:global(.dark .landing .badge.fin) { color: #86efac; }
:global(.dark .landing .badge.appt) { color: #fda4af; }
:global(.dark .landing .badge.ai) { color: #c4b5fd; }
.checks { list-style: none; padding: 0; margin: 22px 0 0; display: grid; gap: 10px; }
.checks li { position: relative; padding-left: 30px; font-size: 15.5px; }
.checks li::before {
  content: ""; position: absolute; left: 0; top: 2px; width: 20px; height: 20px; border-radius: 50%;
  background: color-mix(in srgb, var(--teal) 15%, transparent)
    url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%230d9488' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M20 6 9 17l-5-5'/%3E%3C/svg%3E") center / 12px no-repeat;
}

.feature-visual { position: relative; }
.feature-visual::before {
  content: ""; position: absolute; inset: 8% 4%; border-radius: 40px; filter: blur(50px); opacity: 0.35; z-index: 0;
  background: linear-gradient(135deg, #5eead4, #a5b4fc);
}
:global(.dark .landing .feature-visual::before) { opacity: 0.12; }
.panel { position: relative; z-index: 1; background: var(--card); border: 1px solid var(--line); border-radius: 22px; padding: 22px; box-shadow: var(--shadow); }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 14px; }
.panel-head b { font-size: 16px; }
.chip { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; padding: 4px 10px; border-radius: 999px; background: var(--soft); color: var(--muted); border: 1px solid var(--line); white-space: nowrap; }
.chip.warn { color: var(--appt); background: color-mix(in srgb, var(--appt) 10%, transparent); border-color: transparent; }
.chip.good { color: #15803d; background: color-mix(in srgb, var(--fin) 14%, transparent); border-color: transparent; }
:global(.dark .landing .chip.good) { color: #86efac; }
.chip.live i { width: 7px; height: 7px; border-radius: 50%; background: #22c55e; box-shadow: 0 0 0 3px rgba(34, 197, 94, 0.25); }
.muted { color: var(--muted); font-size: 13px; margin-top: 14px; }

.two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 22px; }
.plan { display: grid; gap: 7px; }
.plan div { display: flex; align-items: center; gap: 10px; padding: 9px 11px; border-radius: 11px; background: var(--soft); font-size: 13.5px; }
.plan small { width: 30px; color: var(--muted); font-weight: 600; }
.plan .away { background: transparent; border: 1px dashed var(--line); }
.plan .away b { color: var(--muted); font-weight: 500; font-style: italic; }
.aisle { margin-bottom: 12px; }
.aisle > small { display: block; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); margin-bottom: 6px; }
.item { display: flex; align-items: center; gap: 10px; padding: 6px 0; font-size: 14px; border-bottom: 1px solid var(--line); }
.item.done { color: var(--muted); text-decoration: line-through; }
.box { display: grid; place-items: center; width: 18px; height: 18px; border-radius: 50%; border: 2px solid var(--line); color: #fff; font-size: 11px; }
.item.done .box { background: var(--meal); border-color: var(--meal); }

.bars { display: grid; gap: 14px; margin: 6px 0 18px; }
.bar-row { display: grid; grid-template-columns: 84px 1fr 64px; align-items: center; gap: 12px; font-size: 14px; }
.bar-row b { text-align: right; font-variant-numeric: tabular-nums; }
.bar { height: 10px; border-radius: 999px; background: var(--soft); overflow: hidden; }
.bar i { display: block; height: 100%; border-radius: inherit; background: linear-gradient(90deg, #22c55e, #16a34a); }
.totals { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.totals div { background: var(--soft); border-radius: 12px; padding: 10px 12px; }
.totals small { display: block; font-size: 12px; color: var(--muted); }
.totals b { font-size: 17px; font-variant-numeric: tabular-nums; }
.totals b.good { color: var(--fin); }

.slots { display: grid; gap: 8px; }
.slot { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 12px 14px; border-radius: 14px; background: var(--soft); }
.slot b { display: block; font-size: 14.5px; }
.slot small { font-size: 12.5px; color: var(--muted); }
.slot.new { background: color-mix(in srgb, var(--fin) 10%, var(--card)); border: 1px solid color-mix(in srgb, var(--fin) 30%, transparent); }

.chat { display: grid; gap: 14px; }
.msg { font-size: 14.5px; line-height: 1.55; }
.msg.me { justify-self: end; max-width: 80%; background: var(--teal); color: #fff; padding: 11px 15px; border-radius: 18px 18px 4px 18px; }
.msg.ai { display: flex; gap: 10px; align-items: flex-start; }
.msg.ai > div { background: var(--soft); padding: 12px 15px; border-radius: 4px 18px 18px 18px; }
.ai-mark { display: grid; place-items: center; width: 30px; height: 30px; border-radius: 50%; background: linear-gradient(135deg, #8b5cf6, #0d9488); color: #fff; flex: none; font-size: 15px; }
.changes { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; }
.undo { font-size: 13px; font-weight: 600; color: var(--vp-c-brand-1); }

/* Connected */
.connected { padding-top: 16px; padding-bottom: 112px; }
.links { display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; }
.link-card { padding: 22px; border-radius: 18px; background: var(--soft); border: 1px solid var(--line); }
.link-card b { display: block; font-size: 16px; line-height: 1.35; margin: 14px 0 8px; }
.link-card p { color: var(--muted); font-size: 14.5px; line-height: 1.55; }
.flow { display: flex; align-items: center; gap: 8px; color: var(--muted); font-weight: 700; }
.flow .sq { width: 26px; height: 26px; border-radius: 8px; }

/* Privacy band */
.privacy { background: linear-gradient(135deg, #0b3b37 0%, #0f766e 55%, #115e59 100%); color: #ecfeff; padding: 96px 0; }
.privacy h2 { color: #fff; }
.lead.light { color: #ccfbf1; margin-bottom: 28px; }
.privacy-grid { display: grid; grid-template-columns: 1fr 1.1fr; gap: 64px; align-items: center; }
.privacy-points { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
.privacy-points > div { padding: 22px; border-radius: 18px; background: rgba(255, 255, 255, 0.07); border: 1px solid rgba(255, 255, 255, 0.12); }
.privacy-points b { display: block; color: #fff; font-size: 16px; margin: 12px 0 6px; }
.privacy-points p { color: #b5ece4; font-size: 14.5px; line-height: 1.55; }
.p-icon { display: grid; place-items: center; width: 40px; height: 40px; border-radius: 11px; background: rgba(255, 255, 255, 0.12); color: #5eead4; font-size: 20px; }

/* How it works */
.how { padding-top: 112px; padding-bottom: 112px; }
.how-steps { display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; }
.how-step { display: flex; flex-direction: column; padding: 28px; border-radius: 22px; background: var(--card); border: 1px solid var(--line); box-shadow: var(--shadow); }
.how-step h3 { font-size: 20px; margin: 18px 0 8px; }
.how-step > p { color: var(--muted); font-size: 15.5px; line-height: 1.6; }
.how-num { display: grid; place-items: center; width: 40px; height: 40px; border-radius: 50%; font-weight: 700; font-size: 17px; color: #fff; background: linear-gradient(135deg, #14b8a6, #0f766e); }
.how-visual { margin-top: auto; padding-top: 24px; }
.device, .invite, .together { display: flex; align-items: center; gap: 12px; padding: 14px; border-radius: 16px; background: var(--soft); border: 1px solid var(--line); }
.device b, .invite b, .together b { display: block; font-size: 14px; }
.device small, .invite small, .together small { font-size: 12px; color: var(--muted); }
.device > div, .invite > div, .together > div:last-child { flex: 1; min-width: 0; }
.device-icon { display: grid; place-items: center; width: 36px; height: 36px; border-radius: 10px; background: #1f2937; color: #5eead4; font-size: 18px; flex: none; }
.invite img { border-radius: 9px; flex: none; }
.invite-btn { padding: 6px 14px; border-radius: 999px; background: var(--teal); color: #fff; font-size: 13px; font-weight: 600; }
.avatars { display: flex; flex: none; }
.avatars span { display: grid; place-items: center; width: 30px; height: 30px; border-radius: 50%; color: #fff; font-size: 12px; font-weight: 700; border: 2px solid var(--soft); margin-left: -8px; }
.avatars span:first-child { margin-left: 0; }
.how-note { text-align: center; margin-top: 36px !important; color: var(--muted); font-size: 16px; }
.how-note a { color: var(--vp-c-brand-1); font-weight: 600; text-decoration: underline; text-underline-offset: 3px; }

/* FAQ */
.faq { padding-bottom: 96px; }
.faq-list { max-width: 780px; margin: 0 auto; display: grid; gap: 12px; }
.faq details { border: 1px solid var(--line); border-radius: 16px; background: var(--card); padding: 0 22px; }
.faq summary { cursor: pointer; list-style: none; padding: 18px 0; font-weight: 600; font-size: 16.5px; display: flex; justify-content: space-between; gap: 16px; }
.faq summary::-webkit-details-marker { display: none; }
.faq summary::after { content: "+"; font-size: 22px; line-height: 1; color: var(--vp-c-brand-1); transition: transform 0.2s ease; }
.faq details[open] summary::after { transform: rotate(45deg); }
.faq details p { color: var(--muted); line-height: 1.65; padding-bottom: 20px; }

/* Final CTA */
.final { padding-bottom: 96px; }
.final-card {
  text-align: center; padding: 64px 24px; border-radius: 32px; color: #fff;
  background: radial-gradient(circle at 20% 0%, #2dd4bf 0%, transparent 45%), radial-gradient(circle at 100% 100%, #6366f1 0%, transparent 40%), #0f766e;
}
.final-card img { border-radius: 18px; box-shadow: 0 16px 32px -12px rgba(0, 0, 0, 0.4); margin: 0 auto 22px; }
.final-card h2 { color: #fff; }
.final-card p { color: #ccfbf1; font-size: 18px; }

/* Smaller screens */
@media (max-width: 960px) {
  .hero { padding: 40px 0 72px; }
  .hero-grid, .feature, .privacy-grid { grid-template-columns: 1fr; gap: 40px; }
  .how-steps { grid-template-columns: 1fr; max-width: 560px; margin: 0 auto; }
  .feature.reverse .feature-copy { order: 0; }
  .feature { margin-bottom: 80px; }
  .hero-visual { height: 520px; max-width: 560px; width: 100%; margin: 0 auto; }
  .mac { right: 0; width: 92%; }
  .phone { left: 0; }
  .toast { right: 0; }
  .pillars { grid-template-columns: 1fr; margin-top: 0; }
  .links { grid-template-columns: 1fr 1fr; }
  .features { padding-top: 88px; }
}
@media (max-width: 640px) {
  .container { padding: 0 16px; }
  .lead { font-size: 17px; }
  .hero-visual { height: 500px; }
  .mac { display: none; }
  .phone { left: 50%; right: auto; transform: translateX(-50%); }
  .toast { display: none; }
  .two-col { grid-template-columns: 1fr; }
  .links, .privacy-points { grid-template-columns: 1fr; }
  .privacy { padding: 72px 0; }
  .bar-row { grid-template-columns: 72px 1fr 58px; }
  .panel { padding: 16px; }
  .month-grid { gap: 4px; }
  .month-grid .day { font-size: 12px; border-radius: 6px; }
  .how, .features { padding-top: 72px; }
  .how { padding-bottom: 72px; }
}
</style>
