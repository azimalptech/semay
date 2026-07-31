import { NextResponse } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { ApiError, callAuthedApi } from "@/lib/apiClient";

export async function DELETE(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const claims = await getSessionClaims();
  if (!claims) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const { id } = await params;
  try {
    const result = await callAuthedApi(`/stores/${id}`, { method: "DELETE" });
    return NextResponse.json(result);
  } catch (err) {
    if (err instanceof ApiError) return NextResponse.json(err.body, { status: err.status });
    throw err;
  }
}
