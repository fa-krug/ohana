import type { Metadata, Viewport } from "next";
import "./globals.css";
import { getI18n, resolveLocale } from "@/lib/i18n/server";
import { themeScript } from "@/lib/theme";

export async function generateMetadata(): Promise<Metadata> {
  const { t } = await getI18n();
  const title = t("meta.title");
  return {
    title,
    description: t("meta.description"),
    appleWebApp: { capable: true, title },
  };
}

export const viewport: Viewport = {
  themeColor: "#0d9488",
  viewportFit: "cover",
  // Both schemes are supported. The theme itself (light / dark / like the system, per
  // device, lib/theme.ts) is applied by the blocking script in <head> below: it sets
  // `.dark` and `color-scheme` on <html> before the first paint, so there's no flash,
  // and follows the OS while the choice is "system".
  colorScheme: "light dark",
};

export default async function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const locale = await resolveLocale();
  return (
    // The theme script changes <html>'s class and style before React hydrates.
    <html lang={locale} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
