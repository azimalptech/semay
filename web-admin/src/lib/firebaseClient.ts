"use client";

import { getApps, initializeApp } from "firebase/app";
import { connectAuthEmulator, getAuth } from "firebase/auth";
import { connectFunctionsEmulator, getFunctions } from "firebase/functions";

const firebaseConfig = {
  apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY,
  appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID,
  messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID,
  projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID,
  authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN,
  storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET,
};

const app = getApps().length === 0 ? initializeApp(firebaseConfig) : getApps()[0];

export const clientAuth = getAuth(app);
export const clientFunctions = getFunctions(app);

// Only connect once — connectXEmulator throws if called a second time on the
// same instance, and this module can be re-evaluated across client navigations.
let emulatorsConnected = false;
if (
  process.env.NEXT_PUBLIC_USE_FIREBASE_EMULATORS === "true" &&
  !emulatorsConnected
) {
  emulatorsConnected = true;
  connectAuthEmulator(
    clientAuth,
    `http://${process.env.NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST}`,
    { disableWarnings: true }
  );
  connectFunctionsEmulator(
    clientFunctions,
    process.env.NEXT_PUBLIC_FIREBASE_FUNCTIONS_EMULATOR_HOST!,
    Number(process.env.NEXT_PUBLIC_FIREBASE_FUNCTIONS_EMULATOR_PORT)
  );
}
