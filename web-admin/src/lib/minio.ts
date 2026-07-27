import "server-only";
import { Client } from "minio";

// Same MinIO instance server/ uses (see .env.local.example) — only the
// leaderboard gift-image upload needs this; everything else that touches
// media goes through server/'s presigned-URL endpoint from the client side.
const endpoint = new URL(process.env.MEDIA_ENDPOINT!);

export const minioClient = new Client({
  endPoint: endpoint.hostname,
  port: endpoint.port ? Number(endpoint.port) : endpoint.protocol === "https:" ? 443 : 80,
  useSSL: endpoint.protocol === "https:",
  accessKey: process.env.MEDIA_ACCESS_KEY!,
  secretKey: process.env.MEDIA_SECRET_KEY!,
});

export const MEDIA_BUCKET = process.env.MEDIA_BUCKET!;
export const MEDIA_PUBLIC_BASE_URL = process.env.MEDIA_PUBLIC_BASE_URL!;
