"use client";

// Settings → AI (family-planner's settings/AiSection.tsx): the family's OpenAI-compatible
// endpoint (URL, key, model from its list, context window, a test), the web search, and
// whether the assistant may change things. Editors only; viewers see who can set it up.

import { useEffect, useState } from "react";
import Link from "next/link";
import { CircleCheck, CircleX, Loader2, RefreshCw } from "lucide-react";
import { toast } from "@/components/ui/sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { useT } from "@/lib/i18n/provider";
import { type AiSettings, type AiSettingsPatch, aiApi } from "./api";
import { useOptionalChat } from "./context";

const PRESETS: [string, string][] = [
  ["OpenAI", "https://api.openai.com/v1"],
  ["OpenRouter", "https://openrouter.ai/api/v1"],
  ["Mistral", "https://api.mistral.ai/v1"],
  ["Groq", "https://api.groq.com/openai/v1"],
  ["Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"],
  ["Ollama", "http://localhost:11434/v1"],
];

function SettingsCard({ title, description, children }: { title: string; description?: string; children: React.ReactNode }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{title}</CardTitle>
        {description && <CardDescription>{description}</CardDescription>}
      </CardHeader>
      <CardContent className="grid grid-cols-1 gap-4">{children}</CardContent>
    </Card>
  );
}

function Field({ id, label, help, children }: { id?: string; label: string; help?: string; children: React.ReactNode }) {
  return (
    <div className="grid gap-1.5">
      <Label htmlFor={id}>{label}</Label>
      {children}
      {help && <p className="text-xs text-muted-foreground">{help}</p>}
    </div>
  );
}

type Search = NonNullable<AiSettings["searchProvider"]>;

export function AiSettingsSection({ familyId, readOnly }: { familyId: string; readOnly: boolean }) {
  const { t } = useT();
  const chat = useOptionalChat();
  const [settings, setSettings] = useState<AiSettings | null>(null);
  const [baseUrl, setBaseUrl] = useState("");
  const [apiKey, setApiKey] = useState("");
  const [model, setModel] = useState("");
  // Tokens as typed; "" finds the window out.
  const [contextWindow, setContextWindow] = useState("");
  const [models, setModels] = useState<string[] | null>(null);
  const [searchProvider, setSearchProvider] = useState<Search>("none");
  const [searchKey, setSearchKey] = useState("");
  const [busy, setBusy] = useState<"" | "save" | "models" | "test">("");
  const [test, setTest] = useState<{ ok: boolean; text: string } | null>(null);

  const apply = (s: AiSettings) => {
    setSettings(s);
    setBaseUrl(s.baseUrl ?? "");
    setModel(s.model);
    setContextWindow(s.contextWindow ? String(s.contextWindow) : "");
    setSearchProvider(s.searchProvider ?? "none");
    setApiKey("");
    setSearchKey("");
    // The chat panel learns that the assistant is set up now.
    if (chat?.token === familyId) chat.setSettings(s);
  };

  useEffect(() => {
    if (readOnly) return;
    aiApi
      .settings(familyId)
      .then(apply)
      .catch((err) => toast((err as Error).message));
    // Load once per family.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [familyId, readOnly]);

  if (readOnly) {
    return <p className="text-sm text-muted-foreground">{t("aiSettings.editorsOnly")}</p>;
  }
  if (!settings) return <div className="h-64 animate-pulse rounded-xl bg-muted" />;

  async function save(patch: AiSettingsPatch = {}) {
    setBusy("save");
    try {
      const body: AiSettingsPatch = {
        baseUrl,
        model,
        contextWindow: Number(contextWindow) || 0,
        searchProvider,
        ...patch,
      };
      if (apiKey) body.apiKey = apiKey;
      if (searchKey) body.searchKey = searchKey;
      apply(await aiApi.saveSettings(familyId, body));
      toast(t("aiSettings.saved"));
    } catch (err) {
      toast(t("aiSettings.saveFailed", { msg: (err as Error).message }));
    }
    setBusy("");
  }

  async function loadModels() {
    setBusy("models");
    try {
      const res = await aiApi.models(familyId, { baseUrl, ...(apiKey ? { apiKey } : {}) });
      setModels(res.models);
      if (!model && res.models.length) setModel(res.models[0]);
      if (!res.models.length) toast(t("aiSettings.noModels"));
    } catch (err) {
      toast((err as Error).message);
    }
    setBusy("");
  }

  async function runTest() {
    setBusy("test");
    setTest(null);
    try {
      const res = await aiApi.test(familyId);
      setTest({ ok: true, text: t("aiSettings.testOk", { model: res.model, reply: res.reply || "…" }) });
    } catch (err) {
      setTest({ ok: false, text: (err as Error).message });
    }
    setBusy("");
  }

  const dirty =
    baseUrl !== (settings.baseUrl ?? "") ||
    model !== settings.model ||
    (Number(contextWindow) || 0) !== (settings.contextWindow ?? 0) ||
    !!apiKey ||
    searchProvider !== (settings.searchProvider ?? "none") ||
    !!searchKey;

  return (
    <div className="grid gap-6">
      <SettingsCard title={t("aiSettings.endpoint")} description={t("aiSettings.endpointHelp")}>
        <Field id="ai-base-url" label={t("aiSettings.baseUrl")} help={t("aiSettings.baseUrlHelp")}>
          <Input
            id="ai-base-url"
            value={baseUrl}
            placeholder="https://api.openai.com/v1"
            spellCheck={false}
            onChange={(e) => {
              setBaseUrl(e.target.value);
              setModels(null);
            }}
          />
          <div className="flex flex-wrap gap-1.5">
            {PRESETS.map(([name, url]) => (
              <Button
                key={name}
                type="button"
                size="sm"
                variant="outline"
                className="h-7 text-xs"
                onClick={() => {
                  setBaseUrl(url);
                  setModels(null);
                }}
              >
                {name}
              </Button>
            ))}
          </div>
        </Field>
        <Field
          id="ai-key"
          label={t("aiSettings.apiKey")}
          help={settings.hasKey ? t("aiSettings.keySaved", { hint: settings.keyHint ?? "" }) : t("aiSettings.keyHelp")}
        >
          <div className="flex gap-2">
            <Input
              id="ai-key"
              type="password"
              autoComplete="off"
              value={apiKey}
              placeholder={settings.hasKey ? `••••••••${settings.keyHint}` : "sk-…"}
              onChange={(e) => setApiKey(e.target.value)}
            />
            {settings.hasKey && (
              <Button variant="outline" disabled={!!busy} onClick={() => save({ apiKey: "" })}>
                {t("aiSettings.removeKey")}
              </Button>
            )}
          </div>
        </Field>
        <Field id="ai-model" label={t("aiSettings.model")} help={t("aiSettings.modelHelp")}>
          <div className="flex flex-col gap-2 sm:flex-row">
            {models?.length ? (
              <Select value={model} onValueChange={setModel}>
                <SelectTrigger id="ai-model" className="w-full min-w-0">
                  <SelectValue placeholder={t("aiSettings.pickModel")} />
                </SelectTrigger>
                <SelectContent position="popper" className="max-h-80">
                  {[...new Set([model, ...models].filter(Boolean))].map((m) => (
                    <SelectItem key={m} value={m}>
                      {m}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            ) : (
              <Input
                id="ai-model"
                value={model}
                placeholder="gpt-4.1-mini"
                spellCheck={false}
                onChange={(e) => setModel(e.target.value)}
              />
            )}
            <Button variant="outline" className="shrink-0" disabled={!baseUrl || !!busy} onClick={loadModels}>
              {busy === "models" ? <Loader2 className="animate-spin" /> : <RefreshCw />}
              {t("aiSettings.loadModels")}
            </Button>
          </div>
        </Field>
        <Field id="ai-window" label={t("aiSettings.contextWindow")} help={t("aiSettings.contextWindowHelp")}>
          <Input
            id="ai-window"
            className="w-40"
            type="number"
            inputMode="numeric"
            min={1000}
            step={1000}
            value={contextWindow}
            placeholder="128000"
            onChange={(e) => setContextWindow(e.target.value)}
          />
        </Field>
        <div className="flex flex-wrap items-center gap-2">
          <Button disabled={!!busy || !dirty} onClick={() => save()}>
            {busy === "save" && <Loader2 className="animate-spin" />} {t("common.save")}
          </Button>
          <Button variant="outline" disabled={!!busy || !settings.configured || dirty} onClick={runTest}>
            {busy === "test" && <Loader2 className="animate-spin" />} {t("aiSettings.test")}
          </Button>
          {test && (
            <span className={`inline-flex items-center gap-1.5 text-sm ${test.ok ? "text-ok" : "text-gap"}`}>
              {test.ok ? <CircleCheck className="size-4 shrink-0" /> : <CircleX className="size-4 shrink-0" />} {test.text}
            </span>
          )}
        </div>
      </SettingsCard>

      <SettingsCard title={t("aiSettings.search")} description={t("aiSettings.searchHelp")}>
        <Field id="ai-search" label={t("aiSettings.searchProvider")}>
          <Select value={searchProvider} onValueChange={(v) => setSearchProvider(v as Search)}>
            <SelectTrigger id="ai-search" className="w-56">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">{t("aiSettings.searchOff")}</SelectItem>
              <SelectItem value="tavily">Tavily</SelectItem>
              <SelectItem value="brave">Brave Search</SelectItem>
            </SelectContent>
          </Select>
        </Field>
        {searchProvider !== "none" && (
          <Field
            id="ai-search-key"
            label={t("aiSettings.searchKey")}
            help={settings.hasSearchKey ? t("aiSettings.keySaved", { hint: settings.searchKeyHint ?? "" }) : undefined}
          >
            <Input
              id="ai-search-key"
              type="password"
              autoComplete="off"
              value={searchKey}
              placeholder={settings.hasSearchKey ? `••••••••${settings.searchKeyHint}` : ""}
              onChange={(e) => setSearchKey(e.target.value)}
            />
          </Field>
        )}
        <Button className="justify-self-start" disabled={!!busy || !dirty} onClick={() => save()}>
          {t("common.save")}
        </Button>
      </SettingsCard>

      <SettingsCard title={t("aiSettings.permissions")}>
        <label className="flex items-center justify-between gap-4 text-sm">
          <span>
            {t("aiSettings.allowWrites")}
            <span className="block text-xs text-muted-foreground">{t("aiSettings.allowWritesHelp")}</span>
          </span>
          <Switch checked={settings.allowWrites} onCheckedChange={(v) => save({ allowWrites: v })} />
        </label>
        <p className="text-xs text-muted-foreground">{t("aiSettings.privacy")}</p>
        <p className="text-xs text-muted-foreground">
          {t("aiSettings.agentHint")}{" "}
          <Link className="text-primary underline underline-offset-2" href={`/api/v1/families/${familyId}/agent`} target="_blank">
            {t("aiSettings.agentLink")}
          </Link>
        </p>
      </SettingsCard>
    </div>
  );
}
