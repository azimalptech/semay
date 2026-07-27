// Seeds the local dev MySQL database with:
// - one Super Admin (phone-identified, same auth as everyone else now — see
//   docs/07_MIGRATION.md Phase 8) to log into web-admin with
// - one store-admin test account, already granted admin on the seed store
// - one baseline store with sample orders across 2 days, so /dashboard has data
//
// Run with `npm run seed` while server/'s MySQL is up and reachable via
// this project's DATABASE_URL (see .env.local.example — same DB server/ uses).
import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

const SUPERADMIN_PHONE = "+99361000001";
const STORE_ADMIN_PHONE = "+99365555555";
const STORE_ADMIN_NAME = "Store Admin";
const STORE_NAME = "Lady's shop";

function daysAgo(days: number, hour: number): Date {
  const d = new Date();
  d.setDate(d.getDate() - days);
  d.setHours(hour, 0, 0, 0);
  return d;
}

async function main() {
  const superadmin = await prisma.user.upsert({
    where: { phone: SUPERADMIN_PHONE },
    create: { phone: SUPERADMIN_PHONE, name: "Super Admin", role: "superadmin" },
    update: { role: "superadmin" },
  });

  const storeAdmin = await prisma.user.upsert({
    where: { phone: STORE_ADMIN_PHONE },
    create: { phone: STORE_ADMIN_PHONE, name: STORE_ADMIN_NAME, role: "admin" },
    update: { role: "admin" },
  });

  let store = await prisma.store.findFirst({ where: { name: STORE_NAME } });
  if (!store) {
    store = await prisma.store.create({
      data: {
        name: STORE_NAME,
        tagline: "Feel Beautiful, Always. ✨",
        phone: "+99362123456",
        address: "Ashgabat, Bitaraplyk shayoly 142-nji jayy",
        createdById: superadmin.id,
        active: true,
      },
    });

    await prisma.storeAdmin.create({ data: { storeId: store.id, userId: storeAdmin.id } });

    await prisma.order.createMany({
      data: [
        {
          storeId: store.id,
          adminId: superadmin.id,
          userId: storeAdmin.id,
          chatId: `${storeAdmin.id}_${store.id}`,
          itemQuantity: 3,
          userPhone: STORE_ADMIN_PHONE,
          createdAt: daysAgo(1, 10),
        },
        {
          storeId: store.id,
          adminId: superadmin.id,
          userId: storeAdmin.id,
          chatId: `${storeAdmin.id}_${store.id}`,
          itemQuantity: 2,
          userPhone: STORE_ADMIN_PHONE,
          createdAt: daysAgo(1, 15),
        },
        {
          storeId: store.id,
          adminId: superadmin.id,
          userId: storeAdmin.id,
          chatId: `${storeAdmin.id}_${store.id}`,
          itemQuantity: 5,
          userPhone: STORE_ADMIN_PHONE,
          createdAt: daysAgo(0, 11),
        },
      ],
    });
  }

  console.log("Seed complete.");
  console.log(`Super Admin login (phone-OTP, same as everyone else) -> ${SUPERADMIN_PHONE}`);
  console.log(
    `Store-admin phone (already has admin rights on "${STORE_NAME}") -> ${STORE_ADMIN_PHONE}`
  );
  console.log(
    "OTP_DEV_MODE=true on server/ echoes the code in the send response, no real SMS needed for local testing."
  );
}

main()
  .then(() => prisma.$disconnect())
  .catch(async (e) => {
    console.error(e);
    await prisma.$disconnect();
    process.exit(1);
  });
