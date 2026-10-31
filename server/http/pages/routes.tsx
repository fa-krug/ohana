// The pages: GET routes that render HTML or redirect. What they do on submit is in
// client/auth.ts (forms → /api/auth/...).

import { Hono, type Context } from "hono";
import type { JSX } from "hono/jsx/jsx-runtime";
import type { Db } from "@/lib/db";
import { getAppUrl } from "@/lib/auth/config";
import { deviceTokenName, safeNext, validPairState } from "@/lib/auth/device-pairing";
import { AuthError } from "@/lib/auth/errors";
import { hasAnyUser } from "@/lib/auth/first-run";
import { listPasskeys } from "@/lib/auth/passkey-management";
import { hasUsablePassword } from "@/lib/auth/password";
import { homeFor } from "@/lib/auth/redirect";
import { getAuth } from "@/lib/auth/session";
import { getInviteSummary } from "@/lib/families/invites";
import { getI18n } from "@/lib/i18n/server";
import { AccountPage, HomePage, OpenInAppPage } from "./account";
import { InvitePage, LoginPage, OnboardingPage, PairPage, SetupLinkPage, SetupPage } from "./auth";
import { Layout } from "./layout";

/** Renders `body` in the layout as a full HTML document. */
async function render(c: Context, page: string, title: (t: (k: string) => string) => string, body: (i18n: Awaited<ReturnType<typeof getI18n>>) => JSX.Element) {
  const i18n = await getI18n();
  const doc = (
    <Layout t={i18n.t} locale={i18n.locale} title={title(i18n.t)} page={page}>
      {body(i18n)}
    </Layout>
  );
  return c.html(`<!doctype html>${await doc.toString()}`);
}

function withQuery(path: string, params: Record<string, string | null | undefined>): string {
  const q = new URLSearchParams(Object.entries(params).filter((e): e is [string, string] => !!e[1]));
  const s = q.toString();
  return s ? `${path}?${s}` : path;
}

export function pageRoutes(db: Db): Hono {
  const pages = new Hono();

  // The start page: Ohana itself is the app; a browser only signs in and manages the account.
  pages.get("/", async (c) => {
    const auth = await getAuth();
    if (!auth) return c.redirect(hasAnyUser(db) ? "/login" : "/setup");
    if (auth.user.onboardingStep !== "COMPLETED") return c.redirect(homeFor(auth.user));
    const name = auth.user.name || auth.user.email;
    return render(c, "home", (t) => t("pages.home.title"), ({ t }) => <HomePage t={t} name={name} serverUrl={getAppUrl()} />);
  });

  // `next`: where to go once signed in (the app's pairing and account pages use it).
  pages.get("/login", async (c) => {
    const next = safeNext(c.req.query("next"));
    const auth = await getAuth();
    if (auth) return c.redirect(homeFor(auth.user, next));
    // A fresh install: the first account, then on to `next` (e.g. the app's pairing).
    if (!hasAnyUser(db)) return c.redirect(withQuery("/setup", { next }));
    return render(c, "login", (t) => t("auth.login.title"), ({ t }) => <LoginPage t={t} next={next} />);
  });

  pages.get("/setup", async (c) => {
    const next = safeNext(c.req.query("next"));
    if (hasAnyUser(db)) return c.redirect(withQuery("/login", { next }));
    return render(c, "setup", (t) => t("auth.setup.title"), ({ t }) => <SetupPage t={t} next={next} />);
  });

  // The link only opens this page: the token is used up by its button, so link previews (chat
  // apps fetch links to show a preview) can't use it up.
  pages.get("/setup-link/:token", (c) =>
    render(c, "setup-link", (t) => t("auth.setupLink.title"), ({ t }) => <SetupLinkPage t={t} token={c.req.param("token")} />),
  );

  pages.get("/invite/:code", async (c) => {
    const code = c.req.param("code");
    const auth = await getAuth();
    return render(c, "invite", (t) => t("invite.title"), ({ t }) => {
      let familyName: string | null = null;
      let personName: string | null = null;
      let error = "";
      try {
        ({ familyName, personName } = getInviteSummary(db, code, new Date()));
      } catch (e) {
        error = e instanceof AuthError ? e.message : t("invite.invalidInvite");
      }
      return <InvitePage t={t} code={code} familyName={familyName} personName={personName} error={error} signedIn={!!auth} />;
    });
  });

  pages.get("/onboarding", async (c) => {
    const next = safeNext(c.req.query("next"));
    const auth = await getAuth();
    if (!auth) return c.redirect(withQuery("/login", { next: withQuery("/onboarding", { next }) }));
    if (auth.user.onboardingStep === "COMPLETED") return c.redirect(next ?? "/");
    const step = auth.user.onboardingStep;
    return render(c, "onboarding", (t) => t("meta.title"), ({ t }) => <OnboardingPage t={t} step={step} next={next} />);
  });

  // Connects the native app (apple/) to the account: see lib/auth/device-pairing.ts.
  pages.get("/device/pair", async (c) => {
    const state = c.req.query("state") ?? "";
    const deviceName = c.req.query("deviceName") ?? "";
    const here = `/device/pair?${new URLSearchParams({ state, deviceName })}`;
    const auth = await getAuth();
    if (!auth) return c.redirect(`/login?${new URLSearchParams({ next: here })}`);
    if (auth.user.onboardingStep !== "COMPLETED") return c.redirect(homeFor(auth.user, here));
    const user = auth.user;
    return render(c, "pair", (t) => t("auth.devicePair.title"), ({ t }) => (
      <PairPage
        t={t}
        valid={validPairState(state)}
        state={state}
        deviceName={deviceName}
        device={deviceTokenName(deviceName)}
        name={user.name || user.email}
      />
    ));
  });

  // The account: passkeys, email, password. The app opens it with `state` (its own secret, as
  // for pairing) and gets ohana://account-callback?state=…[&changed=passkey|email|password].
  pages.get("/account", async (c) => {
    const rawState = c.req.query("state");
    const state = validPairState(rawState) ? rawState : null;
    const here = withQuery("/account", { state });
    const auth = await getAuth();
    if (!auth) return c.redirect(`/login?${new URLSearchParams({ next: here })}`);
    if (auth.user.onboardingStep !== "COMPLETED") return c.redirect(homeFor(auth.user, here));
    const { user, token } = auth;
    return render(c, "account", (t) => t("pages.account.title"), ({ t, locale }) => (
      <AccountPage
        t={t}
        locale={locale}
        email={user.email}
        name={user.name}
        hasPassword={hasUsablePassword(user.password)}
        canReset={token.canReset}
        passkeys={listPasskeys(db, user.id)}
        state={state}
      />
    ));
  });

  // Links into a family (notifications, shared links): there is no web UI, the app opens them.
  pages.get("/f/*", (c) => {
    const url = new URL(c.req.url);
    const link = `ohana:/${url.pathname}${url.search}`;
    return render(c, "open", (t) => t("pages.open.title"), ({ t }) => <OpenInAppPage t={t} link={link} />);
  });

  return pages;
}
