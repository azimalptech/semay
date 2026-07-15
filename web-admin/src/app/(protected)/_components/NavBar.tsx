import Link from "next/link";
import { LogoutButton } from "./LogoutButton";

export function NavBar({ email }: { email: string | null }) {
  return (
    <header className="flex items-center justify-between border-b border-gray-200 bg-white px-8 py-4">
      <nav className="flex items-center gap-6 text-sm font-medium text-gray-700">
        <span className="font-semibold text-gray-900">SeMay Super Admin</span>
        <Link href="/dashboard" className="hover:text-gray-900">
          Dashboard
        </Link>
        <Link href="/stores" className="hover:text-gray-900">
          Stores
        </Link>
      </nav>
      <div className="flex items-center gap-4 text-sm text-gray-500">
        {email && <span>{email}</span>}
        <LogoutButton />
      </div>
    </header>
  );
}
