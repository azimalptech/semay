import Link from "next/link";
import type { ClientDict, Lang } from "@/lib/l10n";
import { LanguageSwitcher } from "./LanguageSwitcher";
import { LogoutButton } from "./LogoutButton";

export function NavBar({
  email,
  lang,
  t,
}: {
  email: string | null;
  lang: Lang;
  t: ClientDict;
}) {
  return (
    <header className="flex items-center justify-between border-b border-gray-200 bg-white px-8 py-4">
      <nav className="flex items-center gap-6 text-sm font-medium text-gray-700">
        <span className="font-semibold text-gray-900">{t.appName}</span>
        <Link href="/dashboard" className="hover:text-gray-900">
          {t.dashboard}
        </Link>
        <Link href="/stores" className="hover:text-gray-900">
          {t.stores}
        </Link>
      </nav>
      <div className="flex items-center gap-4 text-sm text-gray-500">
        <LanguageSwitcher lang={lang} />
        {email && <span>{email}</span>}
        <LogoutButton label={t.logOut} />
      </div>
    </header>
  );
}
