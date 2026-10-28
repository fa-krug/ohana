import type { Metadata, Viewport } from "next";
import "./globals.css";
import { getI18n, resolveLocale } from "@/lib/i18n/server";

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
  // Advertise support for both schemes so the browser paints its own surfaces
  // (canvas, scrollbars, form controls) to match the OS preference from the
  // first frame. The actual theme is resolved purely in CSS via
  // `@media (prefers-color-scheme)`, so there is no script and no theme flash.
  colorScheme: "light dark",
};

export default async function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const locale = await resolveLocale();
  return (
    <html lang={locale}>
      <body>{children}</body>
    </html>
  );
}
