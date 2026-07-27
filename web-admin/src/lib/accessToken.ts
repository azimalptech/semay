import "server-only";
import { cookies } from "next/headers";
import { ACCESS_COOKIE } from "./authCookies";

export async function getAccessToken(): Promise<string | undefined> {
  return (await cookies()).get(ACCESS_COOKIE)?.value;
}
