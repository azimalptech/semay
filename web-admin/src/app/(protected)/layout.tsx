import { requireSuperAdmin } from "@/lib/session";
import { getLang, getTranslations } from "@/lib/l10n";
import { NavBar } from "./_components/NavBar";

export default async function ProtectedLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  // Defense in depth (data-security.md's DAL pattern) — proxy.ts already
  // gates these routes optimistically; this is the "secure" re-check
  // (checkRevoked: true) and also gets us the claims to show in the nav.
  const claims = await requireSuperAdmin();
  const lang = await getLang();
  const t = await getTranslations();

  return (
    <div className="flex min-h-screen flex-col">
      <NavBar email={claims.email} lang={lang} t={t} />
      <main className="flex-1 bg-gray-50 p-8">{children}</main>
    </div>
  );
}
