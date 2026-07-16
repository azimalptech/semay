"use client";

import { useTransition } from "react";
import type { Lang } from "@/lib/l10n";
import { setLanguage } from "@/lib/l10nActions";

export function LanguageSwitcher({ lang }: { lang: Lang }) {
  const [pending, startTransition] = useTransition();

  return (
    <select
      value={lang}
      disabled={pending}
      onChange={(e) => startTransition(() => setLanguage(e.target.value as Lang))}
      className="rounded-md border border-gray-300 bg-white px-2 py-1 text-sm text-gray-700 disabled:opacity-50"
    >
      <option value="tk">Türkmen</option>
      <option value="ru">Русский</option>
    </select>
  );
}
