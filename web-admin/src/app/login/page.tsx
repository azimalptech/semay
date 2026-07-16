import { getLang, getTranslations, toClientDict } from "@/lib/l10n";
import { LoginForm } from "./LoginForm";

export default async function LoginPage() {
  const lang = await getLang();
  const t = await getTranslations();
  return <LoginForm lang={lang} t={toClientDict(t)} />;
}
