import { setGlobalOptions } from "firebase-functions/v2";

// Every function here defaults to 2nd-gen's cpu:1/concurrency:80, which
// during a deploy briefly runs old+new revisions side by side per function —
// with ~24 functions in one region, that repeatedly exceeded this project's
// Cloud Run CPU quota and failed deploys outright (not a code bug, a quota
// ceiling). Dropping to fractional cpu (which forces concurrency:1, since
// Cloud Run requires concurrency:1 below cpu:1) roughly halves the peak CPU
// a deploy needs. concurrency:1 means an instance handles one invocation at
// a time instead of up to 80 — under a burst, Cloud Run spins up more thin
// instances instead of reusing one fuller one (occasional extra cold starts,
// not request failures); every function here is I/O-bound (Firestore/
// Storage/SMS-gateway calls), so this has no meaningful effect on per-request
// latency. deleteStore overrides back to cpu:1 (see its own file) since its
// single-invocation cascade delete is real, sustained work worth the
// headroom, unlike everything else's single-document triggers/callables.
setGlobalOptions({ cpu: 0.5, concurrency: 1 });

export { sendOtp } from "./auth/sendOtp";
export { dispatchQueuedSms } from "./sms/dispatchQueuedSms";
export { verifyOtp } from "./auth/verifyOtp";
export { changePhone } from "./auth/changePhone";
export { completeProfile } from "./auth/completeProfile";

export { onPostCreated } from "./posts/onPostCreated";
export { onPostDeleted } from "./posts/onPostDeleted";
export { onLikeWrite } from "./posts/onLikeWrite";
export { onSavedWrite } from "./posts/onSavedWrite";
export { onViewCreated } from "./posts/onViewCreated";
export { onSentCreated } from "./posts/onSentCreated";
export { onShareCreated } from "./posts/onShareCreated";
export { expireStories } from "./stories/expireStories";

export { onMessageCreated } from "./chat/onMessageCreated";
export { acceptOrder } from "./orders/acceptOrder";
export { onOrderCreated } from "./orders/onOrderCreated";

export { createStore } from "./stores/createStore";
export { setStoreAdmin } from "./stores/setStoreAdmin";
export { deleteStore } from "./stores/deleteStore";

export { broadcastNotification } from "./admin/broadcastNotification";
export { requestBroadcastNotification } from "./admin/requestBroadcastNotification";
export { decideNotificationRequest } from "./admin/decideNotificationRequest";
export { setLeaderboardCampaignStart } from "./admin/setLeaderboardCampaignStart";
export { cleanupDuplicateUsers } from "./admin/cleanupDuplicateUsers";
