// Sign-in, the first account, setup links, invites, the onboarding and pairing the app.

import type { FC } from "hono/jsx";
import { Card, ErrorText, Field, PasskeyIcon, type T } from "./layout";

export const LoginPage: FC<{ t: T; next: string | null }> = ({ t, next }) => (
  <Card title={t("auth.login.title")} description={t("auth.login.subtitle")}>
    <form data-form="login" data-next={next ?? ""}>
      <Field label={t("auth.login.emailLabel")} name="email" autocomplete="username webauthn" />
      <Field label={t("auth.login.passwordLabel")} name="password" type="password" autocomplete="current-password" hidden wrapAttr="data-password" />
      <ErrorText />
      <button type="submit" class="primary" data-passkey-label={t("auth.login.signInWithPasskey")} data-password-label={t("auth.login.submit")}>
        <PasskeyIcon />
        <span data-label>{t("auth.login.signInWithPasskey")}</span>
      </button>
      <button
        type="button"
        class="link"
        data-toggle-password
        data-passkey-label={t("auth.login.usePasswordInstead")}
        data-password-label={t("auth.login.usePasskeyInstead")}
      >
        {t("auth.login.usePasswordInstead")}
      </button>
      <p class="hint" data-password hidden>
        {t("auth.login.forgot")}
      </p>
    </form>
  </Card>
);

export const SetupPage: FC<{ t: T; next: string | null }> = ({ t, next }) => (
  <Card title={t("auth.setup.title")} description={t("auth.setup.subtitle")}>
    <form data-form="setup" data-next={next ?? ""}>
      <Field label={t("auth.setup.nameLabel")} name="name" autocomplete="name" />
      <Field label={t("auth.setup.emailLabel")} name="email" type="email" autocomplete="email" required />
      <Field label={t("auth.setup.passwordLabel")} name="password" type="password" autocomplete="new-password" />
      <ErrorText />
      <button type="submit" class="primary">
        {t("auth.setup.submit")}
      </button>
      <button type="button" data-passkey>
        <PasskeyIcon />
        {t("auth.setup.withPasskey")}
      </button>
    </form>
  </Card>
);

export const SetupLinkPage: FC<{ t: T; token: string }> = ({ t, token }) => (
  <Card title={t("auth.setupLink.title")} description={t("auth.setupLink.description")}>
    <form data-form="setup-link" data-token={token} data-invalid={t("auth.setupLink.invalid")}>
      <ErrorText />
      <button type="submit" class="primary">
        {t("common.continue")}
      </button>
    </form>
  </Card>
);

export const InvitePage: FC<{
  t: T;
  code: string;
  familyName: string | null;
  personName: string | null;
  error: string;
  signedIn: boolean;
}> = ({ t, code, familyName, personName, error, signedIn }) => {
  if (!familyName) {
    return (
      <Card title={t("invite.title")}>
        <p class="error">{error}</p>
      </Card>
    );
  }
  const description = [personName ? t("invite.forPerson", { name: personName }) : "", signedIn ? t("invite.signedInDescription") : t("invite.createAccountDescription")]
    .filter(Boolean)
    .join(" ");
  return (
    <Card title={t("invite.join", { family: familyName })} description={description}>
      {signedIn ? (
        <form data-form="invite-accept" data-code={code}>
          <ErrorText />
          <button type="submit" class="primary">
            {t("invite.accept")}
          </button>
        </form>
      ) : (
        <form data-form="invite-register" data-code={code}>
          <Field label={t("invite.nameLabel")} name="name" autocomplete="name" />
          <Field label={t("invite.emailLabel")} name="email" type="email" autocomplete="email" required />
          <button type="button" class="primary" data-passkey>
            <PasskeyIcon />
            {t("invite.registerWithPasskey")}
          </button>
          <Field label={t("invite.passwordLabel")} name="password" type="password" autocomplete="new-password" />
          <ErrorText />
          <button type="submit">{t("invite.createAccount")}</button>
        </form>
      )}
      <p class="hint">
        <a href={`ohana://invite/${encodeURIComponent(code)}`}>{t("pages.openInviteInApp")}</a>
      </p>
    </Card>
  );
};

export const OnboardingPage: FC<{ t: T; step: string; next: string | null }> = ({ t, step, next }) =>
  step === "SET_CREDENTIALS" ? (
    <Card title={t("onboarding.credentials.title")} description={t("onboarding.credentials.description")}>
      <form data-form="onboarding-credentials" data-next={next ?? ""}>
        <ErrorText />
        <button type="button" class="primary" data-passkey>
          <PasskeyIcon />
          {t("onboarding.credentials.passkey")}
        </button>
        <button type="button" class="link" data-show-password>
          {t("onboarding.credentials.password")}
        </button>
        <div data-password hidden>
          <Field label={t("onboarding.credentials.passwordLabel")} name="password" type="password" autocomplete="new-password" />
          <button type="submit">{t("onboarding.credentials.savePassword")}</button>
        </div>
      </form>
    </Card>
  ) : (
    <Card title={t("onboarding.addPasskey.title")} description={t("onboarding.addPasskey.description")}>
      <form data-form="onboarding-passkey" data-next={next ?? ""}>
        <ErrorText />
        <button type="button" class="primary" data-passkey>
          <PasskeyIcon />
          {t("onboarding.addPasskey.add")}
        </button>
        <button type="button" data-skip>
          {t("onboarding.addPasskey.skip")}
        </button>
      </form>
    </Card>
  );

export const PairPage: FC<{ t: T; valid: boolean; state: string; deviceName: string; device: string; name: string }> = ({ t, valid, state, deviceName, device, name }) => (
  <Card title={t("auth.devicePair.title")} description={valid ? t("auth.devicePair.description", { device, name }) : t("auth.devicePair.invalid")}>
    {valid && (
      <form data-form="pair" data-state={state} data-device-name={deviceName} data-invalid={t("auth.devicePair.invalid")}>
        <ErrorText />
        <button type="submit" class="primary">
          {t("auth.devicePair.connect")}
        </button>
        <button type="button" class="link" data-cancel>
          {t("common.cancel")}
        </button>
      </form>
    )}
  </Card>
);
